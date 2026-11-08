import Foundation
import PDFKit
import Vision

/// Words, lines and paragraphs of a PDF page's printed text, with bounds in page points.
enum PrintedText {
    struct Word {
        var text: String
        var bounds: CGRect
    }

    /// Lines are `txt_1…` in reading order, multi-line paragraphs `par_1…`, words `txt_3.w1…` (parent: their line).
    static func objects(for page: PDFPage, frame: PageFrame) -> [PageObject] {
        objects(from: words(on: page, frame: frame))
    }

    /// The same grouping for words from anywhere (the PDF's text layer, or OCR of a scanned page).
    static func objects(from words: [Word]) -> [PageObject] {
        let lines = group(words)
        var wordObjects: [PageObject] = []
        var lineObjects: [PageObject] = []
        for (i, line) in lines.enumerated() {
            let id = "txt_\(i + 1)"
            let b = line.reduce(CGRect.null) { $0.union($1.bounds) }
            lineObjects.append(PageObject(id: id, source: .pdfText, kind: "line", text: line.map(\.text).joined(separator: " "),
                                          bounds: b))
            for (k, w) in line.enumerated() {
                wordObjects.append(PageObject(id: "\(id).w\(k + 1)", source: .pdfText, kind: "word", text: w.text,
                                              bounds: w.bounds, parent: id))
            }
        }
        // Paragraphs: consecutive lines that sit close together and start at about the same x.
        var paragraphs: [[Int]] = []
        for i in lineObjects.indices {
            let l = lineObjects[i].bounds
            if let last = paragraphs.last?.last {
                let p = lineObjects[last].bounds
                let gap = l.minY - p.maxY
                if gap >= -1, gap < 0.7 * max(p.height, l.height), abs(l.minX - p.minX) < 2 * p.height {
                    paragraphs[paragraphs.count - 1].append(i)
                    continue
                }
            }
            paragraphs.append([i])
        }
        var paragraphObjects: [PageObject] = []
        for group in paragraphs where group.count > 1 {
            let id = "par_\(paragraphObjects.count + 1)"
            let b = group.reduce(CGRect.null) { $0.union(lineObjects[$1].bounds) }
            paragraphObjects.append(PageObject(id: id, source: .pdfText, kind: "paragraph",
                                               text: group.map { lineObjects[$0].text ?? "" }.joined(separator: " "), bounds: b))
            for i in group { lineObjects[i].parent = id }
        }
        return lineObjects + paragraphObjects + wordObjects
    }

