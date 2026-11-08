import SwiftUI

/// The agent's visualizations, hovering over the page in the top right, just under the top buttons: newest at the
/// bottom, scrolling once there are more than fit. The page underneath is exactly as it is without them.
///
/// Drag a card's title bar up and down to scroll the cards, or flick it right to tuck them away; a tab
/// stays on the screen's edge, and tapping it or flicking it left brings them back. A new visualization always brings
/// them back.
struct VisualizationStack: View {
    let model: CanvasModel
    let screen: CGSize
    /// The room between the floating chrome above and below, in points from the top.
    let top: CGFloat
    let bottom: CGFloat

    /// How far the cards have been dragged toward the edge, mid-flick.
    @State private var drag: CGFloat = 0
    /// The cards' own height, so the stack only covers the page where there are cards.
    @State private var contentHeight: CGFloat = 0
    /// How far the cards are scrolled, and how far the drag in progress is taking them.
    @State private var scroll: CGFloat = 0
    @State private var scrollDrag: CGFloat = 0
    /// Which way the drag in progress is going: it scrolls or it flicks, never both.
    @State private var axis: Axis?

    /// Room around the cards, for their shadows.
    private static let margin: CGFloat = 16

    /// How wide a card is on a screen `width` wide.
    static func cardWidth(for width: CGFloat) -> CGFloat {
        min(400, max(300, (width * 0.34).rounded()))
    }

    private var shown: Bool { model.showsVisualizations }
    private var width: CGFloat { Self.cardWidth(for: screen.width) + 2 * Self.margin }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            cards
                .floatingOverPage("visualizations", in: model)
                .offset(x: shown ? max(0, drag) : width + 24)
                .allowsHitTesting(shown)
            if !shown {
                tab.floatingOverPage("visualizationsTab", in: model)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(width: screen.width, height: screen.height, alignment: .topTrailing)
        .animation(.snappy, value: shown)
    }

    /// The room the cards have, margins included.
    private var room: CGFloat { max(0, bottom - top + 2 * Self.margin) }
    /// How far the cards can scroll.
    private var maxScroll: CGFloat { max(0, contentHeight - room) }

    private var cards: some View {
        // Not lazy, and not a system scroll view (around web views it paints over the page): every card keeps running,
        // and the stack scrolls by its title bars (`grab`).
        VStack(spacing: 16) {
            ForEach(Array(model.content.visualizations.enumerated()), id: \.element.id) { index, visualization in
                if closed?.index == index { closedRow }
                VisualizationCard(model: model, visualization: visualization, grab: grab)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if let closed, closed.index >= model.content.visualizations.count { closedRow }
            if model.draftingVisualization {
                VisualizationPlaceholder()
                    .transition(.opacity)
            }
        }
        .padding(Self.margin)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        .offset(y: -min(max(scroll + scrollDrag, 0), maxScroll))
        // Only as tall as the cards (up to the room there is). Scrolled cards pass under the floating chrome, as the
        // page does; they aren't clipped, since clipping a web view paints over the page around it.
        .frame(width: width, height: min(contentHeight, room), alignment: .top)
        .padding(.top, top - Self.margin)
        .onChange(of: model.content.visualizations.last?.id) { old, new in
            guard new != nil, new != old else { return }
            showNewest()
        }
        .onChange(of: model.draftingVisualization) { _, drafting in
            if drafting { showNewest() }
        }
        .onChange(of: maxScroll) { _, limit in scroll = min(scroll, limit) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Visualizations")
        .accessibilityAction(named: "Hide Visualizations") { model.showsVisualizations = false }
        .accessibilityScrollAction { edge in
            withAnimation(.snappy) {
                scroll = min(max(scroll + (edge == .top ? -room * 0.8 : room * 0.8), 0), maxScroll)
            }
        }
    }

    /// The card just closed, unless it's already back (Undo in the toolbar).
    private var closed: ClosedVisualization? {
        guard let closed = model.closedVisualization,
              !model.content.visualizations.contains(where: { $0.id == closed.visualization.id }) else { return nil }
        return closed
    }

    /// Where a closed card was, for a few seconds: its title, and Undo to bring it back.
    private var closedRow: some View {
        HStack(spacing: 8) {
            Text("Closed “\(closed?.visualization.title ?? "")”")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                withAnimation(.snappy) { model.reopenClosedVisualization() }
            } label: {
                Text("Undo")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Landing.card)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Undo Close") { model.reopenClosedVisualization() }
    }

    /// Scrolls to the bottom, where the newest card (or the one on its way) is, once it's been laid out.
    private func showNewest() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            withAnimation(.snappy) { scroll = maxScroll }
        }
    }

    /// A drag on a card's title bar. Up and down scrolls the cards (with a little momentum); a drag to
    /// the right pulls them toward the edge, and they go if it's flicked or pulled far enough.
    private var grab: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if axis == nil {
                    axis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                }
                if axis == .horizontal {
                    drag = max(0, value.translation.width)
                } else {
                    scrollDrag = -value.translation.height
                }
            }
            .onEnded { value in
                let horizontal = axis == .horizontal
                axis = nil
                withAnimation(.snappy) {
                    if horizontal {
                        if value.predictedEndTranslation.width > 160 || value.translation.width > width * 0.4 {
                            model.showsVisualizations = false
                        }
                        drag = 0
                    } else {
                        scroll = min(max(scroll - value.predictedEndTranslation.height, 0), maxScroll)
                        scrollDrag = 0
                    }
                }
            }
    }

    /// While the cards are away: a tab on the right edge with how many there are. Tap it, or flick it left, to bring
    /// them back.
    private var tab: some View {
        Button {
            model.showsVisualizations = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.compact.left")
                Text("\(model.content.visualizations.count)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .canvasChrome(Capsule())
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onEnded { value in
                    if value.translation.width < -20 || value.predictedEndTranslation.width < -80 {
                        model.showsVisualizations = true
                    }
                }
        )
        .padding(.top, top)
        .padding(.trailing, 16)
        .accessibilityLabel("Show Visualizations")
        .accessibilityValue("\(model.content.visualizations.count)")
    }
}

