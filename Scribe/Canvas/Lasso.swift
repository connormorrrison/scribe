import PencilKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - What's selected

/// A loop drawn with the lasso on one page: the region it encloses (which can hold printed text, photos or nothing
/// at all), and the person's strokes inside it. Page points.
struct LassoSelection: Equatable {
    var pageID: UUID
    /// The loop, closed.
    var path: [CGPoint]
    /// Indices into the page's `drawing.strokes`.
    var strokes: IndexSet

    var bounds: CGRect { LassoGeometry.bounds(of: path) }
    var hasInk: Bool { !strokes.isEmpty }

    func translated(by offset: CGSize) -> LassoSelection {
        var moved = self
        moved.path = path.map { CGPoint(x: $0.x + offset.width, y: $0.y + offset.height) }
        return moved
    }
}

/// Where a tap with the lasso offers to paste copied ink.
struct PasteSpot: Equatable {
    var pageID: UUID
    var point: CGPoint
}

/// What the person asks the agent about a lassoed region.
enum LassoAction: Equatable {
    /// One rung of the help ladder (1 to `HelpLadder.top`): a nudge, then the next step, then the full explanation.
    case help(level: Int)
    case visualize
    /// They spoke or typed with a region selected: their words are about it.
    case ask

    var title: String {
        switch self {
        case .help(let level): level <= 1 ? "Help" : level == 2 ? "More Help" : "Explain It"
        case .visualize: "Visualize"
        case .ask: "Ask"
        }
    }

    var symbol: String {
        switch self {
        case .help(let level): level <= 1 ? "lifepreserver" : level == 2 ? "stairs" : "text.bubble"
        case .visualize: "cube.transparent"
        case .ask: "questionmark.bubble"
        }
    }

    /// What goes in the conversation as the person's turn.
    var request: String {
        switch self {
        case .help(let level):
            level <= 1 ? "Help me with this part of my page." : level == 2 ? "I need more help with this." : "Explain this one fully."
        case .visualize: "Visualize this part of my page."
        case .ask: ""
        }
    }
}

/// Help gets fuller each time it's asked for on the same spot: a nudge, then the next step, then the whole thing.
struct HelpLadder {
    static let top = 3

    private var last: (pageID: UUID, bounds: CGRect, level: Int)?

    /// The level Help would give for this region now: one more than last time if it's the same spot, else 1.
    func level(for pageID: UUID, bounds: CGRect) -> Int {
        guard let last, last.pageID == pageID, Self.sameSpot(last.bounds, bounds) else { return 1 }
        return min(last.level + 1, Self.top)
    }

    mutating func climbed(to level: Int, pageID: UUID, bounds: CGRect) {
        last = (pageID, bounds, level)
    }

    /// Mostly overlapping: the overlap covers at least half of the smaller box.
    static func sameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return false }
        let smaller = max(min(a.width * a.height, b.width * b.height), 1)
        return overlap.width * overlap.height / smaller >= 0.5
    }
}

/// A region sent to the agent with a request.
struct LassoFocus {
    var pageID: UUID
    var bounds: CGRect
    var action: LassoAction

    /// Just the visualization tool: a visualization request shouldn't write on the page.
    var drawsOnPage: Bool { action != .visualize }

