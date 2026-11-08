import CoreGraphics
import Foundation

/// The compact text block the agent reads beside the page picture.
enum PageMapText {
    static func block(_ s: PageMapSnapshot, budget: Int = PageMap.objectBudget) -> String {
        var out: [String] = []
        let px = s.imagePixelSize
        let v = s.viewport
        out.append("PAGE \(n(s.pageSize.width))×\(n(s.pageSize.height)) pt. The picture is \(n(px.width))×\(n(px.height)) px "
                   + "(1 pt = \(String(format: "%.3f", Double(s.imageScale))) px). On screen: y \(n(v.minY))–\(n(v.maxY)).")
        out.append("Coordinates are page points, origin top-left, x right, y down. Every box below is exact: use ids, "
                   + "not guesses from the picture.")
        out.append("Their handwriting is about \(n(s.studentInkHeight)) pt tall.")

        let listed = listedObjects(s, budget: budget)
        if listed.rows.isEmpty {
            out.append("OBJECTS: none. The page is blank.")
        } else {
            out.append("OBJECTS (id · what · x,y,w,h in pt):")
            let idWidth = min(12, listed.rows.map(\.id.count).max() ?? 6)
            for o in listed.rows {
                out.append("\(pad(o.id, idWidth)) \(pad(describe(o), 46)) \(PageMap.format(o.bounds))")
            }
        }
        out.append(contentsOf: listed.notes)

        // Where the agent can write: blank areas read from the page's own pixels, clear of everything (answer spaces
        // the person hasn't filled in are kept out of them).
        if s.freeSpaces.isEmpty {
            out.append("FREE SPACE: none big enough on this page; placement will add space below.")
        } else {
            out.append("FREE SPACE (write or draw here with near {\"id\":\"free_N\"}; x,y,w,h in pt):")
            for f in s.freeSpaces {
                var line = "\(pad(f.id, 8)) \(PageMap.format(f.bounds))"
                if let near = f.near { line += " · \(near)" }
                if !f.visible { line += " · off screen" }
                out.append(line)
            }
        }

        if !s.agentMarks.isEmpty {
            out.append("YOUR MARKS: " + s.agentMarks.map(describe).joined(separator: "; "))
        }
        let cards = s.objects.filter { $0.source == .card }
        if !cards.isEmpty {
            out.append("CARDS: " + cards.map { "\($0.id) \($0.kind) \(quote($0.text ?? "")) \(PageMap.format($0.bounds))" }
                .joined(separator: "; "))
        }
        return out.joined(separator: "\n")
    }

    /// A rough token count (about 3.2 characters per token for this dense, number-heavy text).
    static func estimatedTokens(_ text: String) -> Int { Int((Double(text.count) / 3.2).rounded(.up)) }

    // MARK: Choosing what to list

    struct Listed {
        var rows: [PageObject]
        var notes: [String]
    }

    /// Lines, not words. Multi-line paragraphs once. Past `budget`, a paragraph's later lines are summarised as
    /// "+N more lines in paragraph par_2".
    static func listedObjects(_ s: PageMapSnapshot, budget: Int) -> Listed {
        let candidates = s.objects.filter { o in
            switch o.source {
            case .pdfText: return o.kind != "word"
            // Table cells are listed only for small tables; bigger ones say how to name a cell.
            case .printed: return o.kind != "cell" || smallTable(o.parent, s)
            case .studentInk: return true
            case .agentInk, .card: return false // Their own sections.
            }
        }
        guard candidates.count > budget else { return Listed(rows: candidates, notes: []) }

        // Everything that isn't a printed line stays; lines are trimmed from the end, the first line of each
        // paragraph last.
        let lineIndices = candidates.indices.filter { candidates[$0].source == .pdfText && candidates[$0].kind == "line" }
            .reversed()
        var excess = candidates.count - budget
        var remove = Set<Int>()
        var dropped: [String: Int] = [:] // Paragraph (or "page") → lines dropped.
        let firstLines = Set(Dictionary(grouping: lineIndices, by: { candidates[$0].parent ?? candidates[$0].id })
            .values.compactMap { $0.min() })
        for pass in 0..<2 where excess > 0 {
            for i in lineIndices where excess > 0 && !remove.contains(i) {
                if pass == 0 && firstLines.contains(i) { continue }
                remove.insert(i)
                dropped[candidates[i].parent ?? "page", default: 0] += 1
                excess -= 1
            }
        }
        let rows = candidates.enumerated().filter { !remove.contains($0.offset) }.map(\.element)
        let notes = dropped.sorted { $0.key < $1.key }.map { key, count in
            key == "page" ? "+\(count) more printed lines" : "+\(count) more lines in paragraph \(key)"
        }
        return Listed(rows: rows, notes: notes)
    }

    static let listedCellsMax = 12

    private static func smallTable(_ parent: String?, _ s: PageMapSnapshot) -> Bool {
        guard let parent else { return true }
        return s.objects.filter { $0.parent == parent && $0.kind == "cell" }.count <= listedCellsMax
    }

    // MARK: Formatting

    static func describe(_ o: PageObject) -> String {
        var d = describeKind(o)
        if let c = o.confidence, c < 0.6 { d += " (unsure)" }
        if o.paths != nil || (o.outline?.count ?? 0) > 2 { d += " ·traceable" }
        if let tags = o.tags, !tags.isEmpty { d += " [" + tags.joined(separator: ", ") + "]" }
        return d
    }

    private static func describeKind(_ o: PageObject) -> String {
        switch (o.source, o.kind) {
        case (.printed, "table"):
            return "table \(o.text ?? "") (cells \(o.id).r1c1…)"
        case (.printed, "blank"):
            return "blank (answer line)"
        case (.printed, "underline"):
            return "printed underline" + (o.parent.map { " of \($0)" } ?? "")
        case (.pdfText, "paragraph"):
            return "paragraph" + (o.text.map { " \(quote(String($0.prefix(40))))…" } ?? "")
        case (_, "shape"), (_, "drawing"):
            return o.kind + (o.text.map { " \($0)" } ?? "")
        case (_, "handwriting"):
            return "handwriting " + (o.text.map(quote) ?? "(unread)")
        default:
            return o.kind + (o.text.map { " \(quote($0))" } ?? "")
        }
    }

    private static func describe(_ m: AgentMarkSummary) -> String {
        var s = "\(m.id) \(m.kind)"
        if let t = m.text { s += " \(quote(t))" }
        if let target = m.target {
            s += " \(m.kind == "circle" || m.kind == "box" ? "around" : "on") \(target)"
        } else {
            s += " \(PageMap.format(m.bounds))"
        }
        return s
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ") + "\""
    }

    private static func pad(_ s: String, _ w: Int) -> String { s.count >= w ? s : s + String(repeating: " ", count: w - s.count) }
    private static func n(_ v: CGFloat) -> String { String(Int(v.rounded())) }
}