/// One visualization: a dark card with its title, Pause, More (Remake, Replay, Enlarge) and Close, then the page
/// itself (which draws its own live readout under the picture). All of it on the card, so it reads the same over any
/// page.
struct VisualizationCard<Grab: Gesture>: View {
    let model: CanvasModel
    let visualization: Visualization
    /// Scrolls the cards, or flicks them away, from the title bar.
    let grab: Grab

    private var paused: Bool { model.pausedVisualizations.contains(visualization.id) }
    private var remaking: Bool { model.remakingVisualizations.contains(visualization.id) }

    var body: some View {
        VStack(spacing: 0) {
                VisualizationHeader(title: visualization.title) {
                    PauseButton(paused: paused) { model.togglePauseVisualization(visualization.id) }
                    StageMenu(title: "More", symbol: "ellipsis") {
                        Button("Remake", systemImage: "sparkles") { model.remakeVisualization(visualization.id) }
                            .disabled(remaking)
                        Button("Replay", systemImage: "arrow.counterclockwise") {
                            model.replayVisualization(visualization.id)
                        }
                        Button("Enlarge", systemImage: "arrow.up.left.and.arrow.down.right") {
                            model.enlargedVisualization = visualization
                        }
                    }
                    StageButton(title: "Close", symbol: "xmark") {
                        withAnimation(.snappy) { model.closeVisualization(visualization.id) }
                    }
                }
                .contentShape(Rectangle())
                .gesture(grab)
                WebCardView(html: visualization.html, reload: model.visualizationReloads[visualization.id] ?? 0,
                            paused: paused,
                            onSnapshot: { model.visualizationSnapshot($0, for: visualization.id) }) { message in
                    model.visualizationMessage(message, from: visualization.id)
                }
                .frame(height: visualization.height)
                .overlay(alignment: .bottom) { StageError(message: model.visualizationErrors[visualization.id]) }
                .overlay { if remaking { RemakingCover().transition(.opacity) } }
                .animation(.snappy, value: remaking)
                .padding(.bottom, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        // The shadow belongs to a plain shape behind the card: shadowing the card itself (it holds a web view) makes
        // SwiftUI flatten the scroll area into an opaque layer that hides the page around it.
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Landing.card)
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(visualization.title)
    }
}

/// The card's title row on the dark stage: the title, with buttons at the end.
struct VisualizationHeader<Buttons: View>: View {
    let title: String
    @ViewBuilder var buttons: Buttons

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.leading, 16)
            Spacer(minLength: 8)
            buttons
        }
        .padding(.trailing, 4)
        .frame(height: 48)
    }
}

/// Pause and play for a card's page.
struct PauseButton: View {
    let paused: Bool
    let action: () -> Void

    var body: some View {
        StageButton(title: paused ? "Play" : "Pause", symbol: paused ? "play.fill" : "pause.fill", action: action)
            .contentTransition(.symbolEffect(.replace))
    }
}

/// A menu on the dark stage that looks like a `StageButton`.
struct StageMenu<Items: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            StageSymbol(symbol: symbol)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Over a card while the agent remakes it: the old page dimmed, with a spinner.
struct RemakingCover: View {
    var body: some View {
        ZStack {
            Landing.card.opacity(0.82)
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Remaking it simpler…")
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The look of a stage button: a 30 pt circle, with a 44 pt target.
struct StageSymbol: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.12), in: Circle())
            .frame(width: 40, height: 44)
            .contentShape(Rectangle())
    }
}

/// A plain icon button on the dark stage: a 30 pt circle, with a 44 pt target.
struct StageButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StageSymbol(symbol: symbol)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// What went wrong on a page, at the bottom of its stage.
struct StageError: View {
    let message: String?

    var body: some View {
        if let message {
            Text("This visualization hit a problem: \(message)")
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(2)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .padding(10)
        }
    }
}

/// Where the next visualization will appear, while the agent writes it.
struct VisualizationPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().tint(.white)
            Text("Making a visualization…")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .background(Landing.card.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// A visualization filling the screen. The page starts over at the larger size.
struct EnlargedVisualization: View {
    let model: CanvasModel
    let visualization: Visualization
    @Environment(\.dismiss) private var dismiss
    @State private var reload = 0
    @State private var paused = false

    var body: some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 64, 1000)
            let height = min(geo.size.height - 64 - 48, width * 0.75)
            VStack(spacing: 0) {
                VisualizationHeader(title: visualization.title) {
                    PauseButton(paused: paused) { paused.toggle() }
                    StageButton(title: "Replay", symbol: "arrow.counterclockwise") { reload += 1; paused = false }
                    StageButton(title: "Done", symbol: "arrow.down.right.and.arrow.up.left") { dismiss() }
                }
                WebCardView(html: visualization.html, reload: reload, paused: paused) { message in
                    // The card in the stack keeps its own height, and its own pause.
                    if case .resize = message { return }
                    if case .paused(let p) = message { paused = p; return }
                    model.visualizationMessage(message, from: visualization.id)
                }
                .frame(height: height)
            }
            .frame(width: width)
            .background(Landing.card)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black.opacity(0.88).ignoresSafeArea())
    }
}
