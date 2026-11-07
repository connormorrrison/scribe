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
/// agent…" field when the person types instead of talking.
struct AgentControl: View {
    @Bindable var model: CanvasModel
    var openSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    private var state: AgentState { model.agent }
    private var typing: Bool { model.showsKeyboard && state == .idle }
    private var expanded: Bool { typing || state != .idle }
    private var showsStop: Bool { !typing && state != .idle }

    /// What the bar shows. A change of mode gets the livelier spring.
    private enum Mode: Hashable { case dot, line, field }
    private var mode: Mode { typing ? .field : (expanded ? .line : .dot) }

    private static let fieldWidth: CGFloat = 320
    private static let lineFont = UIFont.systemFont(ofSize: 15, weight: .regular)
        .withDesign(.rounded)

    private var barWidth: CGFloat {
        if typing { return Self.fieldWidth }
        guard expanded else { return CanvasChromeMetrics.button }
        let w = ceil((model.agentLine as NSString).size(withAttributes: [.font: Self.lineFont]).width)
        return min(300, max(168, CanvasChromeMetrics.button + w + 16 + (showsStop ? CanvasChromeMetrics.button : 0)))
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                AgentOrb(listening: state == .listening, reduceMotion: reduceMotion)
                    .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
                    .modifier(OrbGather(trigger: mode, reduceMotion: reduceMotion))
                if expanded && !typing {
                    Text(model.agentLine)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(state == .thinking ? .secondary : .primary)
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
            .accessibilityHint(state == .idle ? "Touch and hold for more options" : "")

            if typing {
                typeField
                    .frame(width: Self.fieldWidth - CanvasChromeMetrics.button)
                    .transition(reveal)
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
            guard now else { fieldFocused = false; return }
            // Let the bar open before the keyboard rises.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 220))
                if typing { fieldFocused = true }
            }
        }
        .onChange(of: fieldFocused) { _, focused in
            // Tapped away from an empty field: fold back into the dot.
            if !focused, typing, draft.trimmingCharacters(in: .whitespaces).isEmpty { model.showsKeyboard = false }
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
            TextField("Ask the agent…", text: $draft)
                .font(.system(size: 15, weight: .regular, design: .rounded))
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

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        model.send(text)
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

/// The blue dot with its halo. While listening, the halo and core breathe.
struct AgentOrb: View {
    var listening: Bool
    var reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: !listening || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let level = listening && !reduceMotion ? (sin(t * 4) + 1) / 2 : 0
            ZStack {
                Circle().fill(Landing.blue.opacity(0.16)).frame(width: 28, height: 28)
                    .scaleEffect(listening ? 0.75 + 0.45 * level : 1)
                Circle().fill(Landing.blue).frame(width: 20, height: 20)
                    .scaleEffect(listening ? 0.85 + 0.3 * level : 1)
            }
        }
        .accessibilityHidden(true)
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

struct PlacementBanner: View {
    let cancel: () -> Void
    let place: () -> Void

    var body: some View {
        CanvasBannerBar {
            Text("Drag to move. Pinch or drag the corner to resize.")
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button("Cancel", action: cancel).secondaryActionButton()
            Button("Place", action: place).primaryActionButton().fontWeight(.semibold)
        }
    }
}

// MARK: - Bottom row

/// "1 / 3", which opens the Pages popover, and + to add a page after this one.
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

/// Past the last page: a fresh sheet of paper that becomes a real page when the swipe lands on it.
struct NewPagePlaceholder: View {
    let background: PageBackground
    let size: CGSize

    var body: some View {
        ZStack {
            Color.white
            FadingPageBackground(style: background, size: size,
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

/// Pen, Highlighter, Eraser and Lasso. With the pen or highlighter, that tool's colours and the colour well follow.
struct ToolBar: View {
    let palette: ToolPalette
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

