import CoreGraphics
import Foundation

/// The `draw` tool: simple shapes in their own box, connected and labelled by id, laid out on the page as one mark.
enum DrawBuilder {
    static let defaultSize = CGSize(width: 360, height: 260)
    static let minSize = CGSize(width: 80, height: 60)
    static let maxSize = CGSize(width: 760, height: 560)
    static let maxShapes = 30

    enum Kind: String, CaseIterable { case line, arrow, path, circle, ellipse, rect, text, label }

    /// One end of a line or arrow: a point in the box, or another shape.
    enum End: Equatable {
        case point(CGPoint)
        case shape(String)
    }

    struct Element: Equatable {
        var kind: Kind
        var id: String?
        var color: String
        var dashed = false
        var fill = false
        /// Shapes: their outline in box points. Text: its centre.
        var points: [CGPoint] = []
        var closed = false
        var from: End?
        var to: End?
        var text: String?
        var textSize: CGFloat = 0
        /// A label's shape, and whether it goes inside it.
        var labelFor: String?
        var inside = false
    }

    struct Parsed {
        var elements: [Element]
        var size: CGSize
        /// Some points were outside the box and were pulled in.
        var clamped = false
        var count: Int { elements.count }
        var texts: [String] { elements.compactMap(\.text) }
    }

    // MARK: Parsing

