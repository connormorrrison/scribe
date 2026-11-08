import SwiftUI

extension View {
    /// The floating glass behind the canvas controls (material with a hairline before iOS 26). `interactive` glass
    /// reacts to touch; use it for controls, not for bars that only hold controls.
    @ViewBuilder
    func canvasChrome<S: InsettableShape>(_ shape: S, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
}

/// Controls that belong together float in one container, so on iOS 26 their glass is sampled together and shapes
/// that appear or disappear morph out of their neighbours (Apple's Liquid Glass guidance). Separate groups keep
/// `CanvasChromeMetrics.groupGap` between them, wider than `blend`, so at rest they read as distinct pieces.
struct ChromeGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: CanvasChromeMetrics.blend) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Names a piece of glass so it morphs in and out of its group (iOS 26), or scales and fades (before).
    @ViewBuilder
    func chromeGlassID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            glassEffectID(id, in: namespace)
        } else {
            transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }
}

enum CanvasChromeMetrics {
    /// Space between separate glass groups.
    static let groupGap: CGFloat = 12
    /// How close two pieces of glass get before they start to merge.
    static let blend: CGFloat = 8
    /// The spring for glass changing shape.
    static let morph = Animation.spring(response: 0.38, dampingFraction: 0.8)
    static let button: CGFloat = 44
}

/// A 44 x 44 pt SF Symbol button at the system's default symbol size. Selected, it's tinted on a soft tint circle.
struct ChromeButton: View {
    let title: String
    let symbol: String
    var selected = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { ChromeSymbol(symbol: symbol, selected: selected) }
            .buttonStyle(.plain)
            .disabled(disabled)
            .opacity(disabled ? 0.35 : 1)
            .accessibilityLabel(title)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The look of a `ChromeButton`, for menus that need the same label.
struct ChromeSymbol: View {
    let symbol: String
    var selected = false

