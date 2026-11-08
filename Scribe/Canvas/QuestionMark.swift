import PencilKit
import SwiftUI

// Asking without talking: write a "?" beside whatever you're stuck on. When the pencil lifts and rests, the app looks
// at what was just written; a "?" (or a few words ending in one, like "why?") standing on its own, not part of a line
// of working, goes to the agent about whatever it's beside: a question, a line of their working, an answer, one of the
// agent's own steps. The question it's about gets a faint box while the agent works, so it's clear what was heard.

/// A "?" the person wrote, and what it's beside.
struct MarkedQuestion: Equatable {
    var pageID: UUID
    /// The ? itself (page points).
    var mark: CGRect
    /// What it's about, boxed faintly: the question, the line of working or the step beside it.
    var subject: CGRect
    /// The words written with the ?, when there are more than the ? alone ("why?").
    var words: String?
}

enum QuestionMark {
    /// How long the pencil rests before what was just written is looked at.
    static let pause: Duration = .milliseconds(800)

    /// The strokes just written, as one cluster: the end of the drawing, each stroke started soon after the one before
    /// and close beside it. Nil if the last stroke isn't fresh, or the cluster is too big to be a "?" or a few words.
    static func latestCluster(_ strokes: [PKStroke], now: Date = Date()) -> (indices: Range<Int>, bounds: CGRect)? {
        guard let last = strokes.last, now.timeIntervalSince(end(of: last)) < 4 else { return nil }
        var first = strokes.count - 1
        var bounds = last.renderBounds
        while first > 0, strokes.count - first < 10 {
            let previous = strokes[first - 1], next = strokes[first]
            guard next.path.creationDate.timeIntervalSince(end(of: previous)) < 1.2 else { break }
            let h = max(bounds.height, 12)
            guard previous.renderBounds.insetBy(dx: -h * 0.6, dy: -h * 0.4).intersects(bounds) else { break }
            bounds = bounds.union(previous.renderBounds)
            first -= 1
        }
        guard bounds.height >= 14, bounds.height <= 220, bounds.width <= max(bounds.height * 7, 60) else { return nil }
        return (first..<strokes.count, bounds)
    }

    private static func end(of stroke: PKStroke) -> Date {
        stroke.path.creationDate.addingTimeInterval(stroke.path.last?.timeOffset ?? 0)
    }

    /// It stands on its own: none of their other ink is right beside it on its row, so it isn't the end of a line of
    /// working ("x = ?").
    static func standsAlone(_ bounds: CGRect, others: [CGRect]) -> Bool {
        let h = bounds.height
        let room = bounds.insetBy(dx: -max(h * 0.5, 14), dy: -h * 0.12)
        return !others.contains { $0.intersects(room) }
    }

    /// A hook with a dot under it: the shape of a "?", whatever Vision makes of it.
    static func looksLikeQuestionMark(_ strokes: [PKStroke]) -> Bool {
        guard strokes.count == 2 else { return false }
        let boxes = strokes.map(\.renderBounds).sorted { max($0.width, $0.height) > max($1.width, $1.height) }
        let hook = boxes[0], dot = boxes[1]
        let h: CGFloat = hook.union(dot).height
        let dotIsSmall: Bool = max(dot.width, dot.height) < h * 0.3
        let hookIsTall: Bool = hook.height > h * 0.55 && hook.height > hook.width * 0.8
        let dotIsUnder: Bool = dot.midY > hook.minY + hook.height * 0.7
        let dotIsInLine: Bool = dot.midX > hook.minX - h * 0.3 && dot.midX < hook.maxX + h * 0.3
        return dotIsSmall && hookIsTall && dotIsUnder && dotIsInLine
    }

    /// What Vision reads as a question: a lone "?", or up to five words ending in one. The words, without the "?",
    /// or "" for a lone "?". Nil if it isn't a question.
    static func question(in reading: String) -> String? {
        let t = reading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasSuffix("?") || t.hasSuffix("？") else { return nil }
        let words = t.dropLast().trimmingCharacters(in: .whitespaces)
        guard words.split(separator: " ").count <= 5 else { return nil }
        return words
    }

