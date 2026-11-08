import CoreGraphics
import Foundation

/// Turns the agent's drawing tool calls into marks, checking each before anything reaches the page: the input, the
/// targets (snapped to the page map), placement (clear of everything, on the page), and the turn's budget. A rejection
/// carries a reason the agent can act on; it goes back as an `is_error` tool result.
enum ActionValidator {
    /// What one tool call became.
    struct ToolDecision {
        var marks: [AgentMark] = []
        /// Points to add to the bottom of the page first.
        var growPage: CGFloat = 0
        /// The agent's marks to remove.
        var erase: Set<UUID> = []
        /// The tool result: "ok", facts the agent may need, or why it was rejected.
        var result: String
        var isError = false
        /// Snapping and placement notes, for the debug log.
        var notes: [String] = []
        /// It didn't fit on a page that can't grow (a document page): it belongs on a blank page after it.
        var overflow = false

        static func reject(_ reason: String, notes: [String] = []) -> ToolDecision {
            ToolDecision(result: "rejected: " + reason, isError: true, notes: notes)
        }
    }

    /// Everything the validator knows about this turn. It changes as calls are accepted (the page grows, marks take
    /// space).
    struct ToolContext {
        var map: PageMap
        /// The page as it will be when the accepted calls have run (extend_page included).
        var pageSize: CGSize
        /// Where the agent has drawn (before, and this turn): placement keeps clear of it.
        var placed: [CGRect]
        var inkHeight: CGFloat
        /// What's drawn where, from the page picture (plus cards and reserved answer spaces).
        var occupancy: OccupancyGrid?
        var turn: UUID
        /// The agent's marks on the page, in order: am_N is the Nth. Marks drawn this turn are added as they're accepted.
        var markIDs: [UUID]
        var drawn = 0

        init(snapshot: PageMapSnapshot, marks: [AgentMark], turn: UUID = UUID()) {
            map = snapshot.map
            pageSize = snapshot.pageSize
            placed = snapshot.agentMarks.map(\.bounds)
            inkHeight = snapshot.studentInkHeight
            occupancy = snapshot.occupancy
            self.turn = turn
            markIDs = marks.map(\.id)
        }

        var pageRect: CGRect { CGRect(origin: .zero, size: pageSize) }

        /// Their ink and printed lines: what the agent's writing must never cover, even when told where to write.
        var hardObstacles: [CGRect] {
            map.objects.filter { $0.parent == nil && $0.source == .studentInk || ($0.source == .pdfText && $0.kind == "line") }
                .map(\.bounds)
        }

        /// Everything placement keeps clear of: the above, printed graphics and photos, cards, and the agent's marks.
        var obstacles: [CGRect] {
            let printed = map.objects.filter { $0.source == .printed && !PageLayout.nestedKinds.contains($0.kind) }.map(\.bounds)
            let cards = map.objects.filter { $0.source == .card }.map(\.bounds)
            return hardObstacles + printed + cards + placed + chrome
        }

        /// True when `r` would sit on anything: an obstacle's box or a drawn pixel.
        func isBlocked(_ r: CGRect) -> Bool {
            if obstacles.contains(where: { $0.insetBy(dx: -4, dy: -4).intersects(r) }) { return true }
            return !(occupancy?.isFree(r.insetBy(dx: -2, dy: -2)) ?? true)
        }

        /// Note, label and maths sizes: the landing page's handwriting (26 pt notes, 22 pt labels on a 1194 pt wide
        /// screen), in page points. They stay put however large the person writes, so the agent's ink stays quiet
        /// beside theirs.
        func textSize(_ size: WriteSize) -> CGFloat {
            switch size {
            case .note: 24
            case .label: 20
            case .math: 26
            }
        }

        /// Where the floating controls cover the page (page points). Nothing the agent makes goes under them.
        var chrome: [CGRect] = []
        /// False for a page of an imported document: it keeps its size, so it still prints and exports like the
        /// original. What doesn't fit goes on a blank page after it instead.
        var canGrow = true
        /// A blank page the agent took for what didn't fit on the page before it: anything goes anywhere on it, from
        /// the top down.
        var scratch = false
        /// Set by placement when nothing fits and the page can't grow.
        fileprivate var overflowed = false

        /// `r` moved straight down (or, near the bottom, up) until it's clear of the controls.
        func clearOfChrome(_ r: CGRect) -> CGRect {
            var out = r
            for _ in 0..<4 {
                guard let hit = chrome.first(where: { $0.insetBy(dx: -6, dy: -6).intersects(out) }) else { break }
                if hit.midY < pageSize.height / 2 {
                    out.origin.y = hit.maxY + 10
                } else {
                    out.origin.y = hit.minY - 10 - out.height
                }
            }
            return out
        }
    }