    var body: some View {
        Image(systemName: symbol)
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
            .background {
                if selected { Circle().fill(Color.accentColor.opacity(0.15)).padding(2) }
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Agent control

/// A 44 pt dot at the top. It widens into a slim bar while the agent listens or works, and into the "Ask the
/// agent…" field when the person types instead of talking. A spoken answer streams through it in time with the
/// voice; an answer that isn't spoken goes in `AgentReplyBar`, just below.
struct AgentControl: View {
    @Bindable var model: CanvasModel
    var openSettings: () -> Void
    var openHistory: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool

    private var state: AgentState { model.agent }
    private var typing: Bool { model.showsKeyboard && state == .idle }
    /// The agent's spoken answer, while it's in the bar.
    private var shownReply: AgentReply? {
        guard !typing, state == .idle || state == .speaking, let reply = model.reply, reply.spoken else { return nil }
        return reply
    }
    /// The person's words, while they're speaking.
    private var hearing: Bool { state == .listening && !model.heard.isEmpty }
    private var streaming: Bool { shownReply != nil || hearing }
    private var expanded: Bool { typing || state != .idle || shownReply != nil }
    /// Stop ends whatever the agent is doing: listening, thinking or speaking.
    private var showsStop: Bool { !typing && (state != .idle || shownReply != nil) }

    /// What the bar shows. A change of mode gets the livelier spring.
    private enum Mode: Hashable { case dot, line, field, reply }
    private var mode: Mode {
        if typing { return .field }
        if streaming { return .reply }
        return expanded ? .line : .dot
    }

    /// The field is as wide as the reply bar under it, so the question and the answer line up.
    private static let fieldWidth: CGFloat = AgentReplyBar.width
    private static let replyWidth: CGFloat = 400
    /// The base body size, as in the rest of the app.
    static let textSize: CGFloat = 17
    private static let lineFont = UIFont.systemFont(ofSize: textSize, weight: .regular)
        .withDesign(.rounded)

    private var barWidth: CGFloat {
        if typing { return Self.fieldWidth }
        if streaming { return Self.replyWidth }
        guard expanded else { return CanvasChromeMetrics.button }
        let w = ceil((model.agentLine as NSString).size(withAttributes: [.font: Self.lineFont]).width)
        return min(300, max(168, CanvasChromeMetrics.button + w + 16 + (showsStop ? CanvasChromeMetrics.button : 0)))
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                AgentOrb(model: model, responding: state == .thinking || state == .speaking || shownReply != nil,
                         reduceMotion: reduceMotion)
                    .modifier(OrbGather(trigger: mode, reduceMotion: reduceMotion))
                if expanded && !typing && !streaming {
                    ShimmerText(text: model.agentLine, shimmering: state == .thinking, reduceMotion: reduceMotion)
                        .font(.system(size: Self.textSize, weight: .regular, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .id(model.agentLine)
                        .transition(.opacity)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, 12)
                        .transition(reveal)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if typing { fieldFocused = true } else { model.toggleAgent() }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state == .idle ? "Talk to the agent" : model.agentLine)
            .accessibilityAddTraits([.isButton, .updatesFrequently])
            .accessibilityHint(state == .idle ? "Touch and hold for more options"
                               : state == .listening ? "Double-tap when you're done talking" : "Double-tap to stop")

            if typing {
                typeField
                    .frame(width: Self.fieldWidth - CanvasChromeMetrics.button)
                    .transition(reveal)
            }

            if hearing {
                // Tap when you're done talking, like the dot.
                StreamingLine(words: AgentReply.words(in: model.heard), reduceMotion: reduceMotion)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { model.toggleAgent() }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.heard)
                    .accessibilityHint("Double-tap when you're done talking")
                    .accessibilityAddTraits([.isButton, .updatesFrequently])
                    .transition(.opacity)
            }

            if let reply = shownReply {
                // Tap for the whole answer in History.
                ReplyStream(reply: reply, reduceMotion: reduceMotion) { model.dismissReply() }
                    .padding(.trailing, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        model.dismissReply()
                        openHistory()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(reply.text)
                    .accessibilityHint("Double-tap to see it in History")
                    .accessibilityAddTraits(.isButton)
                    .transition(.opacity)
            }

            if showsStop {
                ChromeButton(title: "Stop", symbol: "stop.fill") { model.stopAgent() }
                    .transition(.opacity)
            }
        }
        .frame(width: barWidth, height: CanvasChromeMetrics.button, alignment: .leading)
        .clipShape(Capsule())
        .canvasChrome(Capsule())
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: barWidth)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.72),
                   value: mode)
        .animation(.easeInOut(duration: 0.2), value: showsStop)
        .animation(.easeInOut(duration: 0.2), value: model.agentLine)
        .onChange(of: typing) { _, now in
            if !now { fieldFocused = false }
        }
        .onChange(of: model.showsKeyboard) { _, now in
            // Asked to type: let the bar open before the keyboard rises. When the field comes back after an answer,
            // the keyboard stays down until the person taps in to follow up.
            guard now else { return }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 220))
                if typing { fieldFocused = true }
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            // Tapped away from an empty field: fold back into the dot. Not while an answer is under it: the two go
            // together, and the person may just be putting the keyboard down to read.
            if !focused, typing, !canSend, model.textReply == nil { model.showsKeyboard = false }
        }
        .contextMenu {
            if state == .idle {
                Button("Type Instead", systemImage: "keyboard") { model.showsKeyboard = true }
                Button("Agent Settings", systemImage: "gearshape", action: openSettings)
            }
        }
    }

    /// Content slides out of the dot: it drifts right, sharpens and fades in; on the way back it just fades.
    private var reveal: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: OutOfTheDot(progress: 0), identity: OutOfTheDot(progress: 1))
                .animation(.smooth(duration: 0.4).delay(0.1)),
            removal: .opacity.animation(.easeIn(duration: 0.1)))
    }

    private var typeField: some View {
        HStack(spacing: 0) {
            TextField(model.textReply == nil ? "Ask the agent…" : "Reply…", text: $model.draft)
                .font(.system(size: Self.textSize, weight: .regular, design: .rounded))
                .focused($fieldFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .frame(maxWidth: .infinity, minHeight: CanvasChromeMetrics.button)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(canSend ? Landing.blue : Color.secondary)
                    .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .animation(.easeOut(duration: 0.15), value: canSend)
        }
    }

    private var canSend: Bool { !model.draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func send() {
        guard canSend else { return }
        let text = model.draft
        model.draft = ""
        model.send(text)
    }
}

/// Text with a band of light sweeping across it, left to right, while something is in progress (as shadcn's
/// Shimmer does): muted text, brightening as the band passes. Without `shimmering`, plain primary text.
private struct ShimmerText: View {
    let text: String
    let shimmering: Bool
    let reduceMotion: Bool

    /// One sweep, then the next straight after.
    private static let period = 2.0
    /// The band's width, as a share of the text's.
    private static let band = 0.5

    var body: some View {
        if shimmering && !reduceMotion {
            TimelineView(.animation) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period)
                    / Self.period
                Text(text)
                    .foregroundStyle(.secondary)
                    .overlay {
                        Text(text)
                            .foregroundStyle(.primary)
                            .mask { sweep(at: phase) }
                    }
            }
        } else {
            Text(text).foregroundStyle(shimmering ? .secondary : .primary)
        }
    }

    /// The band, travelling from just before the text's start to just past its end.
    private func sweep(at phase: Double) -> some View {
        GeometryReader { geo in
            let width = geo.size.width * Self.band
            LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: width)
                .offset(x: -width + phase * (geo.size.width + width))
        }
    }
}

