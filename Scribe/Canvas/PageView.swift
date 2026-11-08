import PencilKit
import SwiftUI

/// One page, edge to edge: paper and background (or a PDF page), photos, the agent's ink, the person's ink, the agent's cards, and a photo being
/// placed. Everything is laid out in page points and scaled by `width / NotePageMetrics.width`.
struct PageView: View {
    let model: CanvasModel
    let page: NotePage
    let width: CGFloat
    let background: PageBackground
    let drawWithFinger: Bool
    /// Pinch and double-tap on the page, for a page that zooms.
    var zoom: PageZoomGestures? = nil

    private var k: CGFloat { width / NotePageMetrics.width }

    var body: some View {
        let size = CGSize(width: width, height: page.height * k)

        ZStack(alignment: .topLeading) {
            Color.white
            if let index = page.pdfPage, let url = model.pdfURL {
                PDFPageView(url: url, page: index, width: size.width)
                    .frame(width: size.width, height: size.height)
            } else {
                PageBackgroundView(style: background, regions: [CGRect(origin: .zero, size: size)],
                                   spacing: NotePageMetrics.backgroundSpacing * k)
            }

            ForEach(page.images) { placed in
                if let image = model.image(named: placed.fileName) {
                    PlacedImageView(image: image, placed: placed, scale: k)
                        // The selected image is drawn by its overlay, above the ink, while it's being edited.
                        .opacity(model.selectedImage?.imageID == placed.id ? 0 : 1)
                }
            }

            if !page.agentDrawing.strokes.isEmpty {
                AgentInkImage(drawing: page.agentDrawing, bounds: page.bounds, scale: k)
                    .frame(width: size.width, height: size.height)
                    .allowsHitTesting(false)
            }

            InkCanvas(model: model, pageID: page.id, scale: k, pageHeight: page.height, drawWithFinger: drawWithFinger,
                      reloadToken: model.reloadToken, zoom: zoom)
                .frame(width: size.width, height: size.height)

            ForEach(page.cards) { card in
                AgentCardView(model: model, card: card, scale: k)
                    .offset(x: card.frame.minX * k, y: card.frame.minY * k)
            }

            if let selection = model.selectedImage, selection.pageID == page.id,
               let placed = model.placedImage(selection), let image = model.image(named: placed.fileName) {
                ImageSelectionOverlay(model: model, selection: selection, placed: placed, image: image, scale: k,
                                      pageSize: size)
                    .frame(width: size.width, height: size.height)
                    .id(placed.id)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .accessibilityElement(children: .contain)
    }
}

/// What a zooming page does with a pinch or double-tap on its paper.
///
/// - `began(anchor, fingers)`: `anchor` is the point under the fingers in the page view's own laid-out points;
///   `fingers` is where they are in window points. Called again, with no anchor, whenever a finger lifts or lands
///   mid-pinch (the pinch's centre moves; the page works out what's under it now).
/// - `changed(scale, fingers)`: `scale` is relative to the last `began`; `fingers` in window points.
struct PageZoomGestures {
    var began: (CGPoint?, CGPoint) -> Void
    var changed: (CGFloat, CGPoint) -> Void
    var ended: () -> Void
    var doubleTapped: (CGPoint) -> Void
}

/// A placed image, rotated about its centre. `scale` is screen points per page point.
struct PlacedImageView: View {
    let image: UIImage
    let placed: PlacedImage
    let scale: CGFloat

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: placed.frame.width * scale, height: placed.frame.height * scale)
            .rotationEffect(.radians(placed.rotation))
            .position(x: placed.frame.midX * scale, y: placed.frame.midY * scale)
            .allowsHitTesting(false)
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
    /// Passed in (rather than only read from the model) so undo always updates the canvas.
    let reloadToken: Int
    var zoom: PageZoomGestures?

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
        // A finger tap selects the image under it (or clears the selection). It never stops ink.
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        canvas.addGestureRecognizer(tap)
        // Pinch and double-tap to zoom (pages that zoom pass `zoom`). Fingers only; the Pencil always draws.
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = context.coordinator
        canvas.addGestureRecognizer(pinch)
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = context.coordinator
        canvas.addGestureRecognizer(doubleTap)
        return canvas
    }

