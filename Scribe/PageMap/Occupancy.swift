import CoreGraphics
import Foundation

// Pure model: Foundation and CoreGraphics only.
//
// The ground truth for "is anything there?" is the page picture itself: every non-white pixel of the rendered page
// (the PDF, photos, the person's ink, the agent's own marks) takes its cell. Whatever the PDF readers miss (shading,
// inline images, text drawn as outlines, a scanned worksheet), the pixels still catch. Answer spaces the person
// hasn't filled in yet (blank lines, empty boxes and cells) are reserved on top of that, and cards are marked from
// their frames. Placement checks this grid, and the free spaces the agent is offered are read from it.

/// A coarse bitmap of the page: one bit per `cell`×`cell` points, set where something is drawn or reserved.
struct OccupancyGrid: Equatable {
    static let defaultCell: CGFloat = 4

    let columns: Int
    let rows: Int
    let cell: CGFloat
    private(set) var bits: [UInt8]
    /// Summed-area table, (columns + 1)×(rows + 1): any rectangle's count in O(1).
    private var integral: [Int32] = []

    init(size: CGSize, cell: CGFloat = OccupancyGrid.defaultCell) {
        self.cell = cell
        columns = max(1, Int((size.width / cell).rounded(.up)))
        rows = max(1, Int((size.height / cell).rounded(.up)))
        bits = [UInt8](repeating: 0, count: columns * rows)
        rebuild()
    }