/// One line of words in the agent bar, growing at its right end. Words appear in place, filling the line from the
/// left. Once it's full, each new word moves the line over by just that word, so the oldest slips out under the fade
/// at the left edge as the newest arrives. Used for the agent's answer and for the person's words as they speak.
private struct StreamingLine: View {
    let words: [String]
    let reduceMotion: Bool

    @State private var lineWidth: CGFloat = 0
    @State private var available: CGFloat = 0

    /// How far the line has moved left to keep the newest word in view.
    private var shift: CGFloat { min(0, available - lineWidth) }

    var body: some View {
        // The space is measured on its own, and the line laid over it, so the line can be wider than the bar
        // without widening it.
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
            .overlay(alignment: .leading) { line.offset(x: shift) }
            .clipped()
            // Only once words have started to leave: the oldest fade out rather than being cut off.
            .mask {
                LinearGradient(stops: [.init(color: shift < 0 ? .clear : .black, location: 0),
                                       .init(color: .black, location: 0.15)],
                               startPoint: .leading, endPoint: .trailing)
            }
    }

    private var line: some View {
        HStack(spacing: 5) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                Text(word)
                    .transition(reduceMotion ? .opacity
                                : .modifier(active: WordAppearing(shown: false), identity: WordAppearing(shown: true)))
            }
        }
        .font(.system(size: AgentControl.textSize, weight: .regular, design: .rounded))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { lineWidth = $0 }
    }
}

/// The agent's spoken answer streaming into the bar one word at a time, as each word is said. A moment after the
/// last word, `finished` folds the bar back into the dot.
private struct ReplyStream: View {
    let reply: AgentReply
    let reduceMotion: Bool
    let finished: () -> Void

    @State private var shown = 0

    var body: some View {
        StreamingLine(words: Array(reply.words.prefix(shown)), reduceMotion: reduceMotion)
            .task(id: reply.id) { await play() }
    }

    private func play() async {
        AccessibilityNotification.Announcement(reply.text).post()
        let words = reply.words
        let starts = reply.wordStarts ?? []
        let clock = ContinuousClock()
        let began = clock.now
        shown = 0
        for index in words.indices where index < starts.count {
            // Timed from when the reply appeared, so a late word doesn't push the rest later.
            let due = began + .milliseconds(Int(starts[index] * 1000))
            guard (try? await clock.sleep(until: due)) != nil else { return }
            withAnimation(reduceMotion ? nil : .smooth(duration: 0.2)) { shown = index + 1 }
        }
        // It was heard as it went: a short beat, then away.
        guard (try? await Task.sleep(for: .seconds(0.9))) != nil else { return }
        finished()
    }
}