    func updateUIView(_ canvas: ScribeCanvasView, context: Context) {
        let coordinator = context.coordinator
        coordinator.model = model
        coordinator.pageID = pageID
        coordinator.scale = scale
        coordinator.zoom = zoom

        if canvas.minimumZoomScale != scale || canvas.zoomScale != scale {
            canvas.minimumZoomScale = scale
            canvas.maximumZoomScale = scale
            canvas.zoomScale = scale
        }
        let contentSize = CGSize(width: NotePageMetrics.width * scale, height: pageHeight * scale)
        if canvas.contentSize != contentSize { canvas.contentSize = contentSize }
        if canvas.contentOffset != .zero { canvas.contentOffset = .zero }

        // Only when they change: this runs on every update of the page, and handing PencilKit a tool is not free.
        let tool = model.palette.pencilKitTool
        if !coordinator.isCurrent(tool) { canvas.tool = tool }
        let policy: PKCanvasViewDrawingPolicy = drawWithFinger ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }

        if coordinator.token != reloadToken { coordinator.load(into: canvas) }
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
        var model: CanvasModel
        var pageID: UUID
        var token = -1
        var scale: CGFloat = 1
        var zoom: PageZoomGestures?
        private var loading = false
        /// What `load` last put on the canvas, until the person changes it. PencilKit can report a drawing it was
        /// just given as a change; that echo isn't an edit.
        private var loaded: PKDrawing?

        init(model: CanvasModel, pageID: UUID) {
            self.model = model
            self.pageID = pageID
        }

        /// Puts the model's ink on the canvas. Always as a new drawing: a `PKDrawing` keeps its identity across
        /// edits, and given an older version of the drawing it's showing (after an undo), PencilKit merges the newer
        /// strokes back in on the next stroke, bringing undone ink back.
        @MainActor func load(into canvas: PKCanvasView) {
            loading = true
            let fresh = PKDrawing(strokes: model.page(pageID)?.drawing.strokes ?? [])
            canvas.drawing = fresh
            loaded = fresh
            token = model.reloadToken
            loading = false
        }

