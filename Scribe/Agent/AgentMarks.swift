import SwiftUI
import UIKit

// What the agent draws and writes on a page. A mark is one thing it did (a circle around a word, a note, a traced
// outline, a small drawing): a few strokes and lines of handwriting, kept as vectors so they stay sharp at any zoom,
// written in Caveat, saved with the page and drawn in the order they were made, each revealed like a pen.

/// One thing the agent drew on a page.
struct AgentMark: Identifiable, Codable, Equatable {
    var id = UUID()
    /// The turn that drew it (one undo step per turn).
    var turn: UUID
    /// What it is, for the next turn's page map: circle, underline, highlight, check, cross, box, arrow, note, label,
    /// outline, drawing.
    var kind: String
    /// The words it says, if any.
    var text: String?
    /// The page object it's on or around ("ink_5").
    var target: String?
    var items: [AgentInk]

    var bounds: CGRect { items.reduce(CGRect.null) { $0.union($1.bounds) } }

    /// Seconds it takes to draw.
    var duration: Double { items.reduce(0) { $0 + $1.duration } }
}

/// A piece of a mark: a stroke of the pen, or a line of handwriting.
enum AgentInk: Codable, Equatable {
    case stroke(AgentStroke)
    case text(AgentText)

    var bounds: CGRect {
        switch self {
        case .stroke(let s): s.bounds
        case .text(let t): t.bounds
        }
    }

    var duration: Double {
        switch self {
        case .stroke(let s):
            if s.highlight || (s.fill != nil && !s.stroked) { return 0.3 }
            return AgentPacing.strokeDuration(length: AgentGeometry.length(s.points) * 0.6)
        case .text(let t): return AgentPacing.write(characters: t.text.count)
        }
    }
}

struct AgentStroke: Codable, Equatable {
    /// Page points.
    var points: [CGPoint]
    /// `#RRGGBB`.
    var color: String = InkSwatch.blueHex
    var width: CGFloat = AgentStroke.penWidth
    /// Joins the last point back to the first.
    var closed = false
    /// Fills the shape this much (0…1), under its outline.
    var fill: Double?
    /// Draws the outline (false: fill only).
    var stroked = true
    var dash: [CGFloat]?
    /// A highlighter swipe: the fill is multiplied over what's beneath it, like the highlighter tool.
    var highlight = false

    static let penWidth: CGFloat = 3

    var path: [CGPoint] {
        guard closed, let first = points.first, points.last != first else { return points }
        return points + [first]
    }

    var bounds: CGRect {
        let box = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        return box.isNull ? box : box.insetBy(dx: -width / 2, dy: -width / 2)
    }
}

/// One line of the agent's handwriting, centred on `center`.
struct AgentText: Codable, Equatable {
    var text: String
    var center: CGPoint
    /// Nominal size, as `Handwriting` takes it.
    var size: CGFloat
    var color: String = InkSwatch.blueHex

    var bounds: CGRect { AgentGeometry.textBounds(text, at: center, size: size) }
}

// MARK: - Geometry

extension AgentGeometry {
    static func length(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// The first `fraction` of a polyline, by length.
    static func trim(_ pts: [CGPoint], _ fraction: Double) -> [CGPoint] {
        guard let first = pts.first else { return [] }
        if fraction >= 1 { return pts }
        if fraction <= 0 { return [first] }
        let target = length(pts) * CGFloat(fraction)
        var out = [first]
        var run: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst()) {
            let segment = hypot(b.x - a.x, b.y - a.y)
            if run + segment >= target {
                let t = segment > 0 ? (target - run) / segment : 0
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                return out
            }
            run += segment
            out.append(b)
        }
        return out
    }

    /// A loose, slightly spiralling hand-drawn ellipse that overshoots its start a little.
    static func handEllipse(_ rect: CGRect, seed: Int = 3) -> [CGPoint] {
        let n = 64
        let s = Double(seed)
        return (0...n).map { i in
            let u = Double(i) / Double(n)
            let a = u * 1.08 * 2 * .pi - .pi * 0.6
            let wobble = 1 + 0.03 * sin(3 * a + s) + 0.045 * u
            return CGPoint(x: rect.midX + cos(a) * rect.width / 2 * wobble, y: rect.midY + sin(a) * rect.height / 2 * wobble)
        }
    }

    /// A tick centred near `p`, `size` across.
    static func checkPoints(at p: CGPoint, size: CGFloat = 24) -> [CGPoint] {
        let k = size / 15
        return [CGPoint(x: p.x - 7 * k, y: p.y), CGPoint(x: p.x - 2.5 * k, y: p.y + 6 * k), CGPoint(x: p.x + 8 * k, y: p.y - 8 * k)]
    }

    static func arrowHead(from a: CGPoint, to b: CGPoint, length: CGFloat = 16) -> [CGPoint] {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let spread: CGFloat = .pi / 6
        return [CGPoint(x: b.x - length * cos(angle - spread), y: b.y - length * sin(angle - spread)), b,
                CGPoint(x: b.x - length * cos(angle + spread), y: b.y - length * sin(angle + spread))]
    }

