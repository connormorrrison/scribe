import CoreGraphics
import CoreText
import Foundation

// Marks on the characters of a worked step, like a teacher's at the board: an arrow that carries the exponent of x³
// down to the front of 3x², a circle on the −1, a stroke through a term that cancels. Each mark is tied to a piece of
// the agent's writing (this line or an earlier step), or to something on the page, and lands exactly on its ink.

extension ActionValidator {
    enum AnnotationKind: String, Decodable { case arrow, circle, underline, box, strike, highlight }

    /// A piece of writing: `text` within this line, an earlier step (`in`: "am_4", or "previous" for the last line
    /// written), or something on the page (`in`: "txt_3", "ink_2"). `nth` picks among repeats (1-based).
    struct PartRef: Decodable {
        var text: String?
        var nth: Int?
        var `in`: String?

        var isLocal: Bool { self.in == nil }
    }

    struct AnnotationInput: Decodable {
        var kind: AnnotationKind
        var on: PartRef?
        var from: PartRef?
        var to: PartRef?
        var label: String?
        var color: String?

        /// Everything it refers to is in the line being written, so it can be laid out with it before placement.
        var isLocal: Bool { [on, from, to].compactMap { $0 }.allSatisfy(\.isLocal) }
    }

    /// The default colour for annotations: a second pen, so what moves stands apart from the working.
    static let annotationColor = colorNames["orange"]!

    /// The strokes and labels for `annotations` on `lines` (the line being written), and a note for each one skipped.
    static func annotate(_ annotations: [AnnotationInput], lines: [AgentText], _ c: ToolContext)
        -> (items: [AgentInk], skipped: [String]) {
        var items: [AgentInk] = []
        var skipped: [String] = []
        for (i, a) in annotations.enumerated() {
            do {
                items += try annotation(a, lines: lines, seed: i, c)
            } catch let error as ToolInputError {
                skipped.append(error.reason)
            } catch {
                skipped.append("annotation \(i + 1) isn't valid")
            }
        }
        return (items, skipped)
    }

    private static func annotation(_ a: AnnotationInput, lines: [AgentText], seed: Int, _ c: ToolContext) throws -> [AgentInk] {
        let color = a.color == nil ? (a.kind == .highlight ? InkSwatch.yellowHighlighter.inkHex : annotationColor)
            : try parseColor(a.color)
        let labelSize: CGFloat = 18
        if a.kind == .arrow {
            guard let fromRef = a.from ?? a.on, let toRef = a.to ?? (a.from == nil ? nil : a.on) else {
                throw ToolInputError("an arrow annotation needs `from` and `to`")
            }
            let from = try box(fromRef, lines: lines, c), to = try box(toRef, lines: lines, c)
            let arrow = curvedArrow(from: from, to: to)
            guard arrow.path.count > 1 else { throw ToolInputError("the arrow's ends are on top of each other") }
            var out: [AgentInk] = [
                .stroke(AgentStroke(points: arrow.path, color: color, width: 2.5)),
                .stroke(AgentStroke(points: AgentGeometry.arrowHead(from: arrow.path[arrow.path.count - 2],
                                                                    to: arrow.path[arrow.path.count - 1], length: 11),
                                    color: color, width: 2.5)),
            ]
            if let label = a.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
                let s = AgentGeometry.textSize(label, size: labelSize)
                let reach = max(s.width, s.height) / 2 + 4
                let center = CGPoint(x: arrow.apex.x + arrow.outward.x * reach, y: arrow.apex.y + arrow.outward.y * reach)
                out.append(.text(AgentText(text: label, center: center, size: labelSize, color: color)))
            }
            return out
        }