    static func parse(_ shapes: [JSONValue], size: CGSize, labelSize: CGFloat, noteSize: CGFloat) throws -> Parsed {
        guard !shapes.isEmpty else { throw ToolInputError("`shapes` is empty") }
        guard shapes.count <= maxShapes else { throw ToolInputError("that's \(shapes.count) shapes; draw at most \(maxShapes) at a time") }
        let box = CGRect(origin: .zero, size: size)
        var clamped = false
        func pt(_ v: JSONValue?, _ field: String, _ i: Int) throws -> CGPoint {
            guard case .array(let a)? = v, a.count == 2, let x = a[0].number, let y = a[1].number else {
                throw ToolInputError("shape \(i + 1): `\(field)` must be [x, y]")
            }
            let p = CGPoint(x: x, y: y)
            let q = ActionValidator.clamp(p, to: box)
            if q != p { clamped = true }
            return q
        }
        func rect(_ v: JSONValue?, _ i: Int) throws -> CGRect {
            guard case .array(let a)? = v, a.count == 4, let x = a[0].number, let y = a[1].number, let w = a[2].number,
                  let h = a[3].number, w > 0, h > 0 else {
                throw ToolInputError("shape \(i + 1): `box` must be [x, y, w, h] with w and h above 0")
            }
            let r = CGRect(x: x, y: y, width: w, height: h)
            let q = ActionValidator.clamp(r, to: box)
            if q != r { clamped = true }
            return q
        }
        func end(_ v: JSONValue?, _ field: String, _ i: Int) throws -> End {
            if let id = v?.string { return .shape(id) }
            return .point(try pt(v, field, i))
        }

        var elements: [Element] = []
        for (i, shape) in shapes.enumerated() {
            guard case .object = shape, let typeName = shape["type"]?.string else {
                throw ToolInputError("shape \(i + 1) needs a `type` (\(Kind.allCases.map(\.rawValue).joined(separator: ", ")))")
            }
            guard let kind = Kind(rawValue: typeName.lowercased()) else {
                throw ToolInputError("shape \(i + 1): unknown type `\(typeName)`; use \(Kind.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            var e = Element(kind: kind, id: shape["id"]?.string, color: try ActionValidator.parseColor(shape["color"]?.string))
            if case .bool(let dashed)? = shape["dashed"] { e.dashed = dashed }
            if case .bool(let fill)? = shape["fill"] { e.fill = fill }
            switch kind {
            case .line, .arrow:
                e.from = try end(shape["from"], "from", i)
                e.to = try end(shape["to"], "to", i)
                e.text = shape["label"]?.string
                e.textSize = labelSize
            case .path:
                guard case .array(let list)? = shape["points"], list.count >= 2 else {
                    throw ToolInputError("shape \(i + 1): a path needs `points`, at least two [x, y]")
                }
                var points = try list.map { try pt($0, "points", i) }
                e.closed = shape["closed"] == .bool(true)
                if shape["smooth"] == .bool(true) { points = AgentGeometry.smoothed(points, closed: e.closed) }
                e.points = points
            case .circle:
                let c = try pt(shape["center"], "center", i)
                guard let r = shape["r"]?.number, r > 0 else { throw ToolInputError("shape \(i + 1): a circle needs `r` above 0") }
                let rr = CGFloat(r)
                let circle = CGRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)
                if !box.contains(circle) { clamped = true }
                e.points = AgentGeometry.ellipse(ActionValidator.clamp(circle, to: box))
                e.closed = true
            case .ellipse:
                e.points = AgentGeometry.ellipse(try rect(shape["box"], i))
                e.closed = true
            case .rect:
                let r = try rect(shape["box"], i)
                e.points = shape["rounded"] == .bool(true) ? AgentGeometry.roundedRect(r, radius: min(14, min(r.width, r.height) / 4))
                    : VectorShapes.rectOutline(r)
                e.closed = true
            case .text:
                guard let text = shape["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw ToolInputError("shape \(i + 1): text needs `text`")
                }
                e.text = text
                e.points = [try pt(shape["at"], "at", i)]
                e.textSize = shape["size"]?.string == "note" ? noteSize : labelSize
            case .label:
                guard let text = shape["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                    throw ToolInputError("shape \(i + 1): a label needs `text`")
                }
                guard let target = shape["for"]?.string else {
                    throw ToolInputError("shape \(i + 1): a label needs `for`, the id of the shape it names (or use text + at)")
                }
                e.text = text
                e.labelFor = target
                e.inside = shape["inside"] == .bool(true)
                e.textSize = labelSize
            }
            elements.append(e)
        }
        // Every id an arrow or label refers to has to exist.
        let ids = Set(elements.compactMap(\.id))
        for (i, e) in elements.enumerated() {
            for case .shape(let id)? in [e.from, e.to] where !ids.contains(id) {
                throw ToolInputError("shape \(i + 1) connects to `\(id)`, but no shape has that id")
            }
            if let id = e.labelFor, !ids.contains(id) {
                throw ToolInputError("shape \(i + 1) labels `\(id)`, but no shape has that id")
            }
        }
        return Parsed(elements: elements, size: size, clamped: clamped)
    }

    // MARK: Layout

    struct Layout {
        var items: [AgentInk]
        /// What still looks wrong, for the agent to avoid next time.
        var notes: [String]
    }

    /// The shapes on the page, in `frame`: outlines and fills first, then lines and arrows routed between shapes,
    /// then labels in clear spots, so everything is drawn in a sensible order.
    static func layout(_ parsed: Parsed, in frame: CGRect) -> Layout {
        let origin = frame.origin
        func page(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + origin.x, y: p.y + origin.y) }
        var shapes: [String: CGRect] = [:] // In box points.
        var taken: [CGRect] = []
        var items: [AgentInk] = []
        var notes: [String] = []
        let box = CGRect(origin: .zero, size: parsed.size)

        // 1. Shapes and free text.
        for e in parsed.elements {
            switch e.kind {
            case .path, .circle, .ellipse, .rect:
                let b = e.points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                if let id = e.id { shapes[id] = b }
                taken.append(b)
                items.append(.stroke(AgentStroke(points: e.points.map(page), color: e.color, closed: e.closed,
                                                 fill: e.fill && e.closed ? 0.25 : nil, dash: e.dashed ? [8, 6] : nil)))
            case .text:
                guard let text = e.text, let at = e.points.first else { continue }
                let b = AgentGeometry.textBounds(text, at: at, size: e.textSize)
                if let id = e.id { shapes[id] = b }
                if taken.contains(where: { $0.intersects(b.insetBy(dx: 2, dy: 2)) && !$0.contains(b) }) {
                    notes.append("“\(text)” overlaps a shape")
                }
                if !box.insetBy(dx: -4, dy: -4).contains(b) { notes.append("“\(text)” runs past the box") }
                taken.append(b)
                items.append(.text(AgentText(text: text, center: page(at), size: e.textSize, color: e.color)))
            case .line, .arrow, .label:
                continue
            }
        }

        // 2. Lines and arrows, from edge to edge when they connect shapes.
        for e in parsed.elements where e.kind == .line || e.kind == .arrow {
            guard let from = e.from, let to = e.to else { continue }
            let target = { (end: End) -> CGPoint in
                switch end {
                case .point(let p): p
                case .shape(let id): shapes[id].map { CGPoint(x: $0.midX, y: $0.midY) } ?? .zero
                }
            }
            var a = target(from), b = target(to)
            if case .shape(let id) = from, let r = shapes[id] { a = AgentGeometry.edgePoint(of: r, toward: b, gap: 6) }
            if case .shape(let id) = to, let r = shapes[id] { b = AgentGeometry.edgePoint(of: r, toward: a, gap: 6) }
            guard hypot(b.x - a.x, b.y - a.y) > 6 else {
                notes.append("an arrow between shapes that touch was left out")
                continue
            }
            items.append(.stroke(AgentStroke(points: [page(a), page(b)], color: e.color, dash: e.dashed ? [8, 6] : nil)))
            if e.kind == .arrow {
                items.append(.stroke(AgentStroke(points: AgentGeometry.arrowHead(from: page(a), to: page(b), length: 14),
                                                 color: e.color)))
            }
            taken.append(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            if let text = e.text, !text.isEmpty {
                // Beside the middle of the line, on whichever side is clear.
                let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                let normal = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len)
                let s = AgentGeometry.textSize(text, size: e.textSize)
                let offset = abs(normal.x) * s.width / 2 + abs(normal.y) * s.height / 2 + 6
                let spots = [1, -1].map { k in CGPoint(x: mid.x + normal.x * offset * CGFloat(k), y: mid.y + normal.y * offset * CGFloat(k)) }
                let spot = spots.first { p in
                    !taken.dropLast().contains { $0.intersects(AgentGeometry.textBounds(text, at: p, size: e.textSize)) }
                } ?? spots[0]
                taken.append(AgentGeometry.textBounds(text, at: spot, size: e.textSize))
                items.append(.text(AgentText(text: text, center: page(spot), size: e.textSize, color: e.color)))
            }
        }

        // 3. Labels: inside their shape, or in the first clear spot around it.
        for e in parsed.elements where e.kind == .label {
            guard let text = e.text, let id = e.labelFor, let r = shapes[id] else { continue }
            let s = AgentGeometry.textSize(text, size: e.textSize)
            let center = CGPoint(x: r.midX, y: r.midY)
            var spot = center
            if !e.inside {
                let candidates = [
                    CGPoint(x: r.midX, y: r.maxY + s.height / 2 + 4), CGPoint(x: r.maxX + s.width / 2 + 6, y: r.midY),
                    CGPoint(x: r.midX, y: r.minY - s.height / 2 - 4), CGPoint(x: r.minX - s.width / 2 - 6, y: r.midY),
                ]
                let clear = candidates.first { p in
                    let b = AgentGeometry.textBounds(text, at: p, size: e.textSize)
                    return box.insetBy(dx: -8, dy: -8).contains(b) && !taken.contains { $0.intersects(b) }
                }
                if let clear {
                    spot = clear
                } else {
                    spot = candidates[0]
                    notes.append("no clear room around `\(id)` for “\(text)”")
                }
            } else if s.width > r.width + 8 {
                notes.append("“\(text)” is wider than `\(id)`")
            }
            taken.append(AgentGeometry.textBounds(text, at: spot, size: e.textSize))
            items.append(.text(AgentText(text: text, center: page(spot), size: e.textSize, color: e.color)))
        }
        return Layout(items: items, notes: notes)
    }
}
