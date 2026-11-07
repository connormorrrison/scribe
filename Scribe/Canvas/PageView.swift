import PencilKit
import SwiftUI

/// One page, edge to edge: paper and background, photos, the agent's ink, the person's ink, the agent's cards, and a photo being
/// placed. Everything is laid out in page points and scaled by `width / NotePageMetrics.width`.
struct PageView: View {
    let model: CanvasModel
    let page: NotePage
    let width: CGFloat
    let background: PageBackground
    let drawWithFinger: Bool

    private var k: CGFloat { width / NotePageMetrics.width }

    var body: some View {
        let size = CGSize(width: width, height: page.height * k)

        ZStack(alignment: .topLeading) {
            Color.white
            PageBackgroundView(style: background, regions: [CGRect(origin: .zero, size: size)],
                               spacing: NotePageMetrics.backgroundSpacing * k)

            ForEach(page.images) { placed in
                if let image = model.image(named: placed.fileName) {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: placed.frame.width * k, height: placed.frame.height * k)
                        .offset(x: placed.frame.minX * k, y: placed.frame.minY * k)
                }
            }

            if !page.agentDrawing.strokes.isEmpty {
                AgentInkImage(drawing: page.agentDrawing, bounds: page.bounds, scale: k)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }

            InkCanvas(model: model, pageID: page.id, scale: k, pageHeight: page.height, drawWithFinger: drawWithFinger)
                .frame(width: size.width, height: size.height)
                // While a photo is being placed, the page is for positioning it.
                .allowsHitTesting(model.placement == nil)

            ForEach(page.cards) { card in
                AgentCardView(model: model, card: card, scale: k)
                    .offset(x: card.frame.minX * k, y: card.frame.minY * k)
            }

            if let placement = model.placement, placement.pageID == page.id {
                PlacementOverlay(model: model, placement: placement, scale: k)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityElement(children: .contain)
    }
}

/// The agent's ink, rendered once per change.
private struct AgentInkImage: View {
    let drawing: PKDrawing
    let bounds: CGRect
    let scale: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Image(uiImage: lightImage(drawing, bounds: bounds, scale: scale * displayScale))
            .resizable()
    }
}

/// Renders ink in light mode (pages are always white, so ink never inverts).
func lightImage(_ drawing: PKDrawing, bounds: CGRect, scale: CGFloat) -> UIImage {
    var image = UIImage()
    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
        image = drawing.image(from: bounds, scale: scale)
    }
    return image
}

// MARK: - Ink

/// Undo goes through the note's own undo manager (whole-page snapshots), so PencilKit doesn't register its own.
final class ScribeCanvasView: PKCanvasView {
    override var undoManager: UndoManager? { nil }
}

/// The person's ink on one page, drawn with PencilKit at page scale.
struct InkCanvas: UIViewRepresentable {
    let model: CanvasModel
    let pageID: UUID
    let scale: CGFloat
    let pageHeight: CGFloat
    let drawWithFinger: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model, pageID: pageID) }

    func makeUIView(context: Context) -> ScribeCanvasView {
        let canvas = ScribeCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = context.coordinator
        context.coordinator.load(into: canvas)
        return canvas
    }

    func updateUIView(_ canvas: ScribeCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.pageID = pageID

        if canvas.minimumZoomScale != scale || canvas.zoomScale != scale {
            canvas.minimumZoomScale = scale
            canvas.maximumZoomScale = scale
            canvas.zoomScale = scale
        }
        let contentSize = CGSize(width: NotePageMetrics.width * scale, height: pageHeight * scale)
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        canvas.contentOffset = .zero

        canvas.tool = model.palette.pencilKitTool
        canvas.drawingPolicy = drawWithFinger ? .anyInput : .pencilOnly

        if coordinator.token != model.reloadToken { coordinator.load(into: canvas) }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var model: CanvasModel
        var pageID: UUID
        var token = -1
        private var loading = false

        init(model: CanvasModel, pageID: UUID) {
            self.model = model
            self.pageID = pageID
        }

        @MainActor func load(into canvas: PKCanvasView) {
            loading = true
            canvas.drawing = model.page(pageID)?.drawing ?? PKDrawing()
            token = model.reloadToken
            loading = false
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !loading else { return }
            MainActor.assumeIsolated {
                model.canvasChanged(page: pageID, drawing: canvasView.drawing)
                token = model.reloadToken
            }
        }
    }
}

// MARK: - Cards

/// A visualization the agent made: Play/Pause and Stop if it's animated, Enlarge and Close, and a resize handle.
struct AgentCardView: View {
    let model: CanvasModel
    let card: AgentCard
    let scale: CGFloat
    @State private var resize: CGSize = .zero