    /// Every pixel darker than `threshold` (0–255 luminance) takes its cell. `image` covers `pageSize` exactly.
    static func from(image: CGImage, pageSize: CGSize, cell: CGFloat = defaultCell, threshold: UInt8 = 232) -> OccupancyGrid {
        var grid = OccupancyGrid(size: pageSize, cell: cell)
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return grid }
        var px = [UInt8](repeating: 255, count: w * h)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return grid }
        // Row 0 of the buffer is the top of the picture.
        let columnOf = (0..<w).map { min(grid.columns - 1, Int(CGFloat($0) * pageSize.width / CGFloat(w) / cell)) }
        px.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let row = min(grid.rows - 1, Int(CGFloat(y) * pageSize.height / CGFloat(h) / cell))
                let base = y * w, rowBase = row * grid.columns
                for x in 0..<w where p[base + x] < threshold { grid.bits[rowBase + columnOf[x]] = 1 }
            }
        }
        grid.rebuild()
        return grid
    }

    // MARK: Marking

    /// A copy with these rectangles taken too.
    func marking(_ rects: [CGRect]) -> OccupancyGrid {
        var g = self
        for r in rects {
            guard let (c0, r0, c1, r1) = g.cells(r) else { continue }
            for y in r0...r1 { for x in c0...c1 { g.bits[y * columns + x] = 1 } }
        }
        g.rebuild()
        return g
    }

    /// A copy where every taken cell also takes its neighbours: a margin of one cell around everything.
    func dilated() -> OccupancyGrid {
        var g = self
        for y in 0..<rows {
            for x in 0..<columns where bits[y * columns + x] == 1 {
                for ny in max(0, y - 1)...min(rows - 1, y + 1) {
                    for nx in max(0, x - 1)...min(columns - 1, x + 1) { g.bits[ny * columns + nx] = 1 }
                }
            }
        }
        g.rebuild()
        return g
    }

    // MARK: Queries

    /// Taken cells under `rect`. Space past the grid (the page grew this turn) is free.
    func occupiedCells(in rect: CGRect) -> Int {
        guard let (c0, r0, c1, r1) = cells(rect) else { return 0 }
        let w = columns + 1
        let a = integral[r0 * w + c0], b = integral[r0 * w + c1 + 1]
        let c = integral[(r1 + 1) * w + c0], d = integral[(r1 + 1) * w + c1 + 1]
        return Int(d - b - c + a)
    }

    func isFree(_ rect: CGRect) -> Bool { occupiedCells(in: rect) == 0 }

    /// The share of `rect` that's taken, 0…1.
    func coverage(_ rect: CGRect) -> CGFloat {
        guard let (c0, r0, c1, r1) = cells(rect) else { return 0 }
        return CGFloat(occupiedCells(in: rect)) / CGFloat((c1 - c0 + 1) * (r1 - r0 + 1))
    }

    /// The free rectangle of `size` closest to `anchor` inside `area`, clear of `avoiding`, at most `maxDistance` away.
    func nearestFree(size: CGSize, near anchor: CGRect, in area: CGRect, avoiding: [CGRect] = [],
                     maxDistance: CGFloat = .greatestFiniteMagnitude) -> CGRect? {
        guard size.width <= area.width, size.height <= area.height else { return nil }
        let a = anchor.standardized
        let reach = min(maxDistance, max(area.width, area.height))
        let x0 = max(area.minX, a.minX - reach - size.width), x1 = min(area.maxX - size.width, a.maxX + reach)
        let y0 = max(area.minY, a.minY - reach - size.height), y1 = min(area.maxY - size.height, a.maxY + reach)
        guard x0 <= x1, y0 <= y1 else { return nil }
        var best: (rect: CGRect, score: CGFloat)?
        for y in stride(from: y0, through: y1, by: cell) {
            for x in stride(from: x0, through: x1, by: cell) {
                let r = CGRect(x: x, y: y, width: size.width, height: size.height)
                let d = Self.gap(r, a)
                guard d <= maxDistance else { continue }
                // Ties go to the spot whose centre is closest, so they don't drift to a corner.
                let score = d + 0.01 * hypot(r.midX - a.midX, r.midY - a.midY)
                guard best == nil || score < best!.score else { continue }
                guard isFree(r), !avoiding.contains(where: { $0.intersects(r) }) else { continue }
                best = (r, score)
            }
        }
        return best?.rect
    }

    /// Up to `count` large free rectangles inside `area`, each at least `minSize`, biggest first; none overlap.
    func freeRects(minSize: CGSize, max count: Int, in area: CGRect) -> [CGRect] {
        let width = CGFloat(columns) * cell, height = CGFloat(rows) * cell
        // Outside `area` counts as taken.
        let outside = [CGRect(x: -1, y: -1, width: width + 2, height: area.minY + 1),
                       CGRect(x: -1, y: area.maxY, width: width + 2, height: max(0, height - area.maxY) + 1),
                       CGRect(x: -1, y: -1, width: area.minX + 1, height: height + 2),
                       CGRect(x: area.maxX, y: -1, width: max(0, width - area.maxX) + 1, height: height + 2)]
        var taken = marking(outside.filter { $0.width > 0 && $0.height > 0 })
        let minW = Int((minSize.width / cell).rounded(.up)), minH = Int((minSize.height / cell).rounded(.up))
        var out: [CGRect] = []
        while out.count < count, let r = taken.largestFree(minW: minW, minH: minH) {
            out.append(r)
            taken = taken.marking([r.insetBy(dx: -cell, dy: -cell)])
        }
        return out
    }

    /// The largest all-free rectangle at least minW×minH cells (maximal rectangles, histogram method).
    private func largestFree(minW: Int, minH: Int) -> CGRect? {
        var heights = [Int](repeating: 0, count: columns)
        var best: (x: Int, y: Int, w: Int, h: Int, area: Int)?
        var stack: [Int] = []
        for y in 0..<rows {
            for x in 0..<columns { heights[x] = bits[y * columns + x] == 0 ? heights[x] + 1 : 0 }
            stack.removeAll(keepingCapacity: true)
            for x in 0...columns {
                let h = x == columns ? 0 : heights[x]
                while let top = stack.last, heights[top] > h {
                    stack.removeLast()
                    let height = heights[top]
                    let left = (stack.last ?? -1) + 1
                    let width = x - left
                    if width >= minW, height >= minH, width * height > (best?.area ?? 0) {
                        best = (left, y - height + 1, width, height, width * height)
                    }
                }
                stack.append(x)
            }
        }
        guard let b = best else { return nil }
        return CGRect(x: CGFloat(b.x) * cell, y: CGFloat(b.y) * cell, width: CGFloat(b.w) * cell, height: CGFloat(b.h) * cell)
    }

    // MARK: Internals

    /// The cell range under `rect`, clipped to the grid; nil when it misses the grid.
    private func cells(_ rect: CGRect) -> (Int, Int, Int, Int)? {
        let r = rect.standardized
        guard !r.isNull, r.maxX > 0, r.maxY > 0 else { return nil }
        let c0 = Swift.max(0, Int((r.minX / cell).rounded(.down)))
        let r0 = Swift.max(0, Int((r.minY / cell).rounded(.down)))
        let c1 = Swift.min(columns - 1, Int((r.maxX / cell).rounded(.up)) - 1)
        let r1 = Swift.min(rows - 1, Int((r.maxY / cell).rounded(.up)) - 1)
        guard c0 <= c1, r0 <= r1 else { return nil }
        return (c0, r0, c1, r1)
    }

    private mutating func rebuild() {
        let w = columns + 1
        var t = [Int32](repeating: 0, count: w * (rows + 1))
        for y in 0..<rows {
            var run: Int32 = 0
            for x in 0..<columns {
                run += Int32(bits[y * columns + x])
                t[(y + 1) * w + x + 1] = t[y * w + x + 1] + run
            }
        }
        integral = t
    }

    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat { PageMap.gap(a, b) }

    static func == (a: OccupancyGrid, b: OccupancyGrid) -> Bool {
        a.columns == b.columns && a.rows == b.rows && a.cell == b.cell && a.bits == b.bits
    }
}