    /// Marks a turn may draw.
    static let budget = 16

    static func validate(_ name: String, input: JSONValue, context: inout ToolContext) -> ToolDecision {
        guard AgentTools.names.contains(name) else { return .reject("there's no tool `\(name)`") }
        if name != "erase_marks" && name != "extend_page", context.drawn >= budget {
            return .reject("that's enough marks for one turn; finish with a short line")
        }
        var decision: ToolDecision
        do {
            switch name {
            case "write": decision = try write(ToolInput.decode(WriteInput.self, from: input), &context)
            case "mark": decision = try mark(ToolInput.decode(MarkInput.self, from: input), &context)
            case "outline_region": decision = try outline(ToolInput.decode(OutlineInput.self, from: input), &context)
            case "draw": decision = try draw(ToolInput.decode(DrawInput.self, from: input), &context)
            case "extend_page": decision = try extend(ToolInput.decode(ExtendInput.self, from: input), &context)
            case "erase_marks": decision = try erase(ToolInput.decode(EraseInput.self, from: input), &context)
            default: return .reject("there's no tool `\(name)`")
            }
        } catch let error as ToolInputError {
            return .reject(error.reason)
        } catch {
            return .reject("the input isn't valid")
        }
        if context.overflowed {
            context.overflowed = false
            var overflow = ToolDecision.reject("there's no room for it on this page")
            overflow.overflow = true
            return overflow
        }
        guard !decision.isError else { return decision }
        // The new marks' ids, so the agent can erase them.
        for mark in decision.marks {
            context.markIDs.append(mark.id)
            context.placed.append(mark.bounds)
        }
        context.drawn += decision.marks.count
        if !decision.marks.isEmpty {
            let first = context.markIDs.count - decision.marks.count + 1
            let ids = (first...context.markIDs.count).map { "am_\($0)" }
            decision.result += " (\(ids.joined(separator: ", ")))"
        }
        return decision
    }

    // MARK: Inputs

    enum WriteSize: String, Decodable { case note, label, math }
    enum MarkKind: String, Decodable { case circle, underline, highlight, check, cross, box, arrow }

    struct WriteInput: Decodable {
        var text: String
        var size: WriteSize?
        var near: PageTarget?
        var side: PlacementSide?
        var at: [Double]?
        var color: String?
    }

    struct MarkInput: Decodable {
        var kind: MarkKind
        var target: PageTarget?
        var from: PageTarget?
        var to: PageTarget?
        var color: String?
    }

    struct OutlineInput: Decodable {
        var target: PageTarget?
        /// Several things traced as one mark (the parts of a continent, all the islands of a country).
        var targets: [PageTarget]?
        var color: String?
        var fill: Bool?
        var label: String?
    }

    struct DrawInput: Decodable {
        var shapes: [JSONValue]
        var size: [Double]?
        var near: PageTarget?
        var side: PlacementSide?
        var at: [Double]?
    }

    struct ExtendInput: Decodable { var height: Double }
    struct EraseInput: Decodable { var ids: [String] }

    // MARK: write

    private static func write(_ input: WriteInput, _ c: inout ToolContext) throws -> ToolDecision {
        let lines = input.text.replacingOccurrences(of: "\\n", with: "\n").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return .reject("write needs some text") }
        guard lines.count <= 4 else { return .reject("that's \(lines.count) lines; write at most 3 short lines at a time") }
        let size = c.textSize(input.size ?? .note)
        let color = try parseColor(input.color)
        let sizes = lines.map { AgentGeometry.textSize($0, size: size) }
        let lineHeight = sizes.map(\.height).max() ?? size
        let box = CGSize(width: (sizes.map(\.width).max() ?? 0) + 8, height: lineHeight * CGFloat(lines.count) + 4)