/// The agent's answer when it isn't spoken (to something typed, or asked of a lasso), just under the agent control.
/// One line for a short answer, growing to three at most; the whole answer is a tap away in History. It holds still
/// to be read at the person's own pace, and stays until they move on: tapping or writing on the page, flicking it
/// up, closing the field, or asking again (`CanvasModel.moveOn()`). Read Aloud speaks it.
struct AgentReplyBar: View {
    let reply: AgentReply
    let readAloud: () -> Void
    let dismiss: () -> Void
    let openHistory: () -> Void

    /// Narrow enough to clear a visualization card in the top right.
    static let width: CGFloat = 340
    @State private var lift: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Text(reply.text)
                .font(.system(size: AgentControl.textSize, weight: .regular, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                // 11 pt above and below one line makes the 44 pt of the bar above.
                .padding(.vertical, 11)
                .padding(.leading, 20)
                .contentShape(Rectangle())
                .onTapGesture(perform: openHistory)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Double-tap to see it in History")
            ChromeButton(title: "Read Aloud", symbol: "speaker.wave.2", action: readAloud)
                .padding(.trailing, 2)
        }
        .frame(width: Self.width)
        .frame(minHeight: CanvasChromeMetrics.button)
        // A capsule while it's one line; rounded the same at its corners when it grows.
        .canvasChrome(RoundedRectangle(cornerRadius: CanvasChromeMetrics.button / 2, style: .continuous))
        .offset(y: lift)
        .simultaneousGesture(flickUp)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Dismiss", dismiss)
        .task(id: reply.id) { AccessibilityNotification.Announcement(reply.text).post() }
    }

    /// Flicked up, it goes; let go short of that and it settles back.
    private var flickUp: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { lift = min(0, $0.translation.height) }
            .onEnded { drag in
                if drag.translation.height < -24 || drag.predictedEndTranslation.height < -80 {
                    dismiss()
                } else {
                    withAnimation(.snappy) { lift = 0 }
                }
            }
    }
}

/// A word arriving in the bar: it sharpens and fades up where it stands.
private struct WordAppearing: ViewModifier {
    let shown: Bool

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .blur(radius: shown ? 0 : 3)
    }
}

/// The reveal inside the agent bar: 0 is still inside the dot, 1 is settled.
private struct OutOfTheDot: ViewModifier {
    var progress: Double

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 6)
            .offset(x: (1 - progress) * -22)
            .scaleEffect(0.92 + 0.08 * progress, anchor: .leading)
    }
}

/// The agent's control. A microphone while it's yours to talk: an empty outline at rest (tap to talk), filling with
/// blue from the bottom as you speak, full when loud. The blue orb while the agent responds: breathing slowly as it
/// thinks or writes, swelling with its voice as it speaks. The orb stays inside the control however loud it gets.
struct AgentOrb: View {
    let model: CanvasModel
    /// The agent is thinking, speaking, or streaming an answer.
    let responding: Bool
    let reduceMotion: Bool

    var body: some View {
        ZStack {
            if responding {
                orb.transition(.blurReplace)
            } else {
                microphone.transition(.blurReplace)
            }
        }
        .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
        .animation(.smooth(duration: 0.3), value: responding)
        .accessibilityHidden(true)
    }

    // MARK: Microphone

