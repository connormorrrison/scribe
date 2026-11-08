import SwiftUI
import WebKit

/// The sandbox the agent's visualization pages run in:
/// - JavaScript on, but no network: a CSP with `connect-src 'none'`, a content rule list that blocks every URL except
///   `app:`, `data:`, `blob:` and `about:`, and an `app://` scheme handler that serves only the bundled files below;
/// - no file access, a non-persistent data store, no navigation away from the page, no popups;
/// - the page talks to the app only through `card` messages (ready, error, focus, resize, readout);
/// - the card kit (Web/card-kit.js) and the dark stylesheet (Web/card.css) are injected before the page's own scripts.
enum CardSandbox {
    static let scheme = "app"
    static let baseURL = URL(string: "app://card/")!

    static let csp = "default-src 'none'; script-src 'unsafe-inline' app:; style-src 'unsafe-inline' app:; "
        + "img-src data: blob: app:; font-src app: data:; media-src 'none'; connect-src 'none'; frame-src 'none'; "
        + "child-src 'none'; worker-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"

    /// Everything is blocked, then the app's own schemes are let through again.
    static let rules = #"""
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^app:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}},
         {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}}]
        """#

    /// The only files a page can load: app://lib/<name>.
    static let library: [String: (resource: String, ext: String, mime: String)] = [
        "three.min.js": ("three.min", "js", "text/javascript"),
        "d3.min.js": ("d3.min", "js", "text/javascript"),
        "STIXTwoText.ttf": ("STIXTwoText", "ttf", "font/ttf"),
        "STIXTwoText-Italic.ttf": ("STIXTwoText-Italic", "ttf", "font/ttf")
    ]

    static let messageTypes: Set<String> = ["ready", "error", "focus", "resize", "readout"]

    static func bundled(_ resource: String, _ ext: String) -> String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return s
    }

    /// The stylesheet, then the kit, at document start (main frame only).
    static let kitScript: String = {
        let css = bundled("card", "css")
        let cssLiteral = (try? String(data: JSONEncoder().encode(css), encoding: .utf8)) ?? "\"\""
        return """
            (function(){var s=document.createElement('style');s.id='card-base';s.textContent=\(cssLiteral);
            (document.head||document.documentElement).appendChild(s);})();
            """ + "\n" + bundled("card-kit", "js")
    }()

    /// The page as loaded: a whole document gets the CSP and viewport metas in its head; a fragment is wrapped.
    static func document(_ html: String) -> String {
        let metas = "<meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"\(csp)\">"
            + "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1, user-scalable=no\">"
        if let head = html.range(of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: head.upperBound..<head.upperBound, with: metas)
        }
        if let open = html.range(of: #"<html\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
            return html.replacingCharacters(in: open.upperBound..<open.upperBound, with: "<head>\(metas)</head>")
        }
        return "<!doctype html><html><head>\(metas)</head><body>\(html)</body></html>"
    }

    @MainActor private static var compiled: WKContentRuleList?

    /// One in-memory store for every page: nothing is kept on disk, and pages can share warm web processes.
    @MainActor private static let dataStore = WKWebsiteDataStore.nonPersistent()

    @MainActor static func ruleList() async -> WKContentRuleList? {
        if let compiled { return compiled }
        let list = try? await WKContentRuleListStore.default()
            .compileContentRuleList(forIdentifier: "card-sandbox-v1", encodedContentRuleList: rules)
        compiled = list
        return list
    }

    @MainActor static func configuration(messages: WKScriptMessageHandler, rules: WKContentRuleList?) -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore
        cfg.setURLSchemeHandler(LibrarySchemeHandler(), forURLScheme: scheme)
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = false
        cfg.preferences.isFraudulentWebsiteWarningEnabled = false
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.dataDetectorTypes = []
        cfg.allowsInlineMediaPlayback = false
        cfg.mediaTypesRequiringUserActionForPlayback = .all
        let ucc = cfg.userContentController
        ucc.add(WeakMessages(messages), name: "card")
        ucc.addUserScript(WKUserScript(source: kitScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let rules { ucc.add(rules) }
        return cfg
    }

    @MainActor static func makeWebView(messages: WKScriptMessageHandler, navigation: WKNavigationDelegate,
                                       rules: WKContentRuleList?) -> WKWebView {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: Visualization.pageWidth, height: Visualization.defaultHeight),
                            configuration: configuration(messages: messages, rules: rules))
        web.navigationDelegate = navigation
        web.isOpaque = false
        web.backgroundColor = UIColor(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255, alpha: 1)
        web.scrollView.isScrollEnabled = false
        web.scrollView.bounces = false
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        return web
    }

    /// Only the page's own first load is allowed: no links, no redirects, no frames.
    static func allows(_ action: WKNavigationAction) -> Bool {
        guard let url = action.request.url else { return false }
        if url.absoluteString == "about:blank" { return true }
        return url == baseURL && action.targetFrame?.isMainFrame == true && action.navigationType == .other
    }

    /// A message from the page, if it's one the app understands. Everything else is dropped.
    static func parse(_ body: Any) -> CardMessage? {
        guard let o = body as? [String: Any], let type = o["type"] as? String, messageTypes.contains(type) else { return nil }
        func str(_ k: String, _ n: Int) -> String { String(String(describing: o[k] ?? "").prefix(n)) }
        switch type {
        case "ready": return .ready
        case "error": return .error(message: str("message", 300), line: (o["line"] as? NSNumber)?.intValue ?? 0)
        case "focus": return .focus(part: str("part", 64))
        case "resize":
            guard let h = (o["height"] as? NSNumber)?.doubleValue, h.isFinite else { return nil }
            return .resize(height: CGFloat(h))
        default: return .readout(text: plainReadout(str("text", 400)))
        }
    }

    /// Readouts are plain text, but pages sometimes send HTML ("n = 20<br>log n ≈ 4.3"): line breaks become " · ",
    /// other tags go.
    static func plainReadout(_ raw: String) -> String {
        var t = raw.replacingOccurrences(of: "<br\\s*/?>", with: " · ", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        return String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
    }
}

enum CardMessage: Equatable {
    case ready
    case error(message: String, line: Int)
    case focus(part: String)
    case resize(height: CGFloat)
    case readout(text: String)
}

/// Serves app://lib/<file> from the bundle, and nothing else.
final class LibrarySchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.host == "lib",
              let entry = CardSandbox.library[url.lastPathComponent],
              let file = Bundle.main.url(forResource: entry.resource, withExtension: entry.ext),
              let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": entry.mime, "Content-Length": "\(data.count)",
                                                      "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

/// WKUserContentController keeps its handlers alive; this keeps it from keeping the card alive.
final class WeakMessages: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

// MARK: - Checking a page before it opens

/// Loads a page off screen. An error before it's ready (or within a moment after), a page that never finishes
/// loading, a blank canvas or a crashed web process is reported back, so the agent can fix it once.
@MainActor
final class WebCardProbe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    private var web: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var firstError: String?
    private var readyAt: Date?

    /// Nil when the page loaded cleanly; otherwise what went wrong, in words the agent can act on.
    static func check(_ html: String, timeout: Double = 10) async -> String? {
        let probe = WebCardProbe()
        return await probe.run(html, timeout: timeout)
    }

    private func run(_ html: String, timeout: Double) async -> String? {
        let rules = await CardSandbox.ruleList()
        let web = CardSandbox.makeWebView(messages: self, navigation: self, rules: rules)
        self.web = web
        // A web view outside any window gets no animation frames, so the page would never run. It goes in the app's
        // window, out of sight.
        if let window = Self.hostWindow {
            web.frame.origin = CGPoint(x: -web.frame.width - 1000, y: 0)
            web.isUserInteractionEnabled = false
            web.accessibilityElementsHidden = true
            window.addSubview(web)
        }
        defer { web.removeFromSuperview() }
        let result: String? = await withCheckedContinuation { c in
            continuation = c
            web.loadHTMLString(CardSandbox.document(html), baseURL: CardSandbox.baseURL)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard let self else { return }
                self.finish(self.readyAt == nil
                    ? "the page didn't finish loading within \(Int(timeout)) s (an endless loop, or waiting on something that never comes)"
                    : nil)
            }
        }
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
        self.web = nil
        return result
    }

    private static var hostWindow: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap(\.windows)
        return windows.first(where: \.isKeyWindow) ?? windows.first
    }

    /// True when every 2D canvas on the page is fully transparent or the stage colour.
    static let blankCanvasScript = """
    (function () {
      var list = document.querySelectorAll('canvas'); if (!list.length) return false;
      var checked = 0;
      for (var i = 0; i < list.length; i++) {
        var c = list[i]; if (!c.width || !c.height) continue;
        var g = null; try { g = c.getContext('2d'); } catch (e) {} if (!g) continue;
        var t = document.createElement('canvas'); t.width = 48; t.height = 48;
        var x = t.getContext('2d'); x.drawImage(c, 0, 0, 48, 48);
        var d = x.getImageData(0, 0, 48, 48).data; checked++;
        for (var j = 0; j < d.length; j += 4) {
          if (d[j + 3] > 8 && (Math.abs(d[j] - 14) > 6 || Math.abs(d[j + 1] - 14) > 6 || Math.abs(d[j + 2] - 16) > 6)) return false;
        }
      }
      return checked > 0;
    })()
    """

    private func finish(_ error: String?) {
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: firstError ?? error)
    }

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        switch CardSandbox.parse(message.body) {
        case .error(let msg, let line)?:
            if firstError == nil { firstError = "the page threw “\(msg)”" + (line > 0 ? " at line \(line)" : "") }
            finish(nil)
        case .ready?:
            guard readyAt == nil else { return }
            readyAt = Date()
            // A moment for the first frames to run: errors in requestAnimationFrame callbacks show up here.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, let web = self.web else { return }
                let blank = try? await web.evaluateJavaScript(Self.blankCanvasScript) as? Bool
                self.finish(blank == true
                    ? "the page loaded but its canvas is blank: nothing was drawn (draw onto the canvas Card.stage() returns, and call your draw function once right away, not only on input)"
                    : nil)
            }
        default: break
        }
    }

    func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        CardSandbox.allows(action) ? .allow : .cancel
    }

    func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
        finish("the page crashed (too much memory, or an endless loop)")
    }

    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
        finish("the page failed to load: \(e.localizedDescription)")
    }
}

// MARK: - The page on screen

/// A visualization page on screen. `reload` changes when the person taps Replay: the page starts over.
struct WebCardView: UIViewRepresentable {
    let html: String
    var reload: Int
    var onMessage: (CardMessage) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onMessage) }

    func makeUIView(context: Context) -> WKWebView {
        let c = context.coordinator
        let web = CardSandbox.makeWebView(messages: c, navigation: c, rules: nil)
        c.loaded = reload
        // The rule list compiles once (then it's cached); the page loads only after it's in place.
        Task { @MainActor in
            if let rules = await CardSandbox.ruleList() { web.configuration.userContentController.add(rules) }
            web.loadHTMLString(CardSandbox.document(html), baseURL: CardSandbox.baseURL)
        }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let c = context.coordinator
        c.onMessage = onMessage
        if c.loaded != reload {
            c.loaded = reload
            web.loadHTMLString(CardSandbox.document(html), baseURL: CardSandbox.baseURL)
        }
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var onMessage: (CardMessage) -> Void
        var loaded = 0
        init(_ f: @escaping (CardMessage) -> Void) { onMessage = f }

        func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let m = CardSandbox.parse(message.body) else { return }
            onMessage(m)
        }

        func webView(_ w: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            CardSandbox.allows(action) ? .allow : .cancel
        }

        func webViewWebContentProcessDidTerminate(_ w: WKWebView) {
            onMessage(.error(message: "The visualization stopped working.", line: 0))
        }
    }
}