        var notes: [String] = []
        var grow: CGFloat = 0
        let rect: CGRect
        if let at = input.at {
            guard at.count == 2 else { return .reject("`at` must be [x, y]") }
            let r = CGRect(x: at[0] - box.width / 2, y: at[1] - box.height / 2, width: box.width, height: box.height)
            var spot = c.clearOfChrome(fit(r, in: c.pageRect))
            notes.append("at \(Int(at[0])),\(Int(at[1]))" + (spot.origin == r.origin ? "" : " (moved onto the page, clear of the controls)"))
            // An exact spot may sit on a figure (a label on a diagram), but never on text or their ink.
            if covers(spot, c.hardObstacles) {
                let blockers = c.hardObstacles.map { $0.insetBy(dx: -3, dy: -3) } + c.placed + c.chrome
                if let free = c.occupancy?.nearestFree(size: spot.size, near: spot, in: c.pageRect.insetBy(dx: 6, dy: 6),
                                                       avoiding: blockers, maxDistance: 64)
                    ?? Placement.nearestClear(spot, avoiding: blockers, in: c.pageRect, maxDistance: 64) {
                    notes.append("moved \(Int(hypot(free.midX - spot.midX, free.midY - spot.midY))) pt off text or ink")
                    spot = free
                } else {
                    notes.append("covers text or ink")
                }
            }
            rect = spot
        } else {
            guard let near = input.near else { return .reject("give `near` (and `side`), or `at`") }
            let t = try resolve(near, c)
            notes.append(t.note)
            let placed = t.isFreeSpace ? placeInside(box, space: t.bounds, &c)
                : place(box, near: t.bounds, side: input.side ?? .right, &c)
            grow = placed.grow
            rect = placed.rect
            notes.append(placed.note)
        }