        @MainActor @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view, scale > 0 else { return }
            let point = tap.location(in: view)
            model.tapPage(pageID, at: CGPoint(x: point.x / scale, y: point.y / scale))
        }

        @MainActor @objc func pinched(_ pinch: UIPinchGestureRecognizer) {
            guard let zoom, let view = pinch.view else { return }
            switch pinch.state {
            case .began:
                pauseScrolling(around: view)
                restart(pinch, in: view, zoom: zoom, continuing: false)
            case .changed:
                // A finger lifting or landing moves the pinch's centre; start again from here so the page doesn't jump.
                if pinch.numberOfTouches != pinchTouches { restart(pinch, in: view, zoom: zoom, continuing: true) }
                zoom.changed(pinch.scale / pinchStartScale, pinch.location(in: nil))
            case .ended, .cancelled, .failed:
                resumeScrolling()
                zoom.ended()
            default: break
            }
        }

        private var pinchTouches = 0
        private var pinchStartScale: CGFloat = 1
        /// The scroll views (the page's own, and the pager) whose panning is paused for the pinch.
        private var paused: [UIScrollView] = []

        @MainActor private func restart(_ pinch: UIPinchGestureRecognizer, in view: UIView, zoom: PageZoomGestures,
                                        continuing: Bool) {
            pinchTouches = pinch.numberOfTouches
            pinchStartScale = max(pinch.scale, 0.01)
            zoom.began(continuing ? nil : pinch.location(in: view), pinch.location(in: nil))
        }

        /// While pinching, the pinch alone moves the page. Left on, the page's scroll view also panned with the two
        /// fingers (and kept coasting from an earlier flick), moving the page under the anchor; at 1x, the pager
        /// could turn the page mid-pinch.
        @MainActor private func pauseScrolling(around view: UIView) {
            resumeScrolling()
            var next = view.superview
            var first = true
            while let current = next {
                if let scroll = current as? UIScrollView, scroll.panGestureRecognizer.isEnabled {
                    // Stops a flick's coasting on the page's own scroll view (not the pager's, which must land on a page).
                    if first, scroll.isDecelerating { scroll.setContentOffset(scroll.contentOffset, animated: false) }
                    scroll.panGestureRecognizer.isEnabled = false
                    paused.append(scroll)
                }
                if current is UIScrollView { first = false }
                next = current.superview
            }
        }

        @MainActor private func resumeScrolling() {
            // As the scroll view itself says: SwiftUI may have turned its scrolling off meanwhile.
            for scroll in paused { scroll.panGestureRecognizer.isEnabled = scroll.isScrollEnabled }
            paused = []
        }

        private var currentTool: PKTool?

        /// Whether `tool` is what the canvas already has (and if not, remembers it as the canvas's tool).
        func isCurrent(_ tool: PKTool) -> Bool {
            defer { currentTool = tool }
            switch (currentTool, tool) {
            case let (a as PKInkingTool, b as PKInkingTool): return a == b
            case let (a as PKEraserTool, b as PKEraserTool): return a == b
            case (is PKLassoTool, is PKLassoTool): return true
            default: return false
            }
        }

        @MainActor @objc func doubleTapped(_ tap: UITapGestureRecognizer) {
            guard let zoom, let view = tap.view else { return }
            zoom.doubleTapped(tap.location(in: view))
        }

        /// The tap works alongside drawing (with finger drawing on, a tap is also a dot of ink).
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        /// Starting to draw or erase puts the selected image down.
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            MainActor.assumeIsolated { model.selectedImage = nil }
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !loading else { return }
            let drawing = canvasView.drawing
            if let loaded {
                if drawing.strokes.count == loaded.strokes.count, drawing.bounds == loaded.bounds { return }
                self.loaded = nil
            }
            MainActor.assumeIsolated {
                model.canvasChanged(page: pageID, drawing: drawing)
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

// MARK: - Editing an image

/// The selected image, above the ink: drag to move, pinch or drag the corner to resize, twist or drag the top handle
/// to rotate. Arrange, Delete and Done float below it. Each finished gesture is one undo step.
private struct ImageSelectionOverlay: View {
    let model: CanvasModel
    let selection: ImageSelection
    let placed: PlacedImage
    let image: UIImage
    /// Screen points per page point.
    let scale: CGFloat
    let pageSize: CGSize

    // What the gesture in progress has done so far.
    @State private var drag: CGSize = .zero
    @State private var zoom: CGFloat = 1
    @State private var turn: Double = 0
    /// While the rotate handle is dragged: the rotation it points to.
    @State private var handleRotation: Double?

    private static let minSide: CGFloat = 40
    private static let snap = 0.07

    /// The image as it is right now, gesture included, in page points.
    private var frame: CGRect {
        let base = placed.frame
        let aspect = base.height / max(base.width, 1)
        let minWidth = Self.minSide / min(1, aspect)
        let width = min(max(base.width * zoom, minWidth), NotePageMetrics.width * 2)
        let size = CGSize(width: width, height: width * aspect)
        let center = CGPoint(x: base.midX + drag.width / scale, y: base.midY + drag.height / scale)
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                      width: size.width, height: size.height)
    }

    private var rotation: Double { Self.snapped(handleRotation ?? placed.rotation + turn) }

    /// The centre in this view's (screen) space.
    private var screenCenter: CGPoint { CGPoint(x: frame.midX * scale, y: frame.midY * scale) }

    var body: some View {
        let f = frame
        let current = PlacedImage(fileName: placed.fileName, frame: f, rotation: rotation)

        ZStack(alignment: .topLeading) {
            Image(uiImage: image)
                .resizable()
                .frame(width: f.width * scale, height: f.height * scale)
                .overlay { Rectangle().strokeBorder(Color.accentColor, lineWidth: 2) }
                .overlay(alignment: .top) { rotateHandle }
                .overlay(alignment: .bottomTrailing) { resizeHandle }
                .contentShape(Rectangle())
                .gesture(moveScaleRotate)
                .rotationEffect(.radians(rotation))
                .position(screenCenter)
                .accessibilityElement()
                .accessibilityLabel("Selected image")
                .accessibilityHint("Drag to move. Pinch to resize. Twist to rotate.")

            actions
                .position(actionsPosition(for: current.bounds))
        }
        .coordinateSpace(name: Self.space)
    }

    private static let space = "imageSelection"

    // MARK: Gestures

    private var moveScaleRotate: some Gesture {
        // Measured in the overlay's space, which stays still. In the image's own space (the default), the image
        // moving under the finger changes the measurement, and the image shakes.
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .simultaneously(with: MagnifyGesture().simultaneously(with: RotateGesture()))
            .onChanged { value in
                drag = value.first?.translation ?? .zero
                zoom = value.second?.first?.magnification ?? 1
                turn = value.second?.second?.rotation.radians ?? 0
            }
            .onEnded { _ in commit(toFront: drag != .zero) }
    }

    /// Scales about the centre: the image grows as the handle moves away from the centre.
    private var resizeHandle: some View {
        handle(symbol: "arrow.up.left.and.arrow.down.right")
            .offset(x: 14, y: 14)
            .gesture(
                DragGesture(coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        let c = screenCenter
                        let start = hypot(value.startLocation.x - c.x, value.startLocation.y - c.y)
                        let now = hypot(value.location.x - c.x, value.location.y - c.y)
                        if start > 1 { zoom = now / start }
                    }
                    .onEnded { _ in commit() }
            )
            .accessibilityLabel("Resize")
    }

    /// Points the top of the image at the finger. Snaps to upright and to quarter turns.
    private var rotateHandle: some View {
        VStack(spacing: 0) {
            handle(symbol: "arrow.clockwise")
            Rectangle().fill(Color.accentColor).frame(width: 2, height: 16)
        }
        .offset(y: -44)
        .gesture(
            DragGesture(coordinateSpace: .named(Self.space))
                .onChanged { value in
                    let c = screenCenter
                    handleRotation = atan2(value.location.y - c.y, value.location.x - c.x) + .pi / 2
                }
                .onEnded { _ in commit() }
        )
        .accessibilityLabel("Rotate")
    }

    private func handle(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: 28, height: 28)
            .background(.white, in: Circle())
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }

    private func commit(toFront: Bool = false) {
        let f = frame, r = rotation
        drag = .zero
        zoom = 1
        turn = 0
        handleRotation = nil
        guard f != placed.frame || abs(r - placed.rotation) > 0.0001 else { return }
        model.transformImage(selection, frame: f, rotation: r, toFront: toFront)
    }

    private static func snapped(_ angle: Double) -> Double {
        let quarter = Double.pi / 2
        let nearest = (angle / quarter).rounded() * quarter
        return abs(angle - nearest) < snap ? nearest : angle
    }

    // MARK: Arrange, Delete and Done

    private var actions: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach([ImageArrangement.front, .forward, .backward, .back], id: \.self) { arrangement in
                    Button(arrangement.title, systemImage: arrangement.symbol) {
                        withAnimation(.snappy) { model.arrangeImage(selection, arrangement) }
                    }
                    .disabled(!model.canArrange(selection, arrangement))
                }
            } label: {
                ChromeSymbol(symbol: "square.3.layers.3d")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel("Arrange")
            ChromeButton(title: "Delete Image", symbol: "trash") {
                withAnimation(.snappy) { model.deleteImage(selection) }
            }
            ChromeButton(title: "Done", symbol: "checkmark") {
                withAnimation(.snappy) { model.selectedImage = nil }
            }
        }
        .padding(.horizontal, 4)
        .canvasChrome(Capsule())
    }

    /// Below the image, or above it (clear of the rotate handle) when there's no room below.
    private func actionsPosition(for bounds: CGRect) -> CGPoint {
        let x = min(max(bounds.midX * scale, 90), pageSize.width - 90)
        let below = bounds.maxY * scale + 44
        let above = bounds.minY * scale - 84
        let y = below < pageSize.height - 110 || above < 90 ? below : above
        return CGPoint(x: x, y: y)
    }
}
