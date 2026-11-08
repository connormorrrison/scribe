import Foundation
import PencilKit
import UIKit
import Vision

// The person's ink, as the page map sees it: strokes grouped into objects (a word, a line of working, a shape, a
// drawing), each with a stable `ink_N` ID, a kind, and what it says when it's writing.

/// One of the person's strokes, as the grouper sees it.
struct MapStroke: Equatable {
    var id: StrokeID
    /// When the pen went down and came up (seconds since the reference date).
    var start: TimeInterval
    var end: TimeInterval
    var bounds: CGRect
    /// Points along the stroke, in page points.
    var points: [CGPoint]
}

extension PKStroke {
    /// The stroke's identity for the page map: when it was drawn, and where it starts (strokes split by the eraser
    /// share a time but not a start).
    var mapID: StrokeID {
        let first = path.first.map { $0.location.applying(transform) } ?? .zero
        return String(format: "%.3f:%.1f,%.1f", path.creationDate.timeIntervalSinceReferenceDate, first.x, first.y)
    }

    var mapStroke: MapStroke {
        let start = path.creationDate.timeIntervalSinceReferenceDate
        let points = path.map { $0.location.applying(transform) }
        return MapStroke(id: mapID, start: start, end: start + (path.last?.timeOffset ?? 0), bounds: renderBounds,
                         points: points)
    }
}

/// Groups strokes into objects.
enum InkGrouping {
    /// Strokes join a group when drawn within this many seconds of it…
    static let joinWindow: TimeInterval = 1.2
    /// …and their bounds are within this many ink heights of it.
    static let joinDistance: CGFloat = 0.6
    /// A pause longer than this always starts a new group.
    static let newGroupPause: TimeInterval = 2.5

    /// Groups in drawing order. Between `joinWindow` and `newGroupPause`, a stroke still joins a group it touches
    /// (dotting an i, crossing a t).
    static func group(_ strokes: [MapStroke], inkHeight h: CGFloat) -> [[MapStroke]] {
        var groups: [[MapStroke]] = []
        var boxes: [CGRect] = []
        var ends: [TimeInterval] = []
        for s in strokes.sorted(by: { $0.start < $1.start }) {
            var best: (index: Int, distance: CGFloat)?
            for i in groups.indices {
                let pause = s.start - ends[i]
                guard pause <= newGroupPause else { continue }
                let d = PageMap.gap(boxes[i], s.bounds)
                let limit = pause <= joinWindow ? joinDistance * h : 0.5
                guard d <= limit else { continue }
                if best == nil || d < best!.distance { best = (i, d) }
            }
            if let b = best {
                groups[b.index].append(s)
                boxes[b.index] = boxes[b.index].union(s.bounds)
                ends[b.index] = max(ends[b.index], s.end)
            } else {
                groups.append([s])
                boxes.append(s.bounds)
                ends.append(s.end)
            }
        }
        return groups
    }

    /// Groups strokes and measures the handwriting height together. Strokes are often pieces of letters, so a first
    /// pass groups with a height estimated from strokes; the median height of the writing-sized groups it finds is
    /// the handwriting height, and the second pass groups with that.
    static func groupAndMeasure(_ strokes: [MapStroke]) -> (groups: [[MapStroke]], inkHeight: CGFloat) {
        let h0 = inkHeight(strokes)
        let first = group(strokes, inkHeight: h0)
        let heights = first.filter { $0.count >= 2 }
            .map { $0.reduce(CGRect.null) { $0.union($1.bounds) }.height }
            .filter { $0 >= h0 * 0.8 && $0 <= h0 * 4 }
            .sorted()
        guard !heights.isEmpty else { return (first, h0) }
        let h1 = min(60, max(h0, heights[heights.count / 2]))
        return (h1 == h0 ? first : group(strokes, inkHeight: h1), h1)
    }

    /// How tall the written letters are: the 80th percentile of small strokes' heights (tall letters and digits).
    static func inkHeight(_ strokes: [MapStroke]) -> CGFloat {
        let heights = strokes.map(\.bounds.height).filter { $0 >= 3 && $0 <= 70 }.sorted()
        guard heights.count >= 3 else { return PageMap.defaultInkHeight }
        return min(60, max(8, heights[min(heights.count - 1, Int(Double(heights.count) * 0.8))]))
    }
}

// MARK: - Shapes