        let items = lines.enumerated().map { i, line in
            AgentInk.text(AgentText(text: line, center: CGPoint(x: rect.midX, y: rect.minY + 2 + lineHeight * (CGFloat(i) + 0.5)),
                                    size: size, color: color))
        }
        let mark = AgentMark(turn: c.turn, kind: input.size == .label ? "label" : "note", text: lines.joined(separator: " "),
                             target: nil, items: items)
        var result = "ok, wrote at \(PageMap.format(rect))"
        if let moved = notes.first(where: { $0.hasPrefix("moved ") || $0 == "covers text or ink" || $0.hasPrefix("no room") }) {
            result += " (\(moved))"
        }
        return ToolDecision(marks: [mark], growPage: grow, result: result, notes: notes)
    }

    // MARK: mark

    private static func mark(_ input: MarkInput, _ c: inout ToolContext) throws -> ToolDecision {
        let color = try parseColor(input.color)
        if input.kind == .arrow {
            guard let fromTarget = input.from ?? input.target, let toTarget = input.to else {
                return .reject("an arrow needs `from` and `to` targets")
            }
            let a = try resolve(fromTarget, c), b = try resolve(toTarget, c)
            let start = clamp(AgentGeometry.edgePoint(of: a.bounds, toward: center(b.bounds), gap: 8), to: c.pageRect)
            let end = clamp(AgentGeometry.edgePoint(of: b.bounds, toward: center(a.bounds), gap: 8), to: c.pageRect)
            guard hypot(end.x - start.x, end.y - start.y) > 12 else { return .reject("those two are too close for an arrow") }
            let mark = AgentMark(turn: c.turn, kind: "arrow", target: b.objectID, items: [
                .stroke(AgentStroke(points: handLine(start, end), color: color)),
                .stroke(AgentStroke(points: AgentGeometry.arrowHead(from: start, to: end), color: color)),
            ])
            return ToolDecision(marks: [mark], result: "ok, arrow from \(a.objectID ?? "there") to \(b.objectID ?? "there")",
                                notes: [a.note, b.note])
        }
        guard let target = input.target else { return .reject("`\(input.kind.rawValue)` needs a `target`") }
        let t = try resolve(target, c)
        let b = t.bounds
        let page = c.pageRect
        var items: [AgentInk]
        switch input.kind {
        case .circle:
            let r = b.insetBy(dx: -max(10, b.width * 0.12), dy: -max(8, b.height * 0.3))
                .union(CGRect(x: b.midX - 20, y: b.midY - 16, width: 40, height: 32))
            items = [.stroke(AgentStroke(points: AgentGeometry.handEllipse(clamp(r, to: page), seed: c.markIDs.count),
                                         color: color))]
        case .underline:
            let y = min(page.maxY - 2, b.maxY + 5)
            items = [.stroke(AgentStroke(points: handLine(CGPoint(x: b.minX - 2, y: y), CGPoint(x: b.maxX + 2, y: y + 1)),
                                         color: color))]
        case .highlight:
            let r = clamp(b.insetBy(dx: -4, dy: -3), to: page)
            let hex = input.color == nil ? InkSwatch.yellowHighlighter.inkHex : color
            items = [.stroke(AgentStroke(points: AgentGeometry.roundedRect(r, radius: 4), color: hex, closed: true, fill: 0.4,
                                         stroked: false, highlight: true))]
        case .check:
            items = [.stroke(AgentStroke(points: AgentGeometry.checkPoints(at: tickSpot(beside: b, c), size: 28),
                                         color: input.color == nil ? colorNames["green"]! : color, width: 3.5))]
        case .cross:
            let p = tickSpot(beside: b, c)
            let red = input.color == nil ? colorNames["red"]! : color
            items = [.stroke(AgentStroke(points: [CGPoint(x: p.x - 10, y: p.y - 10), CGPoint(x: p.x + 10, y: p.y + 10)],
                                         color: red, width: 3.5)),
                     .stroke(AgentStroke(points: [CGPoint(x: p.x + 10, y: p.y - 10), CGPoint(x: p.x - 10, y: p.y + 10)],
                                         color: red, width: 3.5))]
        case .box:
            items = [.stroke(AgentStroke(points: AgentGeometry.roundedRect(clamp(b.insetBy(dx: -6, dy: -6), to: page), radius: 8),
                                         color: color, closed: true))]
        case .arrow:
            return .reject("an arrow needs `from` and `to` targets")
        }
        let mark = AgentMark(turn: c.turn, kind: input.kind.rawValue, target: t.objectID, items: items)
        return ToolDecision(marks: [mark], result: "ok, \(input.kind.rawValue) on \(t.objectID ?? PageMap.format(b))",
                            notes: [t.note])
    }

    /// Where a tick or cross goes: right of the target, else left, else above, whichever is clear; right if none is.
    private static func tickSpot(beside b: CGRect, _ c: ToolContext) -> CGPoint {
        let inner = c.pageRect.insetBy(dx: 16, dy: 16)
        let candidates = [CGPoint(x: b.maxX + 22, y: b.midY), CGPoint(x: b.minX - 22, y: b.midY),
                          CGPoint(x: b.maxX - 8, y: b.minY - 18)].map { clamp($0, to: inner) }
        let clear = candidates.first { p in !c.isBlocked(CGRect(x: p.x - 12, y: p.y - 12, width: 24, height: 24)) }
        return clear ?? candidates[0]
    }

    /// A straight line with a little of a hand's unsteadiness.
    private static func handLine(_ a: CGPoint, _ b: CGPoint) -> [CGPoint] {
        let n = max(2, Int(hypot(b.x - a.x, b.y - a.y) / 12))
        let length = hypot(b.x - a.x, b.y - a.y)
        let normal = length > 0 ? CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length) : .zero
        return (0...n).map { i in
            let t = CGFloat(i) / CGFloat(n)
            let wobble = sin(t * .pi) * 1.2 * sin(t * 7)
            return CGPoint(x: a.x + (b.x - a.x) * t + normal.x * wobble, y: a.y + (b.y - a.y) * t + normal.y * wobble)
        }
    }

    // MARK: outline_region

    private static func outline(_ input: OutlineInput, _ c: inout ToolContext) throws -> ToolDecision {
        let wanted = (input.target.map { [$0] } ?? []) + (input.targets ?? [])
        guard !wanted.isEmpty else { return .reject("give `target`, or `targets` for several") }
        guard wanted.count <= 40 else { return .reject("at most 40 `targets` at once") }
        let resolved = try wanted.map { try resolve($0, c) }
        let color = try parseColor(input.color)
        let page = c.pageRect
        var items: [AgentInk] = []
        var traced: [String] = []
        for t in resolved {
            if t.outline == nil, let paths = t.paths?.filter({ $0.count >= 2 }), !paths.isEmpty {
                // An open shape (a printed diagram, an answer line, their drawing): its own lines, exactly.
                items += paths.map { .stroke(AgentStroke(points: $0.map { clamp($0, to: page) }, color: color)) }
                traced.append("\(paths.count) line\(paths.count == 1 ? "" : "s") of \(t.objectID ?? "the target")")
            } else {
                let ring = (t.outline ?? AgentGeometry.roundedRect(t.bounds.insetBy(dx: -5, dy: -5), radius: 8)).map { clamp($0, to: page) }
                items.append(.stroke(AgentStroke(points: ring, color: color, closed: true, fill: input.fill == true ? 0.18 : nil)))
                traced.append((t.outline == nil ? "the box around " : "the outline of ") + (t.objectID ?? "the target"))
            }
        }
        let t = ResolvedTarget(bounds: resolved.map(\.bounds).reduce(CGRect.null) { $0.union($1) }, objectID: nil,
                               snapped: false, note: resolved.map(\.note).joined(separator: "; "))
        let ids = resolved.compactMap(\.objectID)
        var grow: CGFloat = 0
        let label = input.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !label.isEmpty {
            let size = c.textSize(.label)
            let s = AgentGeometry.textSize(label, size: size)
            let box = CGSize(width: s.width + 8, height: s.height + 4)
            // A part of a figure (a continent) is labelled on itself, like a map; anything else beside it.
            let parts = resolved.filter { r in r.objectID.flatMap { c.map.object($0) }.map { ["part", "area"].contains($0.kind) } ?? false }
            if let biggest = parts.max(by: { PageMap.area($0.bounds) < PageMap.area($1.bounds) }), let ring = biggest.outline,
               let spot = labelSpot(box, inside: ring, c) {
                items.append(.text(AgentText(text: label, center: center(spot), size: size, color: color)))
                c.placed.append(spot)
            } else {
                let placed = place(box, near: t.bounds, side: .right, &c)
                grow = placed.grow
                items.append(.text(AgentText(text: label, center: center(placed.rect), size: size, color: color)))
            }
        }
        let mark = AgentMark(turn: c.turn, kind: "outline", text: label.isEmpty ? nil : label,
                             target: ids.isEmpty ? nil : ids.joined(separator: "+"), items: items)
        return ToolDecision(marks: [mark], growPage: grow, result: "ok, traced " + traced.joined(separator: ", "),
                            notes: [t.note])
    }

    /// Room for a label inside a shape: the spot nearest its middle where the whole label is inside the outline, off
    /// printed text, their ink and the agent's other marks. Nil when it doesn't fit.
    static func labelSpot(_ size: CGSize, inside ring: [CGPoint], _ c: ToolContext) -> CGRect? {
        let b = FigureRegions.bounds(ring)
        guard b.width > size.width, b.height > size.height else { return nil }
        // The middle: the outline's centroid (by area), else the box's.
        var a: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for i in ring.indices {
            let p = ring[i], q = ring[(i + 1) % ring.count]
            let k = p.x * q.y - q.x * p.y
            a += k; cx += (p.x + q.x) * k; cy += (p.y + q.y) * k
        }
        let middle = abs(a) > 1 ? CGPoint(x: cx / (3 * a), y: cy / (3 * a)) : CGPoint(x: b.midX, y: b.midY)
        let blockers = c.hardObstacles.map { $0.insetBy(dx: -3, dy: -3) } + c.placed + c.chrome
        let step = max(4, min(b.width, b.height) / 24)
        var best: (CGRect, CGFloat)?
        var y = b.minY + size.height / 2
        while y <= b.maxY - size.height / 2 {
            var x = b.minX + size.width / 2
            while x <= b.maxX - size.width / 2 {
                let r = CGRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height)
                let d = hypot(x - middle.x, y - middle.y)
                if d < (best?.1 ?? .infinity),
                   [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY),
                    CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.midX, y: r.maxY)]
                    .allSatisfy({ PageMap.polygonContains(ring, $0) }),
                   !blockers.contains(where: { $0.intersects(r) }) {
                    best = (r, d)
                }
                x += step
            }
            y += step
        }
        return best?.0
    }

    // MARK: draw

    private static func draw(_ input: DrawInput, _ c: inout ToolContext) throws -> ToolDecision {
        var size = DrawBuilder.defaultSize
        if let s = input.size {
            guard s.count == 2, s[0] > 0, s[1] > 0 else { return .reject("`size` must be [w, h] in points") }
            size = CGSize(width: min(max(s[0], DrawBuilder.minSize.width), DrawBuilder.maxSize.width),
                          height: min(max(s[1], DrawBuilder.minSize.height), DrawBuilder.maxSize.height))
        }
        let parsed = try DrawBuilder.parse(input.shapes, size: size, labelSize: c.textSize(.label), noteSize: c.textSize(.note))

        var notes: [String] = []
        var grow: CGFloat = 0
        let frame: CGRect
        if let at = input.at {
            guard at.count == 2 else { return .reject("`at` must be [x, y]: the box's top-left corner in page points") }
            let r = CGRect(x: at[0], y: at[1], width: size.width, height: size.height)
            frame = c.clearOfChrome(fit(r, in: c.pageRect))
            notes.append("at \(Int(at[0])),\(Int(at[1]))" + (frame.origin == r.origin ? "" : " (moved onto the page, clear of the controls)"))
        } else {
            var anchor = CGRect(x: c.pageSize.width / 2, y: c.pageSize.height / 2, width: 0, height: 0)
            var inFree = false
            if let near = input.near {
                let t = try resolve(near, c)
                anchor = t.bounds
                inFree = t.isFreeSpace
                notes.append(t.note)
            }
            let placed = inFree ? placeInside(size, space: anchor, &c) : place(size, near: anchor, side: input.side ?? .right, &c)
            grow = placed.grow
            frame = placed.rect
            notes.append(placed.note)
        }

        let layout = DrawBuilder.layout(parsed, in: frame)
        let mark = AgentMark(turn: c.turn, kind: "drawing", text: parsed.texts.isEmpty ? nil : parsed.texts.joined(separator: ", "),
                             target: nil, items: layout.items)
        var result = "ok, drew \(parsed.count) shape\(parsed.count == 1 ? "" : "s") in \(PageMap.format(frame))"
        var checks = layout.notes
        if parsed.clamped {
            checks.insert("some points were outside the \(Int(size.width))×\(Int(size.height)) box and were pulled in", at: 0)
        }
        if !checks.isEmpty { result += ". Check: " + checks.prefix(4).joined(separator: "; ") }
        return ToolDecision(marks: [mark], growPage: grow, result: result, notes: notes + checks)
    }

    // MARK: extend_page and erase_marks

    private static func extend(_ input: ExtendInput, _ c: inout ToolContext) throws -> ToolDecision {
        guard c.canGrow else {
            return .reject("this is a page of their document, so it keeps its size. Write or draw as usual: what doesn't fit goes on a blank page after it by itself")
        }
        let h = CGFloat(min(800, max(100, input.height)))
        c.pageSize.height += h
        return ToolDecision(growPage: h, result: "ok, the page is now \(Int(c.pageSize.width))×\(Int(c.pageSize.height)) pt; "
                            + "the new space is y \(Int(c.pageSize.height - h))–\(Int(c.pageSize.height))")
    }

    private static func erase(_ input: EraseInput, _ c: inout ToolContext) throws -> ToolDecision {
        var ids = Set<UUID>()
        for name in input.ids {
            guard name.hasPrefix("am_"), let n = Int(name.dropFirst(3)), (1...c.markIDs.count).contains(n) else {
                return .reject("there's no mark `\(name)`; your marks are am_1…am_\(c.markIDs.count)")
            }
            ids.insert(c.markIDs[n - 1])
        }
        return ToolDecision(erase: ids, result: "ok, erased \(input.ids.joined(separator: ", "))")
    }

    // MARK: Targets

    private static func resolve(_ target: PageTarget, _ c: ToolContext) throws -> ResolvedTarget {
        if c.scratch {
            // A blank page of its own: whatever it was near is on the page before. Fill it from the top down.
            let body = c.pageRect.insetBy(dx: 60, dy: 0)
            return ResolvedTarget(bounds: CGRect(x: body.minX, y: 0, width: body.width, height: c.pageRect.height),
                                  snapped: false, note: "on the blank page", isFreeSpace: true)
        }
        if case .point(let p) = target, !c.pageRect.insetBy(dx: -1, dy: -1).contains(p) {
            throw ToolInputError("point \(Int(p.x)),\(Int(p.y)) is off the page (\(Int(c.pageSize.width))×\(Int(c.pageSize.height)) pt)")
        }
        guard let r = c.map.resolve(target: target, pageSize: c.pageSize) else {
            if case .id(let id, _) = target {
                if id.hasPrefix("am_") { throw ToolInputError("`\(id)` is one of your marks; target what it marks instead") }
                throw ToolInputError("there's no `\(id)` on the page map")
            }
            throw ToolInputError("that target isn't on the page")
        }
        return r
    }

    // MARK: Placement

    /// A clear spot for `size` beside `anchor`; or the nearest clear spot not far off; or, when there's none, new
    /// space added below the page.
    static func place(_ size: CGSize, near anchor: CGRect, side: PlacementSide, _ c: inout ToolContext)
        -> (rect: CGRect, grow: CGFloat, note: String) {
        if let r = Placement.find(size: size, near: anchor, side: side, page: c.pageRect, obstacles: c.obstacles,
                                  occupancy: c.occupancy) {
            return (r.rect, 0, "placed \(r.side.rawValue) \(PageMap.format(r.rect))")
        }
        let area = c.pageRect.insetBy(dx: Placement.margin, dy: Placement.margin)
        let blockers = c.obstacles.map { $0.insetBy(dx: -4, dy: -4) }
        let nearest: CGRect?
        if let grid = c.occupancy {
            nearest = grid.nearestFree(size: size, near: anchor, in: area, avoiding: blockers, maxDistance: Placement.farthest)
        } else {
            nearest = Placement.nearestClear(CGRect(origin: CGPoint(x: anchor.minX, y: anchor.maxY + Placement.gap), size: size),
                                             avoiding: blockers, in: area, maxDistance: Placement.farthest)
        }
        if let r = nearest {
            return (r, 0, "nothing beside it; nearest clear spot \(PageMap.format(r))")
        }
        guard c.canGrow else {
            c.overflowed = true
            return (CGRect(origin: .zero, size: size), 0, "no room on this page")
        }
        let grow = max(160, size.height + 80)
        let oldHeight = c.pageSize.height
        c.pageSize.height += grow
        let x = min(max(anchor.minX, Placement.margin), max(Placement.margin, c.pageSize.width - size.width - Placement.margin))
        let rect = CGRect(x: x, y: oldHeight + 30, width: size.width, height: size.height)
        return (rect, grow, "no room: added \(Int(grow)) pt below the page, placed \(PageMap.format(rect))")
    }

    /// Inside a free space: the clear spot furthest left, then highest, so later writes this turn go under earlier
    /// ones. With room to spare it keeps off the space's edges and from what's already there; when the space is
    /// tight, it packs in. Too small for it: beside the space instead.
    static func placeInside(_ size: CGSize, space: CGRect, _ c: inout ToolContext) -> (rect: CGRect, grow: CGFloat, note: String) {
        for room in [Placement.roomy, Placement.tight] {
            let inner = space.insetBy(dx: room.edge, dy: room.edge)
            guard size.width <= inner.width, size.height <= inner.height else { continue }
            for x in stride(from: inner.minX, through: inner.maxX - size.width, by: 4) {
                for y in stride(from: inner.minY, through: inner.maxY - size.height, by: 4) {
                    let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                    if !c.isBlocked(r.insetBy(dx: -(room.pad - 4), dy: -(room.pad - 4))) {
                        return (r, 0, "inside the free space \(PageMap.format(r))")
                    }
                }
            }
        }
        let fallback = place(size, near: space, side: .below, &c)
        return (fallback.rect, fallback.grow, "didn't fit in the free space; " + fallback.note)
    }

    /// More than a sliver of `r` is covered by `rects`.
    private static func covers(_ r: CGRect, _ rects: [CGRect]) -> Bool {
        let covered = rects.reduce(CGFloat(0)) { sum, o in
            let i = o.intersection(r)
            return i.isNull ? sum : sum + PageMap.area(i)
        }
        return covered > 0.12 * PageMap.area(r)
    }

    // MARK: Page bounds

    static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    static func clamp(_ rect: CGRect, to r: CGRect) -> CGRect { PageMap.clamp(rect.standardized, to: r) }

    /// Slides `rect` onto `page` without resizing it (shrinking only if it's bigger than the page).
    static func fit(_ rect: CGRect, in page: CGRect) -> CGRect {
        let w = min(rect.width, page.width), h = min(rect.height, page.height)
        return CGRect(x: min(max(rect.minX, page.minX), page.maxX - w), y: min(max(rect.minY, page.minY), page.maxY - h),
                      width: w, height: h)
    }

    private static func center(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }

    // MARK: Colours

    static let colorNames: [String: String] = [
        "blue": InkSwatch.blueHex, "red": "#FF3B30", "green": "#248A3D", "orange": "#C93400", "purple": "#8944AB",
        "yellow": "#FFD60A", "teal": "#0071A4", "pink": "#D30F45", "gray": "#6E6E73", "grey": "#6E6E73",
        "black": "#1C1C1E", "brown": "#7F6545",
    ]

    /// `#RRGGBB` for a colour name or hex; the agent's blue when there's none.
    static func parseColor(_ s: String?) throws -> String {
        guard let s = s?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return InkSwatch.blueHex }
        if let hex = colorNames[s] { return hex }
        let digits = s.hasPrefix("#") ? String(s.dropFirst()) : s
        if digits.count == 6, digits.allSatisfy(\.isHexDigit) { return "#" + digits.uppercased() }
        throw ToolInputError("unknown colour `\(s)`; use a name (blue, red, green, orange, purple, yellow, teal, pink, gray, black) or #RRGGBB")
    }
}