    var body: some View {
        let width = max(AgentCard.minimumSize.width * scale, card.frame.width * scale + resize.width)
        let height = max(AgentCard.minimumSize.height * scale, card.frame.height * scale + resize.height)

        CardFace(card: card, clock: model.clock(for: card.id), artScale: width / card.designWidth) {
            HStack(spacing: 4) {
                if card.isAnimated {
                    let playing = model.clock(for: card.id)?.isPlaying ?? false
                    CardButton(title: playing ? "Pause" : "Play", symbol: playing ? "pause.fill" : "play.fill") {
                        model.togglePlay(card.id)
                    }
                    CardButton(title: "Stop", symbol: "stop.fill") { model.stopAnimation(card.id) }
                    Divider().frame(height: 18).overlay(Color.white.opacity(0.25)).padding(.horizontal, 4)
                }
                CardButton(title: "Enlarge", symbol: "arrow.up.left.and.arrow.down.right") {
                    model.enlargedCard = card
                }
                CardButton(title: "Close", symbol: "xmark") {
                    withAnimation(.snappy) { model.closeCard(card.id) }
                }
            }
        }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) { resizeHandle }
    }

    private var resizeHandle: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.8))
            .frame(width: 28, height: 28)
            .background(.white.opacity(0.14), in: Circle())
            .padding(8)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { resize = $0.translation }
                    .onEnded { value in
                        let size = CGSize(width: card.frame.width + value.translation.width / scale,
                                          height: card.frame.height + value.translation.height / scale)
                        resize = .zero
                        model.resizeCard(card.id, to: size)
                    }
            )
            .accessibilityLabel("Resize")
    }
}

/// The dark card with a title row and the art, shared by the page, the enlarged view and PDF export.
struct CardFace<Accessory: View>: View {
    let card: AgentCard
    let clock: AnimationClock?
    let artScale: CGFloat
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(card.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(height: AgentCard.headerHeight)

            CardArt(card: card, clock: clock, scale: artScale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Landing.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 16, y: 10)
    }
}

extension CardFace where Accessory == EmptyView {
    init(card: AgentCard, clock: AnimationClock?, artScale: CGFloat) {
        self.init(card: card, clock: clock, artScale: artScale) { EmptyView() }
    }
}

/// The card's moving art, paused unless its clock is running.
struct CardArt: View {
    let card: AgentCard
    let clock: AnimationClock?
    let scale: CGFloat

    var body: some View {
        TimelineView(.animation(paused: !(clock?.isPlaying ?? false))) { context in
            let time = clock?.time(at: context.date) ?? 0
            switch card.kind {
            case .atom: AtomArt(time: time, s: scale)
            case .tangent: TangentArt(time: time, s: scale)
            }
        }
    }
}

private struct CardButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(title, systemImage: symbol, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.14), in: Circle())
            .contentShape(Circle())
            .buttonStyle(.plain)
    }
}

// MARK: - Placing a photo

/// The photo being positioned: drag to move, pinch or drag the corner to resize.
private struct PlacementOverlay: View {
    let model: CanvasModel
    let placement: ImagePlacement
    let scale: CGFloat
    @State private var drag: CGSize = .zero
    @State private var zoom: CGFloat = 1

    var body: some View {
        let frame = placement.frame
        let size = CGSize(width: frame.width * scale * zoom, height: frame.height * scale * zoom)

        Image(uiImage: placement.image)
            .resizable()
            .frame(width: size.width, height: size.height)
            .overlay {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
            }
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.white, lineWidth: 2))
                    .offset(x: 11, y: 11)
                    .gesture(
                        DragGesture()
                            .onChanged { zoom = max(0.1, 1 + $0.translation.width / max(size.width / zoom, 1)) }
                            .onEnded { _ in model.scalePlacement(by: zoom); zoom = 1 }
                    )
                    .accessibilityLabel("Resize")
            }
            .position(x: frame.midX * scale + drag.width, y: frame.midY * scale + drag.height)
            .gesture(
                DragGesture()
                    .onChanged { drag = $0.translation }
                    .onEnded { value in
                        model.movePlacement(by: CGSize(width: value.translation.width / scale,
                                                       height: value.translation.height / scale))
                        drag = .zero
                    }
                    .simultaneously(with:
                        MagnifyGesture()
                            .onChanged { zoom = $0.magnification }
                            .onEnded { model.scalePlacement(by: $0.magnification); zoom = 1 }
                    )
            )
    }
}