extension OccupancyGrid: Codable {
    private enum Keys: String, CodingKey { case columns, rows, cell, bits }

    /// Bits packed eight to a byte (a page is a few KB).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        columns = try c.decode(Int.self, forKey: .columns)
        rows = try c.decode(Int.self, forKey: .rows)
        cell = try c.decode(CGFloat.self, forKey: .cell)
        let packed = [UInt8](try c.decode(Data.self, forKey: .bits))
        bits = (0..<(columns * rows)).map { i in
            let byte = i / 8 < packed.count ? packed[i / 8] : 0
            return (byte >> UInt8(i % 8)) & 1
        }
        rebuild()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(columns, forKey: .columns)
        try c.encode(rows, forKey: .rows)
        try c.encode(cell, forKey: .cell)
        var packed = [UInt8](repeating: 0, count: (bits.count + 7) / 8)
        for (i, b) in bits.enumerated() where b != 0 { packed[i / 8] |= 1 << UInt8(i % 8) }
        try c.encode(Data(packed), forKey: .bits)
    }
}

// MARK: - Free space

/// A blank area the agent can write or draw in, offered as `free_N`.
struct FreeSpace: Codable, Hashable {
    var id: String
    var bounds: CGRect
    /// "right of txt_4", "below ink_2": the nearest thing, so the agent can tell which space belongs to which question.
    var near: String?
    /// At least half of it is on screen.
    var visible: Bool
}

enum PageLayout {
    /// The smallest space worth offering: a short note.
    static let minFreeSize = CGSize(width: 72, height: 26)
    static let maxFreeSpaces = 10
    static let margin: CGFloat = 14
    /// Empty boxes and cells up to this size are kept for the person's answers.
    static let answerBoxMax = CGSize(width: 320, height: 220)

    /// Printed kinds that sit inside something bigger, so they're never obstacles of their own.
    static let nestedKinds: Set<String> = ["cell", "underline", "part", "area"]