    /// What the ? at `mark` is about: the nearest thing beside it on its row (to its left first), or else the nearest
    /// thing above it. A printed question is boxed whole, from its number to the line before the next question.
    static func subject(of mark: CGRect, in snapshot: PageMapSnapshot) -> CGRect? {
        let marks = snapshot.agentMarks.map { PageObject(id: $0.id, source: .agentInk, kind: $0.kind, bounds: $0.bounds) }
        let candidates = (snapshot.objects + marks).filter { o in
            guard o.parent == nil, !["word", "part", "area", "rule", "blank"].contains(o.kind), o.source != .card else { return false }
            // Not the ? itself.
            let overlap = o.bounds.intersection(mark)
            return overlap.isNull || overlap.width * overlap.height < 0.4 * max(o.bounds.width * o.bounds.height, 1)
        }
        let row = mark.insetBy(dx: 0, dy: -mark.height * 0.4)
        func gap(_ r: CGRect) -> CGFloat {
            let dx = r.maxX < mark.minX ? mark.minX - r.maxX : r.minX > mark.maxX ? r.minX - mark.maxX : 0
            let dy = r.maxY < mark.minY ? mark.minY - r.maxY : r.minY > mark.maxY ? r.minY - mark.maxY : 0
            return hypot(dx, dy)
        }
        let beside = candidates.filter { $0.bounds.minY < row.maxY && $0.bounds.maxY > row.minY && gap($0.bounds) < 500 }
        let left = beside.filter { $0.bounds.midX < mark.midX }
        let above = candidates.filter { $0.bounds.maxY <= mark.minY + 4 && gap($0.bounds) < 200 }
        guard let near = (left.isEmpty ? beside : left).min(by: { gap($0.bounds) < gap($1.bounds) })
            ?? above.min(by: { gap($0.bounds) < gap($1.bounds) }) else { return nil }

        guard near.source == .pdfText else { return near.bounds }
        // A printed line: the whole question it's part of.
        let lines = snapshot.objects.filter { $0.source == .pdfText && $0.kind == "line" }.sorted { $0.bounds.minY < $1.bounds.minY }
        let questions = lines.filter { PageRelations.isQuestion($0.text ?? "") }
        guard let start = questions.last(where: { $0.bounds.minY <= near.bounds.minY + 2 }),
              near.bounds.minY - start.bounds.maxY < 260 else { return near.bounds }
        let next = questions.first { $0.bounds.minY > start.bounds.minY + 2 }?.bounds.minY ?? .infinity
        let top: CGFloat = start.bounds.minY - 2, limit: CGFloat = start.bounds.maxY + 260
        let block = lines.filter { line -> Bool in
            let y: CGFloat = line.bounds.minY
            return y >= top && y < next && y < limit
        }
        return block.reduce(CGRect.null) { $0.union($1.bounds) }
    }
}

/// The faint box around what a "?" is about, with a soft blue ring on the ? itself, while the agent works on it.
struct MarkedQuestionOverlay: View {
    let question: MarkedQuestion
    let scale: CGFloat
    @State private var shown = false

    var body: some View {
        let box = question.subject.insetBy(dx: -10, dy: -8)
        let ring = question.mark.insetBy(dx: -8, dy: -8)
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .fill(Landing.blue.opacity(0.05))
                .strokeBorder(Landing.blue.opacity(0.35), lineWidth: 1.5)
                .frame(width: box.width * scale, height: box.height * scale)
                .offset(x: box.minX * scale, y: box.minY * scale)
            Circle()
                .fill(Landing.blue.opacity(0.12))
                .strokeBorder(Landing.blue.opacity(0.5), lineWidth: 1.5)
                .frame(width: max(ring.width, ring.height) * scale, height: max(ring.width, ring.height) * scale)
                .offset(x: (ring.midX - max(ring.width, ring.height) / 2) * scale,
                        y: (ring.midY - max(ring.width, ring.height) / 2) * scale)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(false)
        .onAppear { withAnimation(.snappy(duration: 0.35)) { shown = true } }
    }
}