    /// Every whitespace-separated run of characters, with its bounds.
    ///
    /// Bounds come from `PDFSelection`s over ranges of `page.string`, so they use the string's own indexing. Pairing
    /// `page.string` with `characterBounds(at:)` drifts wherever PDFKit inserts characters of its own (line breaks,
    /// and spaces between words that have none in the file), and one drift shifts every box after it.
    static func words(on page: PDFPage, frame: PageFrame) -> [Word] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let ns = string as NSString
        var words: [Word] = []
        var start = -1
        func flush(_ end: Int) {
            guard start >= 0, end > start else { start = -1; return }
            let range = NSRange(location: start, length: end - start)
            start = -1
            words += self.words(in: range, of: ns, page: page, frame: frame)
        }
        var i = 0
        while i < ns.length {
            let range = ns.rangeOfComposedCharacterSequence(at: i)
            if ns.substring(with: range).allSatisfy(\.isWhitespace) {
                flush(range.location)
            } else if start < 0 {
                start = range.location
            }
            i = range.location + range.length
        }
        flush(ns.length)
        return words
    }

    /// One word's selection. A selection that spans two lines, or jumps sideways (two table cells with no space
    /// between them in the file), is split where it jumps.
    private static func words(in range: NSRange, of ns: NSString, page: PDFPage, frame: PageFrame) -> [Word] {
        guard let selection = page.selection(for: range) else { return [] }
        let text = (selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let b = frame.rect(selection.bounds(for: page))
        guard b.width > 0, b.height > 0 else { return [] }
        // Plausible: one line, and not wider than its letters could be.
        if selection.selectionsByLine().count <= 1, b.width <= CGFloat(text.count) * b.height * 1.4 + 4 {
            return [Word(text: text, bounds: b)]
        }

        // Split character by character where the next character jumps.
        var out: [Word] = []
        var current = ""
        var box = CGRect.null
        var i = range.location
        while i < range.location + range.length {
            let r = ns.rangeOfComposedCharacterSequence(at: i)
            i = r.location + r.length
            guard let character = page.selection(for: r) else { continue }
            let cb = frame.rect(character.bounds(for: page))
            guard cb.width > 0, cb.height > 0 else { continue }
            if !box.isNull, cb.minX > box.maxX + max(cb.height, 4) * 1.2 || cb.maxX < box.minX
                || abs(cb.midY - box.midY) > max(box.height, cb.height) * 0.6 {
                out.append(Word(text: current, bounds: box))
                current = ""
                box = .null
            }
            current += ns.substring(with: r)
            box = box.union(cb)
        }
        if !current.isEmpty, !box.isNull { out.append(Word(text: current, bounds: box)) }
        return out
    }

    /// Words on the same baseline that aren't far apart sideways form one line, read left to right.
    static func group(_ words: [Word]) -> [[Word]] {
        // 1. Rows: words that overlap vertically by more than half the smaller height.
        var rows: [[Word]] = []
        var rowBoxes: [CGRect] = []
        for w in words.sorted(by: { $0.bounds.midY < $1.bounds.midY }) {
            if let i = rowBoxes.indices.first(where: { i in
                let b = rowBoxes[i]
                let overlap = min(b.maxY, w.bounds.maxY) - max(b.minY, w.bounds.minY)
                return overlap > 0.5 * min(b.height, w.bounds.height)
            }) {
                rows[i].append(w)
                rowBoxes[i] = rowBoxes[i].union(w.bounds)
            } else {
                rows.append([w])
                rowBoxes.append(w.bounds)
            }
        }
        // 2. Within a row, a wide gap starts a new line (a far "Name" field isn't part of the header).
        var lines: [([Word], CGRect)] = []
        for row in rows {
            var current: [Word] = []
            var box = CGRect.null
            for w in row.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
                let h = max(box.isNull ? 0 : box.height, w.bounds.height)
                if !current.isEmpty, w.bounds.minX - box.maxX > 3 * h {
                    lines.append((current, box))
                    current = []
                    box = .null
                }
                current.append(w)
                box = box.union(w.bounds)
            }
            if !current.isEmpty { lines.append((current, box)) }
        }
        // Reading order: top to bottom; on the same row, left to right.
        return lines.sorted { a, b in
            let overlap = min(a.1.maxY, b.1.maxY) - max(a.1.minY, b.1.minY)
            if overlap > 0.5 * min(a.1.height, b.1.height) { return a.1.minX < b.1.minX }
            return a.1.minY < b.1.minY
        }.map(\.0)
    }
}

// MARK: - Scanned pages

/// A page with no text layer (a scan, a photo of a worksheet): its printed text read from the picture with Vision,
/// as the same `txt_N` lines and `txt_N.wK` words, so everything downstream works the same.
enum ScannedText {
    /// `image` is the printed page alone (no ink), covering `area` of the page (in page points).
    nonisolated static func words(image: CGImage, area: CGRect) -> [PrintedText.Word] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return [] }
        var out: [PrintedText.Word] = []
        for observation in request.results ?? [] {
            guard let top = observation.topCandidates(1).first, top.confidence >= 0.3 else { continue }
            let s = top.string
            var index = s.startIndex
            for part in s.split(whereSeparator: \.isWhitespace) {
                let range = (s.range(of: part, range: index..<s.endIndex)) ?? (part.startIndex..<part.endIndex)
                index = range.upperBound
                let box = (try? top.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                // Vision: normalised, origin bottom-left.
                out.append(PrintedText.Word(text: String(part), bounds: CGRect(
                    x: area.minX + box.minX * area.width, y: area.minY + (1 - box.maxY) * area.height,
                    width: box.width * area.width, height: box.height * area.height)))
            }
        }
        return out
    }
}
