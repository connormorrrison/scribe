import CoreGraphics
import Foundation

// Pure model: Foundation and CoreGraphics only.
//
// Structure the agent reasons about, worked out once per snapshot and attached to the person's ink as `tags`:
//   "new"               drawn since the agent's last turn on this page
//   "latest"            the most recent thing the person wrote or drew
//   "crossed out"       struck through by a later line (the strike is tagged "strikes ink_N"); not an answer
//   "in vec_4"          written on that answer line, in that box, or in that table cell (vec_2.r3c1)
//   "answers txt_7"     the nearest question above it (a printed line that starts "3.", "(b)", "Q2"…)
//   "work_1 step 2/4"   one line of stacked working, in order
// Each is a heuristic with a clear rule; the debug overlay shows the tags so they can be checked.

enum PageRelations {
    struct InkTiming: Equatable {
        /// When the group's first and last strokes were drawn (seconds since the reference date).
        var start: TimeInterval
        var end: TimeInterval
    }

    /// `objects` with tags added to the person's ink. `timing` is per ink object id; `lastTurn` is when the agent last
    /// answered on this page (nil: everything counts as new).
    static func annotate(_ objects: [PageObject], timing: [String: InkTiming], lastTurn: TimeInterval?,
                         inkHeight h: CGFloat) -> [PageObject] {
        var out = objects
        let ink = out.indices.filter { out[$0].source == .studentInk && out[$0].parent == nil }
        func add(_ i: Int, _ tag: String) {
            var tags = out[i].tags ?? []
            if !tags.contains(tag) { tags.append(tag) }
            out[i].tags = tags
        }

        // Recency.
        if let latest = ink.filter({ timing[out[$0].id] != nil })
            .max(by: { timing[out[$0].id]!.end < timing[out[$1].id]!.end }) {
            add(latest, "latest")
        }
        for i in ink {
            guard let t = timing[out[i].id] else { continue }
            if lastTurn.map({ t.end > $0 }) ?? true { add(i, "new") }
        }

        // Crossed out: a later, roughly straight, mostly horizontal line across the middle of another ink object.
        for s in ink where out[s].kind == "shape" && out[s].text == "line" {
            let line = out[s].bounds
            guard line.height < 0.5 * max(line.width, 1) else { continue }
            for t in ink where t != s && out[t].kind != "shape" {
                let b = out[t].bounds
                let overlap = max(0, min(b.maxX, line.maxX) - max(b.minX, line.minX))
                guard overlap >= 0.6 * b.width, line.midY > b.minY + 0.15 * b.height,
                      line.midY < b.maxY - 0.15 * b.height else { continue }
                // An underline drawn first, then written over, isn't a strike.
                if let written = timing[out[t].id], let struck = timing[out[s].id], struck.start < written.end { continue }
                add(t, "crossed out")
                add(s, "strikes \(out[t].id)")
            }
        }

        // Which answer space it's in: the smallest blank band, box or cell holding its centre.
        let spaces = out.filter { $0.source == .printed && ["blank", "box", "checkbox", "cell"].contains($0.kind) }
        for i in ink {
            let b = out[i].bounds
            let c = CGPoint(x: b.midX, y: b.midY)
            let hit = spaces.filter { s in
                if s.kind == "blank" {
                    // Written on the line: just above it, overlapping it sideways.
                    return c.x >= s.bounds.minX - 8 && c.x <= s.bounds.maxX + 8
                        && b.maxY >= s.bounds.minY - 2.2 * h && b.maxY <= s.bounds.maxY + 0.8 * h
                }
                return s.bounds.insetBy(dx: -2, dy: -2).contains(c)
            }.min { PageMap.area($0.bounds) < PageMap.area($1.bounds) }
            if let hit { add(i, "in \(hit.id)") }
        }

        // Which question it answers: the closest question line above it (or on its row, to its left).
        let questions = out.filter { $0.source == .pdfText && $0.kind == "line" && isQuestion($0.text ?? "") }
        for i in ink {
            let b = out[i].bounds
            let q = questions.filter { $0.bounds.minY <= b.minY + 4 && b.minY - $0.bounds.maxY < 260 }
                .max { $0.bounds.minY < $1.bounds.minY }
            if let q { add(i, "answers \(q.id)") }
        }

        // Stacked working: lines of handwriting under each other, left edges close, small gaps.
        let handwriting = ink.filter { out[$0].kind == "handwriting" && !(out[$0].tags ?? []).contains("crossed out") }
            .sorted { out[$0].bounds.minY < out[$1].bounds.minY }
        var chains: [[Int]] = []
        for i in handwriting {
            let b = out[i].bounds
            if let k = chains.indices.last(where: { k in
                let p = out[chains[k].last!].bounds
                let gap = b.minY - p.maxY
                return gap > -0.3 * h && gap < 1.4 * h && abs(b.minX - p.minX) < 2.5 * h
            }) {
                chains[k].append(i)
            } else {
                chains.append([i])
            }
        }
        var n = 0
        for chain in chains where chain.count >= 2 {
            n += 1
            for (k, i) in chain.enumerated() { add(i, "work_\(n) step \(k + 1)/\(chain.count)") }
        }
        return out
    }

    /// "1.", "2)", "(b)", "Q3", "Question 4", "a." at the start of a line.
    static func isQuestion(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let first = t.first else { return false }
        if t.hasPrefix("q"), t.dropFirst().first?.isNumber == true { return true }
        if t.hasPrefix("question") { return true }
        if t.hasPrefix("("), t.dropFirst().prefix(4).contains(")") { return true }
        if first.isNumber {
            let digits = t.prefix { $0.isNumber }
            let next = t.dropFirst(digits.count).first
            return next == "." || next == ")" || next == ":"
        }
        if first.isLetter, t.count > 2, [".", ")"].contains(t[t.index(after: t.startIndex)]),
           t.dropFirst(2).first == " " {
            return true
        }
        return false
    }
}