// MARK: - Placement

enum PlacementSide: String, Codable, Hashable { case right, below, above, left }

enum Placement {
    static let gap: CGFloat = 12
    static let margin: CGFloat = 20
    /// How far from its anchor a note may go before the page is extended instead.
    static let farthest: CGFloat = 480

    /// How much room is left around what the agent puts down.
    struct Room {
        /// From the thing it's beside.
        var gap: CGFloat
        /// From everything else: listed boxes, and (less) drawn pixels.
        var pad: CGFloat
        var pixels: CGFloat
        /// From the page's edges, and a free space's.
        var edge: CGFloat
    }

    /// Breathing room, so marks don't crowd each other or the person's work. Tried first.
    static let roomy = Room(gap: 20, pad: 14, pixels: 8, edge: 28)
    /// Just clear, for a full page. Only when nothing fits with breathing room.
    static let tight = Room(gap: gap, pad: 4, pixels: 2, edge: margin)

    /// The clear rectangle of `size` closest to `anchor`, trying `side` first and then the others, with breathing room
    /// if anywhere has it, otherwise just clear. Nil if nothing fits. With an occupancy grid, a spot must also be
    /// clear of every drawn pixel, not just the listed boxes.
    static func find(size: CGSize, near anchor: CGRect, side: PlacementSide, page: CGRect, obstacles: [CGRect],
                     occupancy: OccupancyGrid? = nil) -> (rect: CGRect, side: PlacementSide)? {
        for room in [roomy, tight] {
            if let found = find(size: size, near: anchor, side: side, page: page, obstacles: obstacles,
                                occupancy: occupancy, room: room) { return found }
        }
        return nil
    }