    private var microphone: some View {
        // Only this view reads the level, so the rest of the bar doesn't redraw with every reading.
        let listening = model.agent == .listening
        // With Reduce Motion, no flickering fill: full while it listens.
        let level = listening ? (reduceMotion ? 1 : model.level) : 0
        return ZStack {
            Image(systemName: "mic")
            Image(systemName: "mic.fill")
                .mask(alignment: .bottom) {
                    GeometryReader { geo in
                        Rectangle()
                            .frame(height: geo.size.height * level)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
                // Readings come ten times a second; a quick spring joins them into a smooth rise and fall.
                .animation(.spring(response: 0.14, dampingFraction: 0.75), value: level)
        }
        .imageScale(.large)
        .foregroundStyle(Landing.blue)
    }

    // MARK: Orb

    /// At rest the orb is small, so it has room to move a lot while staying small at its loudest: the halo goes
    /// from 22 to 36 pt and the core from 12 to 20 pt, well inside the 44 pt control.
    private static let core: CGFloat = 12
    private static let halo: CGFloat = 22
    private static let haloGrowth: CGFloat = 36.0 / 22 - 1
    private static let coreGrowth: CGFloat = 20.0 / 12 - 1

    private var orb: some View {
        let speaking = model.agent == .speaking
        return TimelineView(.animation(paused: reduceMotion || speaking)) { context in
            // Thinking or writing: a slow, gentle breath. Speaking: the voice, in full, so loud syllables throw it
            // wide and pauses pull it right back in.
            let breath = (sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.8) + 1) / 2
            let swell = reduceMotion ? 0 : (speaking ? model.level : 0.3 * breath)
            // Flat: two plain blue circles.
            ZStack {
                Circle()
                    .fill(Landing.blue.opacity(0.18))
                    .frame(width: Self.halo, height: Self.halo)
                    .scaleEffect(1 + Self.haloGrowth * swell)
                Circle()
                    .fill(Landing.blue)
                    .frame(width: Self.core, height: Self.core)
                    .scaleEffect(1 + Self.coreGrowth * swell)
            }
            // Quick and lively, so it keeps up with the syllables.
            .animation(.spring(response: 0.12, dampingFraction: 0.6), value: swell)
        }
    }
}

/// The dot gathers itself, then lets the bar out.
private struct OrbGather<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { orb, scale in
            orb.scaleEffect(scale)
        } keyframes: { (_: Double) in
            KeyframeTrack(\.self) {
                CubicKeyframe(reduceMotion ? 1.0 : 0.82, duration: reduceMotion ? 0.001 : 0.11)
                SpringKeyframe(1.0, duration: reduceMotion ? 0.001 : 0.5, spring: .bouncy(duration: 0.45, extraBounce: 0.1))
            }
        }
    }
}

private extension UIFont {
    func withDesign(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        fontDescriptor.withDesign(design).map { UIFont(descriptor: $0, size: pointSize) } ?? self
    }
}

// MARK: - Banners

/// A banner that slides in under the top row.
struct CanvasBannerBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 12) { content }
            .font(.system(size: 15, weight: .regular, design: .rounded))
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(minHeight: 52)
            .frame(maxWidth: 640)
            .canvasChrome(Capsule(), interactive: false)
    }
}

struct ErrorBanner: View {
    let message: String
    let openSettings: () -> Void
    let retry: () -> Void

    var body: some View {
        CanvasBannerBar {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).lineLimit(2)
            Spacer(minLength: 4)
            Button("Settings", action: openSettings).secondaryActionButton()
            Button("Try Again", action: retry).primaryActionButton()
        }
    }
}

/// Something to know, with OK to dismiss it.
struct NoticeBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        CanvasBannerBar {
            Image(systemName: "info.circle.fill").foregroundStyle(.secondary)
            Text(message).lineLimit(2)
            Spacer(minLength: 4)
            Button("OK", action: dismiss).secondaryActionButton()
        }
    }
}

struct ChoiceBanner: View {
    let prompt: String
    let options: [String]
    let choose: (String) -> Void