        guard let ref = a.on else { throw ToolInputError("`\(a.kind.rawValue)` needs `on`") }
        let b = try box(ref, lines: lines, c)
        var out: [AgentInk]
        switch a.kind {
        case .circle:
            let r = b.insetBy(dx: -max(6, b.width * 0.15), dy: -max(5, b.height * 0.25))
            out = [.stroke(AgentStroke(points: AgentGeometry.handEllipse(r, seed: seed), color: color, width: 2.5))]
        case .underline:
            out = [.stroke(AgentStroke(points: handLine(CGPoint(x: b.minX - 2, y: b.maxY + 4), CGPoint(x: b.maxX + 2, y: b.maxY + 5)),
                                       color: color, width: 2.5))]
        case .box:
            out = [.stroke(AgentStroke(points: AgentGeometry.roundedRect(b.insetBy(dx: -5, dy: -4), radius: 6),
                                       color: color, width: 2.5, closed: true))]
        case .highlight:
            out = [.stroke(AgentStroke(points: AgentGeometry.roundedRect(b.insetBy(dx: -3, dy: -3), radius: 4), color: color,
                                       closed: true, fill: 0.4, stroked: false, highlight: true))]
        case .strike:
            out = [.stroke(AgentStroke(points: handLine(CGPoint(x: b.minX - 3, y: b.maxY + 1), CGPoint(x: b.maxX + 3, y: b.minY - 1)),
                                       color: color, width: 2.5))]
        case .arrow:
            return []
        }
        if let label = a.label?.trimmingCharacters(in: .whitespaces), !label.isEmpty {
            // Under an underline; above anything else, clear of the shape.
            let s = AgentGeometry.textSize(label, size: labelSize)
            let shape = out.reduce(CGRect.null) { $0.union($1.bounds) }
            let y = a.kind == .underline ? shape.maxY + s.height / 2 + 1 : shape.minY - s.height / 2 - 1
            out.append(.text(AgentText(text: label, center: CGPoint(x: b.midX, y: y), size: labelSize, color: color)))
        }
        return out
    }

    /// Where a piece of writing sits on the page.
    private static func box(_ ref: PartRef, lines: [AgentText], _ c: ToolContext) throws -> CGRect {
        let text = ref.text?.trimmingCharacters(in: .whitespaces)
        let nth = max(1, ref.nth ?? 1)
        guard let place = ref.in else {
            guard let text, !text.isEmpty else { throw ToolInputError("a part of this line needs its `text`") }
            if let r = AgentGeometry.inkBox(of: text, nth: nth, in: lines) { return r }
            throw ToolInputError("there's no “\(text)” in “\(lines.map(\.text).joined(separator: " "))”")
        }
        if place.hasPrefix("step_") || (place == "previous" && (c.currentStep ?? 0) > 0) {
            let n = place == "previous" ? c.currentStep! : Int(place.dropFirst(5)) ?? 0
            guard n >= 1, n <= c.stepLines.count else { throw ToolInputError("there's no `\(place)`") }
            let written = c.stepLines[n - 1]
            guard let text, !text.isEmpty else { return written.reduce(CGRect.null) { $0.union($1.bounds) } }
            if let r = AgentGeometry.inkBox(of: text, nth: nth, in: written) { return r }
            throw ToolInputError("there's no “\(text)” in \(place)")
        }
        if place == "previous" || place.hasPrefix("am_") {
            let mark: AgentMark?
            if place == "previous" {
                mark = c.marks.last { $0.items.contains { if case .text = $0 { true } else { false } } }
            } else if let n = Int(place.dropFirst(3)), n >= 1, n <= c.marks.count {
                mark = c.marks[n - 1]
            } else {
                mark = nil
            }
            guard let mark else { throw ToolInputError("there's no `\(place)`") }
            guard let text, !text.isEmpty else { return mark.bounds }
            let written = mark.items.compactMap { if case .text(let t) = $0 { t } else { nil } }
            if let r = AgentGeometry.inkBox(of: text, nth: nth, in: written) { return r }
            throw ToolInputError("there's no “\(text)” in \(place)")
        }
        guard let r = c.map.resolve(target: .id(place, match: text), pageSize: c.pageSize) else {
            throw ToolInputError("there's no `\(place)` on the page map")
        }
        return r.bounds
    }

    /// A hand-drawn arrow from one piece to another. Within a line it arcs over the top, from the top of one to the
    /// top of the other; between lines it swoops from edge to edge. `apex` is the middle of the curve and `outward`
    /// the way it bows, for a label.
    static func curvedArrow(from a: CGRect, to b: CGRect) -> (path: [CGPoint], apex: CGPoint, outward: CGPoint) {
        let sameLine = abs(a.midY - b.midY) < max(a.height, b.height) * 0.6
        let start: CGPoint, end: CGPoint, control: CGPoint, outward: CGPoint
        if sameLine {
            start = CGPoint(x: a.midX, y: a.minY - 4)
            end = CGPoint(x: b.midX, y: b.minY - 4)
            let rise = min(44, max(16, abs(end.x - start.x) * 0.45))
            control = CGPoint(x: (start.x + end.x) / 2, y: min(start.y, end.y) - rise * 2)
            outward = CGPoint(x: 0, y: -1)
        } else {
            start = AgentGeometry.edgePoint(of: a, toward: CGPoint(x: b.midX, y: b.midY), gap: 4)
            end = AgentGeometry.edgePoint(of: b, toward: CGPoint(x: a.midX, y: a.midY), gap: 5)
            let dx = end.x - start.x, dy = end.y - start.y
            let length = max(hypot(dx, dy), 1)
            // Bow to the left of the direction of travel: a downward stroke to the left swoops out and round.
            let n = CGPoint(x: dy / length, y: -dx / length)
            let bow = min(40, length * 0.25)
            control = CGPoint(x: (start.x + end.x) / 2 + n.x * bow, y: (start.y + end.y) / 2 + n.y * bow)
            outward = n
        }
        let steps = 24
        let path = (0...steps).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(steps), u = 1 - t
            return CGPoint(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                           y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
        }
        let apex = path[steps / 2]
        return (hypot(end.x - start.x, end.y - start.y) < 4 ? [start] : path, apex, outward)
    }
}

