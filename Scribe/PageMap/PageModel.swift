import CoreGraphics
import Foundation

// The page as the agent sees it. Pure model (Foundation and CoreGraphics only), so it's easy to test.
//
// Every coordinate is in page points: origin top-left, x right, y down, 1100 wide (`NotePageMetrics.width`), the
// same space the person's ink, photos and the agent's marks live in.

/// A student stroke's identity: when it was drawn and where it starts. PencilKit strokes have no ID of their own, and
/// this survives saving, undo and redo.
typealias StrokeID = String

/// One page, mapped: a picture, plus everything on it with a stable ID and exact bounds.
struct PageMapSnapshot: Codable {
    var pageID: UUID
    /// Page points, including any space added to the page this turn.
    var pageSize: CGSize
    /// JPEG of the page (paper, photos, the person's ink, the agent's marks). Not saved in fixtures' JSON.
    var image: Data
    /// Image pixels per page point.
    var imageScale: CGFloat
    var objects: [PageObject]
    /// What the agent has already drawn on this page.
    var agentMarks: [AgentMarkSummary]
    /// How tall the person's handwriting is, in points. The agent sizes its writing from it.
    var studentInkHeight: CGFloat
    /// The part of the page on screen.
    var viewport: CGRect
    /// What's drawn where, cell by cell, read from the page picture itself (plus cards and reserved answer spaces).
    /// Placement checks it, so nothing the agent writes lands on anything, whatever the parsers missed.
    var occupancy: OccupancyGrid?
    /// Blank areas the agent can write in (`free_1…`), in reading order.
    var freeSpaces: [FreeSpace] = []

    private enum CodingKeys: String, CodingKey {
        case pageID, pageSize, image, imageScale, objects, agentMarks, studentInkHeight, viewport, occupancy, freeSpaces
    }

    init(pageID: UUID = UUID(), pageSize: CGSize, image: Data = Data(), imageScale: CGFloat = 1, objects: [PageObject] = [],
         agentMarks: [AgentMarkSummary] = [], studentInkHeight: CGFloat = PageMap.defaultInkHeight, viewport: CGRect? = nil,
         occupancy: OccupancyGrid? = nil, freeSpaces: [FreeSpace] = []) {
        self.pageID = pageID
        self.pageSize = pageSize
        self.image = image
        self.imageScale = imageScale
        self.objects = objects
        self.agentMarks = agentMarks
        self.studentInkHeight = studentInkHeight
        self.viewport = viewport ?? CGRect(origin: .zero, size: pageSize)
        self.occupancy = occupancy
        self.freeSpaces = freeSpaces
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pageID = try c.decode(UUID.self, forKey: .pageID)
        pageSize = try c.decode(CGSize.self, forKey: .pageSize)
        image = try c.decodeIfPresent(Data.self, forKey: .image) ?? Data()
        imageScale = try c.decode(CGFloat.self, forKey: .imageScale)
        objects = try c.decode([PageObject].self, forKey: .objects)
        agentMarks = try c.decodeIfPresent([AgentMarkSummary].self, forKey: .agentMarks) ?? []
        studentInkHeight = try c.decode(CGFloat.self, forKey: .studentInkHeight)
        viewport = try c.decode(CGRect.self, forKey: .viewport)
        occupancy = try c.decodeIfPresent(OccupancyGrid.self, forKey: .occupancy)
        freeSpaces = try c.decodeIfPresent([FreeSpace].self, forKey: .freeSpaces) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pageID, forKey: .pageID)
        try c.encode(pageSize, forKey: .pageSize)
        if !image.isEmpty { try c.encode(image, forKey: .image) } // Fixtures keep the image beside the JSON.
        try c.encode(imageScale, forKey: .imageScale)
        try c.encode(objects, forKey: .objects)
        try c.encode(agentMarks, forKey: .agentMarks)
        try c.encode(studentInkHeight, forKey: .studentInkHeight)
        try c.encode(viewport, forKey: .viewport)
        try c.encodeIfPresent(occupancy, forKey: .occupancy)
        try c.encode(freeSpaces, forKey: .freeSpaces)
    }

    var map: PageMap { PageMap(snapshot: self) }

    /// The image's size in pixels.
    var imagePixelSize: CGSize {
        CGSize(width: (pageSize.width * imageScale).rounded(), height: (pageSize.height * imageScale).rounded())
    }
}