/// Simple tests for hand-drawn shapes: line, arrow, circle or ellipse, triangle, rectangle.
enum ShapeClassifier {
    /// The shape's name, or nil when it isn't a simple shape. Shapes smaller than about 1.5 ink heights are letters.
    static func classify(_ strokes: [MapStroke], inkHeight h: CGFloat) -> String? {
        let box = strokes.reduce(CGRect.null) { $0.union($1.bounds) }
        guard max(box.width, box.height) >= 1.5 * h else { return nil }

        if strokes.count == 1 {
            let pts = resample(strokes[0].points, spacing: max(2, max(box.width, box.height) / 60))
            guard pts.count >= 4, let first = pts.first, let last = pts.last else { return nil }
            let length = Simplify.length(pts)
            let chord = hypot(last.x - first.x, last.y - first.y)
            if chord / max(length, 1) > 0.93 { return "line" }
            let closed = chord < 0.2 * length || chord < 0.35 * min(box.width, box.height)
            guard closed else { return nil }
            // Corners are counted with the shape scaled to a square, so a long ellipse's tips don't count.
            let square = pts.map {
                CGPoint(x: ($0.x - box.minX) / max(box.width, 1) * 100, y: ($0.y - box.minY) / max(box.height, 1) * 100)
            }
            let corners = cornerCount(square)
            if corners <= 1 && radiusSpread(pts) < 0.3 {
                return abs(box.width - box.height) < 0.2 * max(box.width, box.height) ? "circle" : "ellipse"
            }
            if corners == 3 { return "triangle" }
            if corners == 4 { return abs(box.width - box.height) < 0.15 * max(box.width, box.height) ? "square" : "rectangle" }
            return nil
        }

        // An arrow: one long, fairly straight shaft plus one or two short strokes at one end of it.
        if strokes.count <= 3 {
            let byLength = strokes.sorted { Simplify.length($0.points) > Simplify.length($1.points) }
            let shaft = byLength[0].points
            let shaftLength = Simplify.length(shaft)
            guard let a = shaft.first, let b = shaft.last, shaftLength > 2 * h else { return nil }
            let straight = hypot(b.x - a.x, b.y - a.y) / max(shaftLength, 1) > 0.85
            let heads = byLength.dropFirst()
            let headsShort = heads.allSatisfy { Simplify.length($0.points) < 0.5 * shaftLength }
            let headsAtEnd = heads.allSatisfy { s in
                let near = 0.3 * shaftLength + 6
                return [a, b].contains { e in s.points.contains { hypot($0.x - e.x, $0.y - e.y) < near } }
            }
            if straight && headsShort && headsAtEnd { return "arrow" }
        }
        return nil
    }

    /// Sharp turns along the stroke (more than ~55° within a short window), merging neighbours. The closing corner
    /// counts once.
    static func cornerCount(_ pts: [CGPoint]) -> Int {
        let n = pts.count
        guard n >= 8 else { return 0 }
        let k = max(2, n / 16)
        var sharp: [Int] = []
        for i in k..<(n - k) {
            let a = pts[i - k], p = pts[i], b = pts[i + k]
            let v1 = CGVector(dx: p.x - a.x, dy: p.y - a.y), v2 = CGVector(dx: b.x - p.x, dy: b.y - p.y)
            let l1 = hypot(v1.dx, v1.dy), l2 = hypot(v2.dx, v2.dy)
            guard l1 > 0, l2 > 0 else { continue }
            if (v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2) < 0.57 { sharp.append(i) }
        }
        var corners: [Int] = []
        for i in sharp where corners.last.map({ i - $0 > k }) ?? true { corners.append(i) }
        // The corner where the stroke starts and ends shows up at neither end of the window: add it when the start
        // and end directions differ sharply.
        let d1 = CGVector(dx: pts[k].x - pts[0].x, dy: pts[k].y - pts[0].y)
        let d2 = CGVector(dx: pts[n - 1].x - pts[n - 1 - k].x, dy: pts[n - 1].y - pts[n - 1 - k].y)
        let l1 = hypot(d1.dx, d1.dy), l2 = hypot(d2.dx, d2.dy)
        if l1 > 0, l2 > 0, (d1.dx * d2.dx + d1.dy * d2.dy) / (l1 * l2) < 0.57 { corners.append(0) }
        return corners.count
    }

    /// How much the distance from the centre varies, relative to its mean (0 for a perfect circle). Measured after
    /// scaling the box to a square, so ellipses pass too.
    static func radiusSpread(_ pts: [CGPoint]) -> CGFloat {
        let box = pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        guard box.width > 0, box.height > 0 else { return 1 }
        let r = pts.map { hypot(($0.x - box.midX) / box.width, ($0.y - box.midY) / box.height) }
        let mean = r.reduce(0, +) / CGFloat(r.count)
        guard mean > 0 else { return 1 }
        let variance = r.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / CGFloat(r.count)
        return sqrt(variance) / mean
    }

    static func resample(_ pts: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard pts.count > 1 else { return pts }
        var out = [pts[0]]
        var carry: CGFloat = 0
        for (a, b) in zip(pts, pts.dropFirst()) {
            let d = hypot(b.x - a.x, b.y - a.y)
            guard d > 0 else { continue }
            var t = spacing - carry
            while t <= d {
                out.append(CGPoint(x: a.x + (b.x - a.x) * t / d, y: a.y + (b.y - a.y) * t / d))
                t += spacing
            }
            carry = d - (t - spacing)
        }
        if let last = pts.last, out.last != last { out.append(last) }
        return out
    }
}

// MARK: - Stable IDs