    /// A rounded rectangle as a closed polyline, starting at the top-left corner's end.
    static func roundedRect(_ r: CGRect, radius: CGFloat) -> [CGPoint] {
        let k = max(0, min(radius, r.width / 2, r.height / 2))
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: r.maxX - k, y: r.minY + k), -.pi / 2), (CGPoint(x: r.maxX - k, y: r.maxY - k), 0),
            (CGPoint(x: r.minX + k, y: r.maxY - k), .pi / 2), (CGPoint(x: r.minX + k, y: r.minY + k), .pi),
        ]
        var pts: [CGPoint] = []
        for (c, start) in corners {
            for i in 0...6 {
                let a = start + CGFloat(i) / 6 * .pi / 2
                pts.append(CGPoint(x: c.x + cos(a) * k, y: c.y + sin(a) * k))
            }
        }
        return pts
    }

    static func ellipse(_ r: CGRect, points n: Int = 48) -> [CGPoint] {
        (0..<n).map { i in
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi - .pi / 2
            return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2)
        }
    }

    /// The point on `r`'s edge in the direction of `toward`, `gap` outside it.
    static func edgePoint(of r: CGRect, toward p: CGPoint, gap: CGFloat) -> CGPoint {
        let c = CGPoint(x: r.midX, y: r.midY)
        let dx = p.x - c.x, dy = p.y - c.y
        guard dx != 0 || dy != 0 else { return c }
        let tx = dx == 0 ? CGFloat.infinity : (r.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.infinity : (r.height / 2) / abs(dy)
        let t = min(tx, ty)
        let len = hypot(dx, dy)
        return CGPoint(x: c.x + dx * t + dx / len * gap, y: c.y + dy * t + dy / len * gap)
    }

    /// Catmull–Rom through the points, for natural shapes (leaves, clouds, waves).
    static func smoothed(_ pts: [CGPoint], closed: Bool, steps: Int = 8) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        let n = pts.count
        func p(_ i: Int) -> CGPoint { closed ? pts[(i % n + n) % n] : pts[min(max(i, 0), n - 1)] }
        var out: [CGPoint] = []
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = p(i - 1), p1 = p(i), p2 = p(i + 1), p3 = p(i + 2)
            for s in 0..<steps {
                let t = CGFloat(s) / CGFloat(steps), t2 = t * t, t3 = t2 * t
                out.append(CGPoint(
                    x: 0.5 * (2 * p1.x + (-p0.x + p2.x) * t + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3),
                    y: 0.5 * (2 * p1.y + (-p0.y + p2.y) * t + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3)))
            }
        }
        out.append(closed ? pts[0] : pts[n - 1])
        return out
    }

    /// The box a line of handwriting takes, centred on `at`.
    static func textBounds(_ text: String, at: CGPoint, size: CGFloat) -> CGRect {
        let s = textSize(text, size: size)
        return CGRect(x: at.x - s.width / 2, y: at.y - s.height / 2, width: s.width, height: s.height)
    }

    static func textSize(_ text: String, size: CGFloat) -> CGSize {
        // Caveat's slanted strokes reach a little past the width it reports.
        CGSize(width: ceil(Handwriting.width(of: text, size: size) + size * 0.25),
               height: ceil(Handwriting.font(size: size).lineHeight))
    }
}

// MARK: - Drawing

enum AgentMarkRenderer {
    /// Draws `mark` as far as `progress` (0…1): its pieces one after another, each at its own pace.
    static func draw(_ mark: AgentMark, progress: Double = 1, in ctx: inout GraphicsContext) {
        guard progress > 0 else { return }
        if progress >= 1 {
            for item in mark.items { draw(item, progress: 1, in: &ctx) }
            return
        }
        let total = max(mark.duration, 0.001)
        var start = 0.0
        for item in mark.items {
            let share = item.duration / total
            let local = share > 0 ? (progress - start) / share : 1
            if local <= 0 { break }
            draw(item, progress: min(1, local), in: &ctx)
            start += share
        }
    }

    static func draw(_ item: AgentInk, progress p: Double, in ctx: inout GraphicsContext) {
        switch item {
        case .stroke(let s):
            let color = AgentColor(s.color).color
            if let fill = s.fill, s.points.count > 2 {
                var path = Path()
                path.addLines(s.points)
                path.closeSubpath()
                if s.highlight {
                    var layer = ctx
                    layer.blendMode = .multiply
                    layer.fill(path, with: .color(color.opacity(fill * min(1, p * 1.5))))
                } else {
                    ctx.fill(path, with: .color(color.opacity(fill * p)))
                }
            }
            guard s.stroked else { return }
            let pts = AgentGeometry.trim(s.path, p)
            guard pts.count > 1 else { return }
            var path = Path()
            path.addLines(pts)
            ctx.stroke(path, with: .color(color),
                       style: StrokeStyle(lineWidth: s.width, lineCap: .round, lineJoin: .round, dash: s.dash ?? []))
        case .text(let t):
            AgentRenderer.draw(.writeLabel(text: t.text, at: t.center, color: AgentColor(t.color), size: t.size),
                               progress: p, seed: 0, in: &ctx)
        }
    }
}

/// A mark being drawn right now: which page, and since when.
struct LiveMark: Equatable {
    var pageID: UUID
    var markID: UUID
    var start: Date
    var duration: Double

    func progress(at date: Date) -> Double {
        duration > 0 ? min(1, max(0, date.timeIntervalSince(start) / duration)) : 1
    }
}

/// The agent's marks on one page, in page points scaled by `scale`. The mark being drawn reveals itself frame by frame.
struct AgentMarksLayer: View {
    let marks: [AgentMark]
    var live: LiveMark?
    var scale: CGFloat = 1

    var body: some View {
        if let live {
            TimelineView(.animation) { timeline in
                canvas(progress: live.progress(at: timeline.date), of: live.markID)
            }
        } else {
            canvas(progress: 1, of: nil)
        }
    }

    private func canvas(progress: Double, of liveID: UUID?) -> some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            for mark in marks {
                AgentMarkRenderer.draw(mark, progress: mark.id == liveID ? progress : 1, in: &ctx)
            }
        }
        .environment(\.colorScheme, .light)
        .allowsHitTesting(false)
    }
}