struct PageObject: Codable, Identifiable, Hashable {
    /// `printed` is everything on the paper that isn't text: photos, figures and vector graphics (`vec_N`).
    enum Source: String, Codable, Hashable { case pdfText, printed, studentInk, agentInk, card }

    /// "txt_12", "txt_12.w3", "ink_7", "img_2", "vec_3", "vec_3.r1c2", "card_1": stable while the object exists.
    var id: String
    var source: Source
    /// "word", "line", "paragraph", "handwriting", "shape", "drawing", "figure", "photo", "blank", "rule",
    /// "underline", "box", "checkbox", "table", "cell", or an agent mark or card kind.
    var kind: String
    /// Printed text, recognised handwriting (best effort), a shape's name or a card's title.
    var text: String?
    /// Page points, origin top-left.
    var bounds: CGRect
    /// A closed shape's outline (boxes, cells), for tracing it.
    var outline: [CGPoint]?
    /// For student ink.
    var strokeIDs: [StrokeID]?
    /// A word belongs to a line, a line to a paragraph, a cell to a table.
    var parent: String?
    /// An open shape's exact lines, as polylines: a printed diagram's strokes, an answer line, the person's drawing.
    /// What the agent follows to trace something exactly. Not listed in the text block.
    var paths: [[CGPoint]]?
    /// How sure the reader is of `text` (handwriting recognition), 0…1. Nil when the text is exact.
    var confidence: Float?
    /// Relations worked out before the call (`PageRelations`): "new", "latest", "crossed out", "in vec_4",
    /// "answers txt_7", "work_1 step 2/3", "strikes ink_5".
    var tags: [String]?

    /// Who owns it: the paper, the person, or the agent.
    var owner: String {
        switch source {
        case .pdfText, .printed: "printed"
        case .studentInk: "student"
        case .agentInk, .card: "agent"
        }
    }

    init(id: String, source: Source, kind: String, text: String? = nil, bounds: CGRect, outline: [CGPoint]? = nil,
         strokeIDs: [StrokeID]? = nil, parent: String? = nil, paths: [[CGPoint]]? = nil, confidence: Float? = nil,
         tags: [String]? = nil) {
        self.id = id
        self.source = source
        self.kind = kind
        self.text = text
        self.bounds = bounds
        self.outline = outline
        self.strokeIDs = strokeIDs
        self.parent = parent
        self.paths = paths
        self.confidence = confidence
        self.tags = tags
    }
}

/// One mark on the agent's layer, as the next turn sees it.
struct AgentMarkSummary: Codable, Hashable {
    /// "am_1"
    var id: String
    /// circle, underline, highlight, check, cross, box, arrow, note, label, outline, drawing
    var kind: String
    var text: String?
    var bounds: CGRect
    /// The object the mark is around or on, when there is one ("am_1 circle around ink_5").
    var target: String?
}

// MARK: - Targets

/// Whatever the agent points at: an ID (optionally a word inside it), a raw box, or a raw point.
/// JSON: `{"id":"ink_7"}` · `{"id":"txt_3","match":"continents"}` · `{"box":[x,y,w,h]}` · `{"point":[x,y]}`.
enum PageTarget: Codable, Hashable {
    case id(String, match: String? = nil)
    case box(CGRect)
    case point(CGPoint)

    private enum Keys: String, CodingKey { case id, match, part, box, point }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let id = try c.decodeIfPresent(String.self, forKey: .id) {
            let match = try c.decodeIfPresent(String.self, forKey: .match) ?? c.decodeIfPresent(String.self, forKey: .part)
            self = .id(id, match: match)
        } else if let b = try c.decodeIfPresent([Double].self, forKey: .box), b.count == 4 {
            self = .box(CGRect(x: b[0], y: b[1], width: b[2], height: b[3]))
        } else if let p = try c.decodeIfPresent([Double].self, forKey: .point), p.count == 2 {
            self = .point(CGPoint(x: p[0], y: p[1]))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "A target needs `id`, `box` [x,y,w,h] or `point` [x,y]"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .id(let id, let match):
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(match, forKey: .match)
        case .box(let r): try c.encode([r.minX, r.minY, r.width, r.height].map(Double.init), forKey: .box)
        case .point(let p): try c.encode([Double(p.x), Double(p.y)], forKey: .point)
        }
    }
}

