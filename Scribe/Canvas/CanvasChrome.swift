import SwiftUI

extension View {
    /// The floating glass behind the canvas controls (material before iOS 26).
    @ViewBuilder
    func canvasChrome<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        }
    }
}

enum CanvasChromeMetrics {
    static let button: CGFloat = 44
    static let iconSize: CGFloat = 17
}

/// A round floating button, like Back and the keyboard toggle.
struct ChromeCircleButton: View {
    let title: String
    let symbol: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CanvasChromeMetrics.iconSize, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
                .background(isOn ? Color.accentColor : .clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .canvasChrome(Circle())
        .accessibilityLabel(title)
    }
}

/// An icon button inside a capsule.
struct ChromeIconButton: View {
    let title: String
    let symbol: String
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CanvasChromeMetrics.iconSize, weight: .semibold))
                .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : Color.primary)
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

// MARK: - Agent control

/// The circle at the top for talking to the agent. While the agent listens or works, it becomes Stop.
struct AgentControl: View {
    let state: AgentState
    let action: () -> Void

    private static let size: CGFloat = 52

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: state == .idle)) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                ZStack {
                    if state == .listening {
                        ForEach(0..<2) { i in
                            let phase = (t / 1.6 + Double(i) / 2).truncatingRemainder(dividingBy: 1)
                            Circle()
                                .stroke(Landing.blue.opacity(0.45 * (1 - phase)), lineWidth: 2)
                                .frame(width: Self.size, height: Self.size)
                                .scaleEffect(1 + 0.5 * phase)
                        }
                    }

                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 0.25, green: 0.6, blue: 1), Landing.blue],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: Self.size, height: Self.size)
                        .shadow(color: Landing.blue.opacity(0.35), radius: 10, y: 4)

                    if state == .thinking {
                        Circle()
                            .trim(from: 0, to: 0.28)
                            .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .frame(width: Self.size - 10, height: Self.size - 10)
                            .rotationEffect(.radians(t * 4))
                    }

                    Image(systemName: state == .idle ? "waveform" : "stop.fill")
                        .font(.system(size: state == .idle ? 20 : 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: Self.size + 26, height: Self.size + 26)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state == .idle ? "Talk to the agent" : "Stop the agent")
        .animation(.snappy, value: state)
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
            .canvasChrome(Capsule())
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
            Button("Settings", action: openSettings).secondaryGlassButton()
            Button("Try Again", action: retry).prominentGlassButton()
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
                        Button(option) { choose(option) }.secondaryGlassButton()
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
            Image(systemName: "photo").foregroundStyle(.secondary)
            Text("Drag to move. Pinch or drag the corner to resize.").lineLimit(1)
            Spacer(minLength: 4)
            Button("Cancel", action: cancel).secondaryGlassButton()
            Button("Place", action: place).prominentGlassButton()
        }
    }
}

// MARK: - Bottom row

/// "Page X of Y"; opens the Pages panel.
struct PagePill: View {
    let current: Int
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("Page \(current) of \(count)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 18)
                .frame(height: CanvasChromeMetrics.button)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .canvasChrome(Capsule())
        .accessibilityHint("Shows all pages")
    }
}

/// Pen, Highlighter, Eraser and Lasso, then colour swatches and Add Colour.
struct ToolBar: View {
    @Bindable var model: CanvasModel
    let editColour: (ColourTarget) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(CanvasTool.allCases) { tool in
                if tool == .eraser { eraser } else { toolButton(tool) }
            }

            Divider().frame(height: 26).padding(.horizontal, 6)

            ForEach(Array(model.swatches.enumerated()), id: \.offset) { index, hex in
                swatch(index, hex: hex)
            }

            Button("Add Colour", systemImage: "plus") { editColour(.add) }
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: CanvasChromeMetrics.button)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .canvasChrome(Capsule())
    }

    private func toolButton(_ tool: CanvasTool) -> some View {
        Button { model.tool = tool } label: { toolIcon(tool) }
            .buttonStyle(.plain)
            .accessibilityLabel(tool.title)
            .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
    }

    /// Tap to pick the eraser; touch and hold to choose stroke or pixel.
    private var eraser: some View {
        Menu {
            Picker("Eraser", selection: $model.eraserMode) {
                Label("Stroke Eraser", systemImage: "scribble").tag(EraserMode.stroke)
                Label("Pixel Eraser", systemImage: "eraser.line.dashed").tag(EraserMode.pixel)
            }
        } label: {
            toolIcon(.eraser)
        } primaryAction: {
            model.tool = .eraser
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(model.eraserMode == .stroke ? "Stroke Eraser" : "Pixel Eraser")
        .accessibilityAddTraits(model.tool == .eraser ? .isSelected : [])
    }

    private func toolIcon(_ tool: CanvasTool) -> some View {
        let selected = model.tool == tool
        return Image(systemName: tool == .eraser && model.eraserMode == .pixel ? "eraser.line.dashed" : tool.symbol)
            .font(.system(size: 18, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(width: 40, height: 36)
            .background(selected ? Color.accentColor : .clear, in: Capsule())
            .frame(height: CanvasChromeMetrics.button)
            .contentShape(Rectangle())
    }

    /// Tap to pick the colour; touch and hold to edit or remove it.
    private func swatch(_ index: Int, hex: String) -> some View {
        let selected = model.selectedSwatch == index && (model.tool == .pen || model.tool == .highlighter)
        return Menu {
            Button("Edit Colour", systemImage: "eyedropper") { editColour(.edit(index)) }
            Button("Remove", systemImage: "trash", role: .destructive) { model.removeSwatch(index) }
                .disabled(model.swatches.count <= 1)
        } label: {
            Circle()
                .fill(Color(uiColor: UIColor(hex: hex)))
                .frame(width: 24, height: 24)
                .overlay(Circle().stroke(.primary.opacity(0.15), lineWidth: 1))
                .padding(3)
                .overlay(Circle().stroke(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                .frame(width: 36, height: CanvasChromeMetrics.button)
                .contentShape(Rectangle())
        } primaryAction: {
            model.selectSwatch(index)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Colour \(index + 1)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Which swatch the colour picker is changing.
enum ColourTarget: Identifiable, Equatable {
    case add
    case edit(Int)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let i): "edit-\(i)"
        }
    }
}

/// The type-to-agent field.
struct AgentTextField: View {
    @Binding var text: String
    var focused: FocusState<Bool>.Binding
    let send: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Ask the agent…", text: $text)
                .font(.system(size: 17, weight: .regular, design: .rounded))
                .focused(focused)
                .submitLabel(.send)
                .onSubmit(send)
            Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Landing.blue)
                .buttonStyle(.plain)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.leading, 20)
        .padding(.trailing, 8)
        .frame(height: 52)
        .frame(maxWidth: 600)
        .canvasChrome(Capsule())
    }
}