    /// What the agent reads beside the close-up, after the page map.
    func instructions(objects: [PageObject]) -> String {
        let box = "[\(n(bounds.minX)), \(n(bounds.minY)), \(n(bounds.width)), \(n(bounds.height))]"
        let near = "{\"box\": \(box)}"
        let beside = "beside it with write (near \(near), side right, or the free space closest to it)"
        var lines = ["They drew a lasso around part of the page: the box \(box) in page points, shown close up in "
                     + "the next picture."]
        if objects.isEmpty {
            lines.append("Nothing in the page map falls inside it; read it from the close-up.")
        } else {
            lines.append("Inside it: " + objects.map { o in
                let text = String((o.text ?? "").prefix(80))
                return text.isEmpty ? "\(o.id) (\(o.kind))" : "\(o.id) (\(o.kind)) “\(text)”"
            }.joined(separator: "; ") + ".")
        }
        switch action {
        case .help(let level):
            lines.append("""
                They pressed Help: level \(min(max(level, 1), HelpLadder.top)) of \(HelpLadder.top). Help gets fuller \
                each time they ask about the same spot, so they learn by doing as much as they can themselves. First \
                decide what it is. If it's a problem they're working on (their ink inside the box is their working), \
                follow the level below. If it's something to understand rather than solve (printed text, a \
                definition, a diagram, a concept), just explain it clearly at any level: the key idea in a few short \
                lines \(beside), and a small labelled sketch with draw if a picture makes it clearer.
                """)
            switch level {
            case ...1:
                lines.append("""
                    Level 1, a nudge: don't give any steps or the answer. Write a hint \(beside): the idea they're \
                    missing, or a question that points them the right way, in two or three short lines. Then say one \
                    short, encouraging line about what to try, and that they can press Help again for more.
                    """)
            case 2:
                lines.append("""
                    Level 2, the next step: your earlier hint for this spot is in YOUR MARKS; build on it, don't \
                    repeat it. If their working goes wrong somewhere, circle that spot and say why in a few words. \
                    Then write just the next step \(beside), with a small diagram from draw if it helps. Still don't \
                    give the final answer. Say one short line about what to do next.
                    """)
            default:
                lines.append("""
                    Level 3, the full explanation: your earlier help for this spot is in YOUR MARKS; build on it, \
                    don't repeat it. Work it through to the answer \(beside), step by step, a few short lines a step \
                    (use draw for a worked layout or diagram if it's clearer), and point out the idea that makes it \
                    work. Then say in a line what to remember for next time.
                    """)
            }
        case .visualize:
            lines.append("""
                They want it visualized. Call \(VisualizationTool.name) with something to play with that shows the \
                idea in the box, built from what's actually there (its numbers, functions, shapes or words). Don't \
                write on the page.
                """)
        case .ask:
            lines.append("What they said is about this part of the page. If you write an answer on the page, put it beside it (near \(near)).")
        }
        return lines.joined(separator: "\n")
    }

    /// The page objects mostly inside the region, for the agent (lines rather than words; figures, not their parts).
    func objects(in snapshot: PageMapSnapshot) -> [PageObject] {
        snapshot.objects.filter { o in
            guard !["word", "part", "area"].contains(o.kind), o.source != .card else { return false }
            let overlap = o.bounds.intersection(bounds)
            guard !overlap.isNull else { return false }
            let area = max(o.bounds.width * o.bounds.height, 1)
            return overlap.width * overlap.height / area > 0.5
        }
        .prefix(30).map { $0 }
    }

    private func n(_ v: CGFloat) -> String { String(Int(v.rounded())) }
}

// MARK: - Geometry