/// Gives each ink object an `ink_N` ID that it keeps while more than half of its strokes survive. Each ID remembers
/// its last few versions, so undo (back to an earlier version) and redo keep the ID too.
struct InkIDRegistry: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var id: String
        /// Most recent last.
        var versions: [Set<StrokeID>]
        var active: Bool
    }

    private(set) var entries: [Entry] = []
    private(set) var next = 1
    static let memory = 400
    static let versionsKept = 8

    /// One ID per group, in the groups' order.
    mutating func assign(_ groups: [Set<StrokeID>]) -> [String] {
        // An entry keeps its ID for a group holding more than half the strokes of one of its versions. Better
        // matches win: more shared strokes, then the most recent version, then an object still on the page.
        struct Pair { var group: Int; var entry: Int; var shared: Int; var recency: Int }
        var pairs: [Pair] = []
        for (g, strokes) in groups.enumerated() {
            for (e, entry) in entries.enumerated() {
                var best: Pair?
                for (v, version) in entry.versions.enumerated().reversed() where !version.isEmpty {
                    let shared = version.intersection(strokes).count
                    guard Double(shared) > 0.5 * Double(version.count) else { continue }
                    if best == nil || shared > best!.shared { best = Pair(group: g, entry: e, shared: shared, recency: v) }
                }
                if let best { pairs.append(best) }
            }
        }
        pairs.sort { a, b in
            if a.shared != b.shared { return a.shared > b.shared }
            if a.recency != b.recency { return a.recency > b.recency }
            return entries[a.entry].active && !entries[b.entry].active
        }
        var ids = [String?](repeating: nil, count: groups.count)
        var usedEntries = Set<Int>()
        for p in pairs where ids[p.group] == nil && !usedEntries.contains(p.entry) {
            ids[p.group] = entries[p.entry].id
            usedEntries.insert(p.entry)
        }
        for i in entries.indices { entries[i].active = false }
        var out: [String] = []
        for (g, strokes) in groups.enumerated() {
            let id: String
            if let existing = ids[g] {
                id = existing
            } else {
                id = "ink_\(next)"
                next += 1
            }
            if let e = entries.firstIndex(where: { $0.id == id }) {
                if entries[e].versions.last != strokes {
                    entries[e].versions.removeAll { $0 == strokes }
                    entries[e].versions.append(strokes)
                    if entries[e].versions.count > Self.versionsKept { entries[e].versions.removeFirst() }
                }
                entries[e].active = true
            } else {
                entries.append(Entry(id: id, versions: [strokes], active: true))
            }
            out.append(id)
        }
        // Forget the oldest retired entries.
        let retired = entries.filter { !$0.active }
        if retired.count > Self.memory {
            let drop = Set(retired.prefix(retired.count - Self.memory).map(\.id))
            entries.removeAll { drop.contains($0.id) }
        }
        return out
    }
}

// MARK: - Reading handwriting

/// Reads a group of strokes with Vision, drawn black on white. Best effort.
enum HandwritingReader {
    struct Reading: Equatable {
        var text: String
        var confidence: Float
    }

    /// Readings less sure than this are treated as "not handwriting".
    static let minimumConfidence: Float = 0.3
    /// The ink is drawn about this tall in pixels.
    static let targetHeight: CGFloat = 96
    /// The longest side of the picture handed to Vision: a long line of writing would otherwise be a huge bitmap.
    static let maxSide: CGFloat = 1600

    /// Safe off the main thread (rendering ink can take a while).
    nonisolated static func image(of strokes: [PKStroke]) -> CGImage? {
        let box = strokes.reduce(CGRect.null) { $0.union($1.renderBounds) }
        guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
        let crop = box.insetBy(dx: -box.height * 0.3 - 4, dy: -box.height * 0.3 - 4)
        let scale = min(6, max(1, targetHeight / box.height), maxSide / crop.width, maxSide / crop.height)
        let black = strokes.map { stroke -> PKStroke in
            var stroke = stroke
            stroke.ink = PKInk(.pen, color: .black)
            return stroke
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: ceil(crop.width * scale), height: ceil(crop.height * scale))
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = PKDrawing(strokes: black).image(from: crop, scale: scale)
            image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
                ink.draw(in: CGRect(origin: .zero, size: size))
            }
        }
        return image?.cgImage
    }

    /// Lines top to bottom, joined with spaces; the confidence is the least sure line's. Nil when Vision finds nothing.
    nonisolated static func read(_ image: CGImage) -> Reading? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false // Maths and labels aren't dictionary words.
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        struct Line { var box: CGRect; var text: String; var confidence: Float }
        var lines: [Line] = []
        for observation in request.results ?? [] {
            guard let top = observation.topCandidates(1).first,
                  !top.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            lines.append(Line(box: observation.boundingBox, text: top.string, confidence: top.confidence))
        }
        // Vision's boxes are bottom-up.
        lines.sort { a, b in abs(a.box.midY - b.box.midY) > 0.02 ? a.box.midY > b.box.midY : a.box.minX < b.box.minX }
        guard !lines.isEmpty else { return nil }
        return Reading(text: lines.map(\.text).joined(separator: " "), confidence: lines.map(\.confidence).min() ?? 0)
    }
}