/// A target turned into exact geometry.
struct ResolvedTarget: Equatable {
    var bounds: CGRect
    /// The object's closed outline, when it has one (boxes, cells).
    var outline: [CGPoint]?
    /// The object it landed on, if any.
    var objectID: String?
    /// True when a raw box or point was moved onto an object.
    var snapped: Bool
    /// One line for the debug log.
    var note: String
    /// The object's open lines, for tracing (vector drawings, answer lines, the person's drawings).
    var paths: [[CGPoint]]? = nil
    /// The target is one of the free spaces: write inside it, not beside it.
    var isFreeSpace = false
}

// MARK: - The map

/// The objects of one snapshot, with lookups, snapping and the text block the agent reads.
struct PageMap {
    static let defaultInkHeight: CGFloat = 18
    /// About 150 objects are listed for the agent; the rest are summarised.
    static let objectBudget = 150
    /// A raw box snaps to an object it overlaps this much (intersection over union).
    static let snapOverlap: CGFloat = 0.6
    /// A raw box drawn loosely around an object snaps to it when the object fills at least this much of the box.
    static let snapFill: CGFloat = 0.4
    /// A raw point snaps to the object under it only when that object is smaller than this (a word, a mark, a
    /// shape), or has an outline. A point on a big figure or paragraph stays where it is.
    static let pointSnapMaxArea: CGFloat = 160 * 160

    let snapshot: PageMapSnapshot
    private let byID: [String: PageObject]
    private let freeByID: [String: FreeSpace]
    private let childrenByID: [String: [PageObject]]