enum LassoGeometry {
    static func bounds(of path: [CGPoint]) -> CGRect {
        guard let first = path.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in path {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even-odd point in polygon.
    static func contains(_ path: [CGPoint], _ point: CGPoint) -> Bool {
        guard path.count > 2 else { return false }
        var inside = false
        var j = path.count - 1
        for i in path.indices {
            let a = path[i], b = path[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// The strokes with at least half their length inside the loop.
    static func strokes(in path: [CGPoint], of drawing: PKDrawing) -> IndexSet {
        let box = bounds(of: path)
        var picked = IndexSet()
        for (i, stroke) in drawing.strokes.enumerated() where stroke.renderBounds.intersects(box) {
            var total = 0, inside = 0
            for point in stroke.path.interpolatedPoints(by: .distance(4)) {
                total += 1
                if contains(path, point.location.applying(stroke.transform)) { inside += 1 }
            }
            if total > 0, inside * 2 >= total { picked.insert(i) }
        }
        return picked
    }

    /// A loop drawn in page points, closed and simplified (points closer than `spacing` are dropped).
    static func simplified(_ points: [CGPoint], spacing: CGFloat = 2) -> [CGPoint] {
        var out: [CGPoint] = []
        for p in points {
            if let last = out.last, hypot(p.x - last.x, p.y - last.y) < spacing { continue }
            out.append(p)
        }
        return out
    }
}

// MARK: - Copy and paste

enum InkPasteboard {
    static let type = "app.scribe.ink"

    static var hasInk: Bool { UIPasteboard.general.contains(pasteboardTypes: [type]) }

    /// The strokes for Scribe, and a picture of them for other apps.
    static func copy(_ drawing: PKDrawing) {
        var item: [String: Any] = [type: drawing.dataRepresentation()]
        let bounds = drawing.bounds.insetBy(dx: -8, dy: -8)
        if let png = lightImage(drawing, bounds: bounds, scale: 2).pngData() { item[UTType.png.identifier] = png }
        UIPasteboard.general.setItems([item])
    }

    static func read() -> PKDrawing? {
        UIPasteboard.general.data(forPasteboardType: type).flatMap { try? PKDrawing(data: $0) }
    }
}

// MARK: - On the page

/// The selection on one page: the loop, dashed, and a bar of what to do with it. Drag inside the loop to move the
/// ink in it. Only the loop and the bar take touches, so a new loop can be drawn anywhere else.
struct LassoOverlay: View {
    let model: CanvasModel
    let selection: LassoSelection
    /// Screen points per page point.
    let scale: CGFloat
    let pageSize: CGSize

    @State private var drag: CGSize = .zero
    @State private var dragging = false

    var body: some View {
        let offset = CGSize(width: drag.width / scale, height: drag.height / scale)
        let shown = selection.translated(by: offset)
        let box = shown.bounds

        ZStack(alignment: .topLeading) {
            if let lifted = model.liftedInk {
                let inkBounds = lifted.bounds.insetBy(dx: -4, dy: -4)
                Image(uiImage: lightImage(lifted, bounds: inkBounds, scale: scale * 2))
                    .resizable()
                    .frame(width: inkBounds.width * scale, height: inkBounds.height * scale)
                    .offset(x: (inkBounds.minX + offset.width) * scale, y: (inkBounds.minY + offset.height) * scale)
                    .allowsHitTesting(false)
            }

            loop(shown.path)
                .fill(Color.accentColor.opacity(0.06))
                .allowsHitTesting(false)
            loop(shown.path)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [6, 5]))
                .allowsHitTesting(false)

            if selection.hasInk {
                Color.clear
                    .frame(width: box.width * scale, height: box.height * scale)
                    .contentShape(Rectangle())
                    .offset(x: box.minX * scale, y: box.minY * scale)
                    .gesture(move)
                    .accessibilityElement()
                    .accessibilityLabel("Selected ink")
                    .accessibilityHint("Drag to move.")
            }

            if !dragging {
                LassoActionBar(model: model, selection: selection)
                    .fixedSize()
                    .position(barPosition(for: box))
                    .transition(.opacity)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .coordinateSpace(name: Self.space)
        .animation(.snappy(duration: 0.2), value: dragging)
    }

    private static let space = "lassoSelection"

    private var move: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if !dragging {
                    dragging = true
                    model.liftSelection()
                }
                drag = value.translation
            }
            .onEnded { value in
                model.dropSelection(by: CGSize(width: value.translation.width / scale,
                                               height: value.translation.height / scale))
                drag = .zero
                dragging = false
            }
    }

    private func loop(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
            for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x * scale, y: p.y * scale)) }
            path.closeSubpath()
        }
    }

    /// Below the loop, or above it when there's no room below; kept on the page.
    private func barPosition(for box: CGRect) -> CGPoint {
        let half: CGFloat = 230
        let x = min(max(box.midX * scale, half), max(half, pageSize.width - half))
        let below = box.maxY * scale + 40
        let above = box.minY * scale - 40
        let y = below < pageSize.height - 40 || above < 40 ? min(below, pageSize.height - 30) : above
        return CGPoint(x: x, y: y)
    }
}