extension AgentGeometry {
    /// The ink of the `nth` occurrence of `part` across `lines` (in order), in page points: the glyphs' own outlines,
    /// so a superscript's box is small and high. Matched exactly, then ignoring case. Nil if it isn't there.
    static func inkBox(of part: String, nth: Int = 1, in lines: [AgentText]) -> CGRect? {
        var remaining = nth
        for options: String.CompareOptions in [[], [.caseInsensitive]] {
            remaining = nth
            for line in lines {
                var search = line.text.startIndex..<line.text.endIndex
                while let found = line.text.range(of: part, options: options, range: search) {
                    remaining -= 1
                    if remaining == 0 { return inkBox(of: found, in: line) }
                    search = found.upperBound..<line.text.endIndex
                }
            }
        }
        return nil
    }

    /// The ink of the characters in `range` of `line`, in page points.
    static func inkBox(of range: Range<String.Index>, in line: AgentText) -> CGRect? {
        let utf16 = line.text.utf16
        let lo = utf16.distance(from: utf16.startIndex, to: range.lowerBound)
        let hi = utf16.distance(from: utf16.startIndex, to: range.upperBound)
        let font = Handwriting.font(size: line.size)
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
        let origin = HandwritingLine.make(line.text, size: line.size).origin(centeredOn: line.center)
        var box = CGRect.null
        var advanceBox = CGRect.null
        for run in CTLineGetGlyphRuns(ct) as? [CTRun] ?? [] {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont = attributes[kCTFontAttributeName].map { $0 as! CTFont } ?? (font as CTFont)
            for g in 0..<count where indices[g] >= lo && indices[g] < hi {
                var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[g].x, ty: 0)
                if let path = CTFontCreatePathForGlyph(runFont, glyphs[g], &flip), !path.boundingBoxOfPath.isEmpty {
                    box = box.union(path.boundingBoxOfPath)
                }
                advanceBox = advanceBox.union(CGRect(x: positions[g].x, y: -font.xHeight, width: advances[g].width,
                                                     height: font.xHeight))
            }
        }
        // Only spaces: where they'd be, x-height tall.
        let local = box.isNull ? advanceBox : box
        guard !local.isNull else { return nil }
        return local.offsetBy(dx: origin.x, dy: origin.y)
    }
}