    init(snapshot: PageMapSnapshot) {
        self.snapshot = snapshot
        byID = Dictionary(snapshot.objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        freeByID = Dictionary(snapshot.freeSpaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        childrenByID = Dictionary(grouping: snapshot.objects.filter { $0.parent != nil }, by: { $0.parent! })
    }

    var objects: [PageObject] { snapshot.objects }

    func object(_ id: String) -> PageObject? { byID[id] }
    func freeSpace(_ id: String) -> FreeSpace? { freeByID[id] }
    func children(of id: String) -> [PageObject] { childrenByID[id] ?? [] }

    // MARK: Snapping

    /// Turns whatever the agent sent into exact geometry. Nil only for an ID that doesn't exist.
    /// `pageSize` is the page as it is now: after `extend_page` this turn it's bigger than the snapshot's, and targets
    /// in the new space must not be pulled back to the old bottom edge.
    func resolve(target: PageTarget, pageSize: CGSize? = nil) -> ResolvedTarget? {
        let page = CGRect(origin: .zero, size: pageSize ?? snapshot.pageSize)
        switch target {
        case .id(let id, let match):
            if let f = freeSpace(id) {
                return ResolvedTarget(bounds: f.bounds, objectID: f.id, snapped: false,
                                      note: "\(id) (free space) \(Self.format(f.bounds))", isFreeSpace: true)
            }
            guard let o = object(id) else { return nil }
            if let match, !match.isEmpty {
                if let w = word(matching: match, in: o) {
                    return ResolvedTarget(bounds: w.bounds, objectID: w.id, snapped: true,
                                          note: "\(id) + “\(match)” → \(w.id) \(Self.format(w.bounds))")
                }
                return ResolvedTarget(bounds: o.bounds, outline: o.outline, objectID: o.id, snapped: false,
                                      note: "\(id): no word “\(match)”, using the whole object", paths: o.paths)
            }
            return ResolvedTarget(bounds: o.bounds, outline: o.outline, objectID: o.id, snapped: false,
                                  note: "\(id) \(Self.format(o.bounds))", paths: o.paths)

        case .box(let raw):
            let box = raw.standardized
            // Snap when the box is (nearly) the object, or drawn loosely around it. A box drawn *inside* a big object
            // (part of a figure, a spot in a paragraph) means that spot, so it stays raw.
            let snaps = objects.filter { o in
                guard o.bounds.width > 0 || o.bounds.height > 0 else { return false }
                if Self.iou(o.bounds, box) >= Self.snapOverlap { return true }
                return Self.contains(box, o.bounds) && Self.area(o.bounds) >= Self.snapFill * Self.area(box)
            }
            if let o = snaps.max(by: { Self.iou($0.bounds, box) < Self.iou($1.bounds, box) }) {
                return ResolvedTarget(bounds: o.bounds, outline: o.outline, objectID: o.id, snapped: true,
                                      note: "box \(Self.format(box)) → \(o.id)", paths: o.paths)
            }
            let clamped = Self.clamp(box, to: page)
            let inside = smallest(objects.filter { $0.kind != "word" && Self.contains($0.bounds, box) })
                .map { " inside \($0.id)" } ?? ""
            return ResolvedTarget(bounds: clamped, objectID: nil, snapped: false,
                                  note: "box \(Self.format(box)) → raw\(inside)" + (clamped == box ? "" : " (clamped to the page)"))

        case .point(let p):
            if let o = smallest(objects.filter { $0.bounds.insetBy(dx: -2, dy: -2).contains(p) && Self.hits(p, $0) }),
               Self.area(o.bounds) <= Self.pointSnapMaxArea || (o.outline?.count ?? 0) > 4 {
                return ResolvedTarget(bounds: o.bounds, outline: o.outline, objectID: o.id, snapped: true,
                                      note: "point \(Int(p.x)),\(Int(p.y)) → \(o.id)", paths: o.paths)
            }
            let q = CGPoint(x: min(max(p.x, 0), page.width), y: min(max(p.y, 0), page.height))
            return ResolvedTarget(bounds: CGRect(origin: q, size: .zero), objectID: nil, snapped: false,
                                  note: "point \(Int(p.x)),\(Int(p.y)) → no object, raw")
        }
    }

    /// The word (or run of words, for a phrase) of `object` that best matches `match`.
    func word(matching match: String, in object: PageObject) -> PageObject? {
        let needle = Self.normalise(match)
        guard !needle.isEmpty else { return nil }
        var words = children(of: object.id).filter { $0.kind == "word" }
        if words.isEmpty { // A paragraph: look in its lines.
            words = children(of: object.id).flatMap { children(of: $0.id) }.filter { $0.kind == "word" }
        }
        let parts = needle.split(separator: " ").map(String.init)
        if parts.count > 1, words.count >= parts.count {
            for i in 0...(words.count - parts.count) {
                let run = Array(words[i..<(i + parts.count)])
                if zip(run, parts).allSatisfy({ Self.normalise($0.0.text ?? "") == $0.1 }) {
                    let b = run.reduce(CGRect.null) { $0.union($1.bounds) }
                    return PageObject(id: run[0].id, source: object.source, kind: "word", text: match, bounds: b,
                                      parent: object.id)
                }
            }
        }
        let scored = words.map { w -> (PageObject, Int) in
            let t = Self.normalise(w.text ?? "")
            if t == needle { return (w, 3) }
            if t.hasPrefix(needle) || (needle.hasPrefix(t) && t.count >= 3) { return (w, 2) }
            if t.contains(needle) { return (w, 1) }
            return (w, 0)
        }.filter { $0.1 > 0 }
        // The first of the best, so "the" picks the first "the" on the line.
        guard let best = scored.map(\.1).max() else { return nil }
        return scored.first { $0.1 == best }?.0
    }

    private func smallest(_ list: [PageObject]) -> PageObject? {
        list.min { Self.area($0.bounds) < Self.area($1.bounds) }
    }

    /// For outlined objects the point has to be inside the outline, not just the bounding box.
    private static func hits(_ p: CGPoint, _ o: PageObject) -> Bool {
        guard let outline = o.outline, outline.count > 2 else { return true }
        return polygonContains(outline, p)
    }

    static func polygonContains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    static func clamp(_ r: CGRect, to page: CGRect) -> CGRect {
        let i = r.intersection(page)
        if !i.isNull { return i }
        let x = min(max(r.minX, page.minX), page.maxX), y = min(max(r.minY, page.minY), page.maxY)
        return CGRect(x: x, y: y, width: 0, height: 0)
    }

    static func contains(_ outer: CGRect, _ inner: CGRect) -> Bool { outer.insetBy(dx: -1, dy: -1).contains(inner) }
    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : max(r.width, 0.5) * max(r.height, 0.5) }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = area(i)
        return inter / max(area(a) + area(b) - inter, 0.0001)
    }

    /// Distance between two rectangles (0 when they touch or overlap).
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
        let dy = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
        return hypot(dx, dy)
    }

    static func normalise(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
    }

    static func format(_ r: CGRect) -> String {
        "\(Int(r.minX.rounded())),\(Int(r.minY.rounded())),\(Int(r.width.rounded())),\(Int(r.height.rounded()))"
    }
}
