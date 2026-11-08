import Foundation

/// How a step the agent took reads in History: "Wrote “x = 3” on page 2", "Circled your writing on page 1".
enum AgentStep {
    /// The History entry for one drawing tool call: the marks it drew and how many it erased, on page `page`
    /// (1-based). Nil if it did nothing.
    static func entry(drawn marks: [AgentMark], erased: Int, page: Int, pageID: UUID) -> HistoryEntry? {
        guard let (text, symbol) = describe(drawn: marks, erased: erased, page: page) else { return nil }
        return HistoryEntry(author: .agent, text: text, symbol: symbol, pageID: pageID,
                            markIDs: marks.isEmpty ? nil : marks.map(\.id))
    }

    static func describe(drawn marks: [AgentMark], erased: Int, page: Int) -> (text: String, symbol: String)? {
        let on = "on page \(page)"
        guard let mark = marks.first else {
            guard erased > 0 else { return nil }
            return (erased == 1 ? "Erased one of its marks \(on)" : "Erased \(erased) of its marks \(on)", "eraser")
        }
        let words = mark.text.map(quoted)
        let subject = subject(of: mark.target)
        switch mark.kind {
        case "note", "label":
            return ("Wrote \(words ?? "a note") \(on)", "pencil.line")
        case "circle": return ("Circled \(subject) \(on)", "circle.dashed")
        case "underline": return ("Underlined \(subject) \(on)", "underline")
        case "highlight": return ("Highlighted \(subject) \(on)", "highlighter")
        case "check": return ("Ticked \(subject) \(on)", "checkmark")
        case "cross": return ("Put a cross by \(subject) \(on)", "xmark")
        case "box": return ("Boxed \(subject) \(on)", "square.dashed")
        case "arrow": return ("Drew an arrow \(on)", "arrow.up.right")
        case "outline":
            let traced = marks.count > 1 ? "\(marks.count) parts" : (words ?? subject)
            return ("Traced \(traced) \(on)", "scribble")
        case "drawing":
            return (words.map { "Drew a diagram of \($0) \(on)" } ?? "Drew a diagram \(on)", "pencil.and.scribble")
        default:
            return ("Drew \(on)", "pencil.and.scribble")
        }
    }

    /// What a page object is, in words, from its id ("ink_5" is their writing).
    private static func subject(of target: String?) -> String {
        switch target?.prefix(while: { $0 != "_" }) {
        case "ink": "your writing"
        case "txt": "the text"
        case "img": "part of the figure"
        case "vec": "part of the diagram"
        case "am": "its note"
        default: "something"
        }
    }

    /// “Short words in quotes”, cut at a word if they run long.
    private static func quoted(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard flat.count > 40 else { return "“\(flat)”" }
        let cut = flat.prefix(40)
        let atWord = cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut
        return "“\(atWord)…”"
    }
}