    /// The occupancy grid and the free spaces for one snapshot.
    /// - image: the flattened page picture (paper, photos, the person's ink, the agent's marks), covering `pageSize`.
    /// - objects: the snapshot's objects (cards are marked from their frames; answer spaces are reserved).
    static func build(image: CGImage?, pageSize: CGSize, objects: [PageObject], inkHeight: CGFloat,
                      viewport: CGRect) -> (grid: OccupancyGrid, free: [FreeSpace]) {
        var grid = image.map { OccupancyGrid.from(image: $0, pageSize: pageSize) } ?? OccupancyGrid(size: pageSize)
        let reserved = answerSpaces(objects, inkHeight: inkHeight)
        // The same boxes placement keeps clear of, so a free space offered is one placement accepts.
        grid = grid.marking(obstacleBoxes(objects) + reserved.map(\.bounds))
        let padded = grid.dilated()
        let area = CGRect(origin: .zero, size: pageSize).insetBy(dx: margin, dy: margin)
        let rects = padded.freeRects(minSize: minFreeSize, max: maxFreeSpaces, in: area)
            .sorted { abs($0.minY - $1.minY) > 8 ? $0.minY < $1.minY : $0.minX < $1.minX }
        let landmarks = objects.filter { o in
            o.kind != "word" && o.kind != "cell" && o.source != .card && o.bounds.width > 0
        }
        let free = rects.enumerated().map { i, r -> FreeSpace in
            let v = r.intersection(viewport)
            return FreeSpace(id: "free_\(i + 1)", bounds: r, near: describeNear(r, landmarks),
                             visible: !v.isNull && PageMap.area(v) >= 0.5 * PageMap.area(r))
        }
        return (grid, free)
    }

    /// Everything placement keeps clear of, as boxes: printed lines (not single words), printed graphics, photos,
    /// the person's ink, the agent's marks and cards.
    static func obstacleBoxes(_ objects: [PageObject]) -> [CGRect] {
        objects.filter { o in
            switch o.source {
            case .card, .studentInk, .agentInk: o.parent == nil
            case .pdfText: o.kind == "line"
            case .printed: !nestedKinds.contains(o.kind)
            }
        }.map(\.bounds)
    }

    /// Where the person will write: the band above a blank line, empty answer boxes and empty table cells.
    /// Something already written there (ink inside it) means it's taken anyway; the pixels show that.
    static func answerSpaces(_ objects: [PageObject], inkHeight: CGFloat) -> [PageObject] {
        let filled = objects.filter { $0.source == .studentInk || $0.source == .pdfText }
        func empty(_ r: CGRect) -> Bool {
            !filled.contains { r.insetBy(dx: 1, dy: 1).contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }
        }
        var out: [PageObject] = []
        for o in objects where o.source == .printed {
            switch o.kind {
            case "blank":
                let h = max(22, 1.6 * inkHeight)
                out.append(PageObject(id: o.id, source: .printed, kind: "answer space",
                                      bounds: CGRect(x: o.bounds.minX, y: o.bounds.minY - h, width: o.bounds.width,
                                                     height: h + o.bounds.height)))
            case "box", "checkbox", "cell":
                guard o.bounds.width <= answerBoxMax.width, o.bounds.height <= answerBoxMax.height, empty(o.bounds) else { continue }
                out.append(PageObject(id: o.id, source: .printed, kind: "answer space", bounds: o.bounds))
            default:
                continue
            }
        }
        return out
    }

    static func describeNear(_ r: CGRect, _ landmarks: [PageObject]) -> String? {
        guard let o = landmarks.min(by: { PageMap.gap($0.bounds, r) < PageMap.gap($1.bounds, r) }),
              PageMap.gap(o.bounds, r) < 120 else { return nil }
        let b = o.bounds
        let side: String
        if r.minX >= b.maxX - 4 { side = "right of" }
        else if r.maxX <= b.minX + 4 { side = "left of" }
        else if r.minY >= b.maxY - 4 { side = "below" }
        else if r.maxY <= b.minY + 4 { side = "above" }
        else { side = "beside" }
        return "\(side) \(o.id)"
    }
}