    var body: some View {
        CanvasBannerBar {
            Image(systemName: "sparkles").foregroundStyle(Landing.blue)
            Text(prompt).lineLimit(1)
            Spacer(minLength: 4)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button(option) { choose(option) }.secondaryActionButton()
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - Bottom row

/// "1 / 3", which opens the Pages popover, and + to add a page after this one.
/// The page dots, as on the home screen: the system page control, so it looks and behaves the standard way (tap a
/// side to step, drag along it to scrub, a platter behind it while you do, shrinking dots for long notes). Hidden
/// for nothing: they show on a one-page note too. The dots are dark because they always sit on paper.
struct PageDots: UIViewRepresentable {
    let count: Int
    let current: Int
    let select: (Int) -> Void

    func makeUIView(context: Context) -> UIPageControl {
        let control = UIPageControl()
        control.hidesForSinglePage = false
        control.backgroundStyle = .automatic
        control.pageIndicatorTintColor = UIColor(white: 0, alpha: 0.2)
        control.currentPageIndicatorTintColor = UIColor(white: 0, alpha: 0.7)
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return control
    }

    func updateUIView(_ control: UIPageControl, context: Context) {
        context.coordinator.select = select
        if control.numberOfPages != count { control.numberOfPages = count }
        if control.currentPage != current { control.currentPage = current }
    }

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    final class Coordinator: NSObject {
        var select: (Int) -> Void
        init(select: @escaping (Int) -> Void) { self.select = select }
        @objc func changed(_ control: UIPageControl) { select(control.currentPage) }
    }
}

struct PagePill: View {
    let current: Int
    let count: Int
    let showPages: () -> Void
    let addPage: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: showPages) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                    Text("\(current) / \(count)")
                        .font(.system(size: 17, weight: .regular, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .foregroundStyle(.primary)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(minHeight: CanvasChromeMetrics.button)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Page \(current) of \(count)")
            .accessibilityHint("Shows page thumbnails")

            Rectangle()
                .fill(.primary.opacity(0.18))
                .frame(width: 1, height: 24)

            ChromeButton(title: "Add Page", symbol: "plus", action: addPage)
                .padding(.trailing, 2)
        }
        .animation(.snappy, value: count)
        .animation(.snappy, value: current)
        .canvasChrome(Capsule())
    }
}

/// Says which page just came on screen, then fades. Floats over the page; never takes a touch.
struct PageChangeLabel: View {
    let current: Int
    let count: Int

    var body: some View {
        Text("Page \(current) of \(count)")
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .padding(.horizontal, 16)
            .frame(height: 36)
            .canvasChrome(Capsule(), interactive: false)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Past the last page: a fresh sheet of paper that becomes a real page when the swipe lands on it.
struct NewPagePlaceholder: View {
    let background: PageBackground
    let size: CGSize

    var body: some View {
        ZStack {
            Color.white
            PageBackgroundView(style: background, regions: [CGRect(origin: .zero, size: size)],
                               spacing: NotePageMetrics.backgroundSpacing * size.width / NotePageMetrics.width)
                .opacity(0.6)
            VStack(spacing: 14) {
                Image(systemName: "plus")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                Text("New Page")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(white: 0.45))
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Page")
        .accessibilityHint("Scroll here to add a page")
    }
}

/// Pen, Highlighter, Eraser, Lasso and Add Image. With the pen or highlighter, that tool's colours and the colour
/// well follow.
struct ToolBar: View {
    let palette: ToolPalette
    let addPhoto: () -> Void
    let addFile: () -> Void
    @State private var editing: InkSwatch?
    @State private var showsPicker = false
    /// The colour the picker added; later picks change it rather than adding more.
    @State private var added: UUID?
    @Namespace private var glass

    /// Two pieces of glass: the tools, and (for the pen and highlighter) that tool's colours, which grow out of the
    /// tools when one of them is picked.
    var body: some View {
        HStack(spacing: CanvasChromeMetrics.groupGap) {
            HStack(spacing: 0) {
                ForEach(CanvasTool.allCases) { tool in
                    if tool == .eraser { eraser } else {
                        ChromeButton(title: tool.title, symbol: tool.symbol, selected: palette.tool == tool) {
                            pick(tool)
                        }
                    }
                }
                Rectangle()
                    .fill(.primary.opacity(0.18))
                    .frame(width: 1, height: 24)
                    .padding(.horizontal, 4)
                addImage
            }
            .padding(.horizontal, 4)
            .canvasChrome(Capsule())
            .chromeGlassID("tools", in: glass)

            if palette.tool.hasSwatches {
                HStack(spacing: 0) {
                    swatchStrip
                    colourWell
                }
                .padding(.horizontal, 4)
                .canvasChrome(Capsule())
                .chromeGlassID("colours", in: glass)
            }
        }
        .animation(CanvasChromeMetrics.morph, value: palette.tool.hasSwatches)
        .animation(CanvasChromeMetrics.morph, value: palette.swatches.count)
        .sheet(item: $editing) { swatch in
            ColourPickerSheet(initial: UIColor(hex: swatch.swatchHex)) { picked in
                palette.replace(swatch.id, with: palette.swatch(from: picked))
            }
        }
    }

    /// Putting a picture on the page is making something, like drawing, so it sits with the tools.
    private var addImage: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle", action: addPhoto)
            Button("Files", systemImage: "folder", action: addFile)
        } label: {
            ChromeSymbol(symbol: "photo.badge.plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Add Image")
    }

    private func pick(_ tool: CanvasTool) {
        withAnimation(CanvasChromeMetrics.morph) { palette.tool = tool }
    }

    /// Tap to pick the eraser; touch and hold to choose stroke or pixel.
    private var eraser: some View {
        let selected = palette.tool == .eraser
        return Menu {
            Picker("Eraser", selection: Bindable(palette).eraserMode) {
                Label(EraserMode.stroke.title, systemImage: "scribble").tag(EraserMode.stroke)
                Label(EraserMode.pixel.title, systemImage: "eraser.line.dashed").tag(EraserMode.pixel)
            }
        } label: {
            ChromeSymbol(symbol: palette.eraserMode == .pixel ? "eraser.line.dashed" : "eraser", selected: selected)
        } primaryAction: {
            pick(.eraser)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(palette.eraserMode.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Up to four colours show; more scroll.
    private var swatchStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(palette.swatches) { swatch in
                    let selected = swatch.id == palette.selectedSwatchID
                    Button { palette.select(swatch) } label: {
                        SwatchDot(swatch: swatch, selected: selected, hairline: palette.tool == .highlighter)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Colour \(swatch.swatchHex)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .contextMenu {
                        Button("Edit Colour", systemImage: "eyedropper") { editing = swatch }
                        Button("Remove", systemImage: "trash", role: .destructive) { palette.remove(swatch) }
                            .disabled(!palette.canRemoveSwatch)
                    }
                }
            }
        }
        .frame(width: CGFloat(min(palette.swatches.count, 4)) * CanvasChromeMetrics.button,
               height: CanvasChromeMetrics.button)
    }

    /// Opens the system colour picker. The first pick adds a colour; later picks change that one.
    private var colourWell: some View {
        Button {
            added = nil
            showsPicker = true
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink,
                                                           .red], center: .center), lineWidth: 3)
                    .frame(width: 26, height: 26)
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Colour")
        .sheet(isPresented: $showsPicker) {
            ColourPickerSheet(initial: UIColor(hex: palette.tool == .highlighter ? "#FFF3A3" : "#007AFF")) { picked in
                let swatch = palette.swatch(from: picked)
                if let added {
                    palette.replace(added, with: swatch)
                } else {
                    palette.add(swatch)
                    added = swatch.id
                }
            }
        }
    }
}

/// A colour in the tool bar. Selected, it gets a tinted ring with a white gap.
struct SwatchDot: View {
    let swatch: InkSwatch
    let selected: Bool
    /// Light highlighter colours need an edge to show on the glass.
    let hairline: Bool

    var body: some View {
        ZStack {
            if selected {
                Circle().strokeBorder(Color.accentColor, lineWidth: 1.5).frame(width: 33, height: 33)
                Circle().fill(.white).frame(width: 29, height: 29)
            }
            Circle()
                .fill(swatch.swatch)
                .frame(width: 26, height: 26)
                .overlay { if hairline { Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5) } }
        }
        .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
        .contentShape(Rectangle())
    }
}