/// Ask the agent (Help, which gets fuller each time on the same spot, and Visualize), then Cut, Copy and Delete for the ink.
struct LassoActionBar: View {
    let model: CanvasModel
    let selection: LassoSelection

    private var hasInk: Bool { selection.hasInk }

    var body: some View {
        HStack(spacing: 0) {
            ForEach([model.helpAction(for: selection), .visualize], id: \.title) { action in
                Button {
                    withAnimation(.snappy) { model.ask(action) }
                } label: {
                    Label(action.title, systemImage: action.symbol)
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .padding(.horizontal, 12)
                        .frame(height: CanvasChromeMetrics.button)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Rectangle()
                .fill(.primary.opacity(0.18))
                .frame(width: 1, height: 24)
                .padding(.horizontal, 4)
            ChromeButton(title: "Cut", symbol: "scissors", disabled: !hasInk) {
                withAnimation(.snappy) { model.cutSelection() }
            }
            ChromeButton(title: "Copy", symbol: "doc.on.doc", disabled: !hasInk) { model.copySelection() }
            ChromeButton(title: "Delete", symbol: "trash", disabled: !hasInk) {
                withAnimation(.snappy) { model.deleteSelection() }
            }
        }
        .padding(.horizontal, 4)
        .canvasChrome(Capsule())
    }
}

/// Offered where the lasso tapped, when there's ink to paste.
struct InkPasteButton: View {
    let model: CanvasModel
    let spot: PasteSpot
    let scale: CGFloat

    var body: some View {
        Button {
            withAnimation(.snappy) { model.paste(at: spot) }
        } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
                .font(.system(size: 15, weight: .regular, design: .rounded))
                .padding(.horizontal, 16)
                .frame(height: CanvasChromeMetrics.button)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .canvasChrome(Capsule())
        .fixedSize()
        .position(x: spot.point.x * scale, y: spot.point.y * scale - 36)
    }
}

// MARK: - Drawing the loop

/// Draws the lasso loop on a page's canvas and hands it to the model when the stroke ends. While the lasso is the
/// tool, PencilKit's own drawing is off, so this is what the Pencil (and a finger, with finger drawing on) does.
@MainActor
final class LassoTracker: NSObject {
    let pan: UIPanGestureRecognizer
    private let layer = CAShapeLayer()
    private var points: [CGPoint] = []
    var scale: CGFloat = 1
    var finished: ([CGPoint]) -> Void = { _ in }

    override init() {
        pan = UIPanGestureRecognizer()
        super.init()
        pan.addTarget(self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        layer.fillColor = UIColor.tintColor.withAlphaComponent(0.06).cgColor
        layer.strokeColor = UIColor.tintColor.cgColor
        layer.lineWidth = 1.5
        layer.lineDashPattern = [6, 5]
        layer.lineCap = .round
        layer.lineJoin = .round
    }

    func attach(to view: UIView) {
        view.addGestureRecognizer(pan)
        view.layer.addSublayer(layer)
    }

    func setEnabled(_ enabled: Bool, fingers: Bool) {
        if pan.isEnabled != enabled { pan.isEnabled = enabled }
        var types = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        if fingers { types.append(NSNumber(value: UITouch.TouchType.direct.rawValue)) }
        if pan.allowedTouchTypes != types { pan.allowedTouchTypes = types }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let view = pan.view, scale > 0 else { return }
        let p = pan.location(in: view)
        switch pan.state {
        case .began:
            points = [CGPoint(x: p.x / scale, y: p.y / scale)]
            layer.frame = view.bounds
        case .changed:
            points.append(CGPoint(x: p.x / scale, y: p.y / scale))
            let path = UIBezierPath()
            path.move(to: CGPoint(x: points[0].x * scale, y: points[0].y * scale))
            for q in points.dropFirst() { path.addLine(to: CGPoint(x: q.x * scale, y: q.y * scale)) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.path = path.cgPath
            CATransaction.commit()
        case .ended:
            layer.path = nil
            finished(LassoGeometry.simplified(points))
            points = []
        default:
            layer.path = nil
            points = []
        }
    }
}