    private static func find(size: CGSize, near anchor: CGRect, side: PlacementSide, page: CGRect, obstacles: [CGRect],
                             occupancy: OccupancyGrid?, room: Room) -> (rect: CGRect, side: PlacementSide)? {
        let order = [side] + [PlacementSide.right, .below, .above, .left].filter { $0 != side }
        let area = page.insetBy(dx: room.edge, dy: room.edge)
        let blockers = obstacles.map { $0.insetBy(dx: -room.pad, dy: -room.pad) }
        let gap = room.gap
        let a = anchor.standardized
        for s in order {
            var best: (rect: CGRect, distance: CGFloat)?
            for out in 0..<12 {
                let o = CGFloat(out) * 20
                for k in 0..<25 {
                    let lateral = CGFloat((k + 1) / 2) * 18 * (k % 2 == 0 ? 1 : -1)
                    let r: CGRect
                    switch s {
                    case .right: r = CGRect(x: a.maxX + gap + o, y: a.midY - size.height / 2 + lateral, width: size.width, height: size.height)
                    case .left: r = CGRect(x: a.minX - gap - o - size.width, y: a.midY - size.height / 2 + lateral, width: size.width, height: size.height)
                    case .below: r = CGRect(x: a.minX + lateral, y: a.maxY + gap + o, width: size.width, height: size.height)
                    case .above: r = CGRect(x: a.minX + lateral, y: a.minY - gap - o - size.height, width: size.width, height: size.height)
                    }
                    guard area.contains(r), !blockers.contains(where: { $0.intersects(r) }),
                          occupancy?.isFree(r.insetBy(dx: -room.pixels, dy: -room.pixels)) ?? true else { continue }
                    let d = hypot(r.midX - a.midX, r.midY - a.midY)
                    if best == nil || d < best!.distance { best = (r, d) }
                }
                if best != nil { break } // The nearest band outward that has room.
            }
            if let best { return (best.rect, s) }
        }
        return nil
    }

    /// Without a grid: the nearest spot (in 4 pt steps) clear of `avoiding`.
    static func nearestClear(_ r: CGRect, avoiding: [CGRect], in page: CGRect, maxDistance: CGFloat) -> CGRect? {
        var best: (rect: CGRect, distance: CGFloat)?
        for dy in stride(from: -maxDistance, through: maxDistance, by: 4) {
            for dx in stride(from: -maxDistance, through: maxDistance, by: 4) {
                let d = hypot(dx, dy)
                guard d <= maxDistance, best == nil || d < best!.distance else { continue }
                let candidate = r.offsetBy(dx: dx, dy: dy)
                guard page.contains(candidate), !avoiding.contains(where: { $0.intersects(candidate) }) else { continue }
                best = (candidate, d)
            }
        }
        return best?.rect
    }
}
