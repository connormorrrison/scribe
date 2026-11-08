import CoreGraphics
import Foundation

// A worked solution, laid out by the app rather than step by step by the agent: one column beside the question, each
// step on its own line in blue, a grey arrow down between steps with a few words on the move, the marks on each step's
// characters in orange with room kept for them, and the answer boxed in green. Every step is its own mark, so the pen
// writes them one after another.
//
// Ink colours: blue is the working, orange shows a move (what goes where, what changes, what cancels), grey joins one
// step to the next, green is the answer (and what's right), red is a mistake, yellow highlights what the question
// gives you.

extension ActionValidator {
    struct StepInput: Decodable {
        var text: String
        /// The move that got here from the step before, written beside the arrow down to it.
        var why: String?
        var annotate: [AnnotationInput]?
    }

    struct StepsInput: Decodable {
        var steps: [StepInput]
        var near: PageTarget?
        var side: PlacementSide?
        /// The part of the last step that's the answer; the part after its last "=" if not given.
        var answer: String?
        /// False when the last step isn't an answer (the working stops part way, in coach mode).
        var box_answer: Bool?
    }

    static let connectorColor = colorNames["gray"]!
    static let answerColor = colorNames["green"]!

    /// The answer in the last step: after its last "=", or all of it.
    static func answerPart(of text: String) -> String {
        guard let eq = text.range(of: "=", options: .backwards) else { return text }
        let tail = text[eq.upperBound...].trimmingCharacters(in: .whitespaces)
        return tail.isEmpty ? text : tail
    }

    static func steps(_ input: StepsInput, _ c: inout ToolContext) throws -> ToolDecision {
        guard !input.steps.isEmpty else { return .reject("give at least one step") }
        guard input.steps.count <= 8 else { return .reject("that's \(input.steps.count) steps; use at most 8, or split the working") }
        guard let near = input.near else { return .reject("give `near`: the question or their working") }
        let size = c.textSize(.math)
        let whySize: CGFloat = 18
        let color = InkSwatch.blueHex

        // Each step's text and its annotations, the last with the answer's green box.
        var lines: [[String]] = []
        var annotations: [[AnnotationInput]] = []
        for (i, step) in input.steps.enumerated() {
            let split = step.text.replacingOccurrences(of: "\\n", with: "\n").split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !split.isEmpty else { return .reject("step \(i + 1) has no text") }
            guard split.count <= 2 else { return .reject("step \(i + 1) is \(split.count) lines; keep each step to one line") }
            var marks = step.annotate ?? []
            guard marks.count <= 5 else { return .reject("step \(i + 1) has \(marks.count) annotations; use at most 5") }
            if i == input.steps.count - 1, input.box_answer != false {
                let answer = input.answer ?? answerPart(of: split.joined(separator: " "))
                marks.removeAll { $0.kind == .box }
                marks.append(AnnotationInput(kind: .box, on: PartRef(text: answer), color: "green"))
            }
            lines.append(split)
            annotations.append(marks)
        }

        // Lay out the column at the origin: how much room each step's own marks need around its text.
        func written(_ text: [String], in rect: CGRect) -> [AgentText] {
            let height = rect.height / CGFloat(text.count)
            return text.enumerated().map { i, line in
                AgentText(text: line, center: CGPoint(x: rect.minX + AgentGeometry.textSize(line, size: size).width / 2 + 4,
                                                      y: rect.minY + height * (CGFloat(i) + 0.5)),
                          size: size, color: color)
            }
        }
        var boxes: [CGRect] = []
        var insets: [(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat)] = []
        for (i, text) in lines.enumerated() {
            let sizes = text.map { AgentGeometry.textSize($0, size: size) }
            let box = CGRect(x: 0, y: 0, width: (sizes.map(\.width).max() ?? 0) + 8,
                             height: sizes.reduce(0) { $0 + $1.height } + 4)
            var local = c
            local.stepLines = []
            let reach = annotate(annotations[i].filter(\.isLocal), lines: written(text, in: box), local).items
                .reduce(box) { $0.union($1.bounds) }
            boxes.append(box)
            insets.append((box.minX - reach.minX, box.minY - reach.minY, reach.maxX - box.maxX, reach.maxY - box.maxY))
        }
        let whys = input.steps.map { $0.why?.trimmingCharacters(in: .whitespaces) }.map { $0?.isEmpty == false ? $0 : nil }
        let whyHeight = AgentGeometry.textSize("bring down", size: whySize).height
        let gap = max(40, whyHeight + 14)
        let left = max(28, insets.map(\.left).max() ?? 0)
        var rects: [CGRect] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        for (i, box) in boxes.enumerated() {
            if i > 0 { y += gap }
            y += insets[i].top
            rects.append(CGRect(x: left, y: y, width: box.width, height: box.height))
            y += box.height + insets[i].bottom
            width = max(width, left + box.width + insets[i].right)
            if let why = whys[i], i > 0 {
                width = max(width, left - 4 + AgentGeometry.textSize(why, size: whySize).width + 8)
            }
        }
        let column = CGSize(width: width, height: y)

        // Find room for the whole column beside what it's about.
        let target = try resolve(near, c)
        let placed = target.isFreeSpace ? placeInside(column, space: target.bounds, &c)
            : place(column, near: target.bounds, side: input.side ?? .right, &c)
        let origin = placed.rect.origin
        let texts = zip(lines, rects).map { written($0, in: $1.offsetBy(dx: origin.x, dy: origin.y)) }

        // Each step as its own mark: the arrow down to it and why, the line, then the marks on it.
        var marks: [AgentMark] = []
        var skipped: [String] = []
        let arrowX = origin.x + left - 14
        for (i, text) in texts.enumerated() {
            var items: [AgentInk] = []
            if i > 0 {
                let above = rects[i - 1].offsetBy(dx: origin.x, dy: origin.y), here = rects[i].offsetBy(dx: origin.x, dy: origin.y)
                let top = above.maxY + insets[i - 1].bottom + 4, bottom = here.minY - insets[i].top - 4
                let start = CGPoint(x: arrowX, y: top), end = CGPoint(x: arrowX, y: max(bottom, top + 16))
                items.append(.stroke(AgentStroke(points: handLine(start, end), color: connectorColor, width: 2)))
                items.append(.stroke(AgentStroke(points: AgentGeometry.arrowHead(from: start, to: end, length: 9),
                                                 color: connectorColor, width: 2)))
                if let why = whys[i] {
                    let s = AgentGeometry.textSize(why, size: whySize)
                    items.append(.text(AgentText(text: why, center: CGPoint(x: arrowX + 12 + s.width / 2, y: (start.y + end.y) / 2),
                                                 size: whySize, color: connectorColor)))
                }
            }
            items += text.map(AgentInk.text)
            var local = c
            local.stepLines = texts
            local.currentStep = i
            let marked = annotate(annotations[i], lines: text, local)
            items += marked.items
            skipped += marked.skipped.map { "step \(i + 1): \($0)" }
            marks.append(AgentMark(turn: c.turn, kind: "step", text: lines[i].joined(separator: " "), target: target.objectID,
                                   items: items))
        }
        var result = "ok, \(marks.count) steps at \(PageMap.format(placed.rect))"
        if !skipped.isEmpty { result += "; skipped: " + skipped.joined(separator: "; ") }
        return ToolDecision(marks: marks, result: result, notes: [target.note, placed.note] + skipped)
    }
}
