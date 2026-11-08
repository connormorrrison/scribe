import CoreGraphics
import Foundation

/// Splits a figure (a map, a diagram, a photo of a worksheet's picture) into the shapes it's made of, from its pixels,
/// so the agent can point at one and the app can trace it exactly: each continent of a world map, each country of a
/// coloured map, each labelled part of a diagram.
///
/// Two levels:
/// - parts (`img_1.p3`): the separate shapes standing out from the figure's background. Thin necks (an isthmus, a
///   line joining two shapes) are cut, so Africa comes apart from Asia and North from South America.
/// - areas (`img_1.p3.a2`): the differently coloured patches inside a part (countries of one continent, continents
///   of a coloured landmass), listed only when a part has more than one.
///
/// Every outline is traced from the pixels at up to 2 px per point (at least about 1 for a page-wide figure), so it's
/// accurate to within a point: finer than the agent's 3 pt pen.
enum FigureRegions {
    struct Region: Equatable {
        /// A closed ring in page points.
        var outline: [CGPoint]
        var bounds: CGRect
        /// In square points.
        var area: CGFloat
        /// The region's colour, named ("green", "light blue").
        var color: String
        var areas: [Region] = []
    }

    /// Figures smaller than this aren't split.
    static let minFigureSide: CGFloat = 60
    /// Pixels per page point the figure is read at (fewer for big figures, to keep under `maxPixels`).
    static let maxScale: CGFloat = 2
    static let maxPixels = 700_000
    static let maxParts = 40
    static let maxAreas = 12
    /// Colours this close (0–255 RGB distance) are the same colour.
    static let tolerance: Int = 44

    /// Splits the part of `image` under `figure`. `scale` is the image's pixels per page point; the image's origin is
    /// the page's.
    static func regions(in image: CGImage, scale: CGFloat, figure: CGRect) -> [Region] {
        guard figure.width >= minFigureSide, figure.height >= minFigureSide else { return [] }
        let px = CGRect(x: figure.minX * scale, y: figure.minY * scale, width: figure.width * scale, height: figure.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard px.width >= 8, px.height >= 8, let crop = image.cropping(to: px) else { return [] }
        // Read it at no more than `maxScale` and `maxPixels`.
        var s = scale
        var w = crop.width, h = crop.height
        let shrink = min(1, maxScale / scale, sqrt(CGFloat(maxPixels) / CGFloat(w * h)))
        if shrink < 1 {
            w = max(8, Int(CGFloat(w) * shrink))
            h = max(8, Int(CGFloat(h) * shrink))
            s = scale * CGFloat(w) / CGFloat(crop.width)
        }
        guard let pixels = Pixels(crop, width: w, height: h) else { return [] }
        let origin = CGPoint(x: px.minX / scale, y: px.minY / scale)
        return split(pixels, scale: s, origin: origin)
    }

    // MARK: Pixels

    struct Pixels {
        let width: Int, height: Int
        /// RGB, 3 bytes a pixel, on white.
        var rgb: [UInt8]

        init?(_ image: CGImage, width: Int, height: Int) {
            self.width = width
            self.height = height
            var rgba = [UInt8](repeating: 255, count: width * height * 4)
            let ok = rgba.withUnsafeMutableBytes { buffer -> Bool in
                guard let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.interpolationQuality = .high
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard ok else { return nil }
            rgb = [UInt8](repeating: 0, count: width * height * 3)
            for i in 0..<(width * height) {
                rgb[i * 3] = rgba[i * 4]
                rgb[i * 3 + 1] = rgba[i * 4 + 1]
                rgb[i * 3 + 2] = rgba[i * 4 + 2]
            }
        }

        /// For tests: pixels from a colour per pixel.
        init(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) {
            self.width = width
            self.height = height
            rgb = [UInt8](repeating: 0, count: width * height * 3)
            for y in 0..<height {
                for x in 0..<width {
                    let c = color(x, y)
                    let i = (y * width + x) * 3
                    rgb[i] = c.0; rgb[i + 1] = c.1; rgb[i + 2] = c.2
                }
            }
        }

        func color(_ i: Int) -> RGB { RGB(r: Int(rgb[i * 3]), g: Int(rgb[i * 3 + 1]), b: Int(rgb[i * 3 + 2])) }
    }

    struct RGB: Hashable {
        var r: Int, g: Int, b: Int
        func near(_ o: RGB, _ t: Int) -> Bool {
            let dr = r - o.r, dg = g - o.g, db = b - o.b
            return dr * dr + dg * dg + db * db <= t * t
        }
        /// Coarse bucket, for finding a common colour.
        var bucket: Int { (r >> 5) << 6 | (g >> 5) << 3 | (b >> 5) }
    }

    // MARK: Splitting

    static func split(_ p: Pixels, scale s: CGFloat, origin: CGPoint) -> [Region] {
        let w = p.width, h = p.height, n = w * h
        var background = [Bool](repeating: false, count: n)

        // 1. Background: the figure's common border colours, flooded in from the edge.
        var borderCounts: [Int: (count: Int, sum: (Int, Int, Int))] = [:]
        var border: [Int] = []
        for x in 0..<w { border.append(x); border.append((h - 1) * w + x) }
        for y in 1..<(h - 1) { border.append(y * w); border.append(y * w + w - 1) }
        for i in border {
            let c = p.color(i)
            var e = borderCounts[c.bucket] ?? (0, (0, 0, 0))
            e.count += 1
            e.sum = (e.sum.0 + c.r, e.sum.1 + c.g, e.sum.2 + c.b)
            borderCounts[c.bucket] = e
        }
        let backgroundColors = borderCounts.values.filter { $0.count * 100 >= border.count * 15 }
            .map { RGB(r: $0.sum.0 / $0.count, g: $0.sum.1 / $0.count, b: $0.sum.2 / $0.count) }
        for c in backgroundColors {
            flood(p, from: border.filter { p.color($0).near(c, tolerance) }, like: c, into: &background)
        }

        // 2. Peel: a colour wrapping everything left (the sea inside a white margin) is background too, when it's
        //    solid (not a drawing's outlines) and taking it away leaves separate shapes.
        let figurePixels = n
        let minPixels = max(Int(20 * s * s), figurePixels / 2000)
        let neck = max(1.2, min(4, 0.003 * max(CGFloat(w), CGFloat(h)) / s)) * s // In pixels.
        for _ in 0..<3 {
            // Its colour: a little in from the edge, past the blended pixels right on it.
            let inward = Labels.distance(background.map { !$0 }, width: w, height: h)
            var shore: [Int: (count: Int, sum: (Int, Int, Int))] = [:]
            var shorePixels: [Int] = []
            for i in 0..<n where inward[i] > 2 && inward[i] <= 4 {
                shorePixels.append(i)
                let c = p.color(i)
                var e = shore[c.bucket] ?? (0, (0, 0, 0))
                e.count += 1
                e.sum = (e.sum.0 + c.r, e.sum.1 + c.g, e.sum.2 + c.b)
                shore[c.bucket] = e
            }
            guard let top = shore.values.max(by: { $0.count < $1.count }) else { break }
            let c = RGB(r: top.sum.0 / top.count, g: top.sum.1 / top.count, b: top.sum.2 / top.count)
            var candidate = [Bool](repeating: false, count: n)
            let taken0 = background
            flood(p, from: shorePixels.filter { p.color($0).near(c, tolerance) }, like: c, blocked: taken0, into: &candidate)
            let foreground = background.reduce(0) { $0 + ($1 ? 0 : 1) }
            let taken = candidate.reduce(0) { $0 + ($1 ? 1 : 0) }
            guard foreground > 0, taken * 5 >= foreground else { break }
            // Solid: most of it is thicker than a line.
            let thickness = Labels.distance(candidate, width: w, height: h)
            let thick = thickness.reduce(0) { $0 + ($1 > Float(2 * neck + 1) ? 1 : 0) }
            guard thick * 2 >= taken else { break }
            var rest = [Bool](repeating: false, count: n)
            for i in 0..<n { rest[i] = !background[i] && !candidate[i] }
            // Only solid shapes count: the thin fringe left round a shape's edge isn't one.
            let restDistance = Labels.distance(rest, width: w, height: h)
            let solid = restDistance.map { $0 > 1.5 }
            let pieces = Labels.components(solid, width: w, height: h, eight: false)
            guard pieces.sizes.filter({ $0 >= minPixels }).count >= 2 else { break }
            for i in 0..<n where candidate[i] { background[i] = true }
        }

        // 3. Cut thin necks to find each shape's heart, then grow every heart back through everything thicker than a
        //    line (peninsulas included; a neck is shared between its two sides), and last a little into the thin
        //    edge, never along lines across the background.
        let foreground = background.map { !$0 }
        let distance = Labels.distance(foreground, width: w, height: h)
        var core = [Bool](repeating: false, count: n)
        for i in 0..<n where distance[i] > Float(neck) { core[i] = true }
        var labels = Labels.components(core, width: w, height: h, eight: true)
        let tiny = Set(labels.sizes.indices.filter { labels.sizes[$0] < minPixels / 4 }.map { Int32($0 + 1) })
        if !tiny.isEmpty {
            for i in 0..<n where labels.map[i] > 0 && tiny.contains(labels.map[i]) { labels.map[i] = 0 }
        }
        let body = (0..<n).map { foreground[$0] && distance[$0] >= 1.5 }
        Labels.grow(&labels.map, within: body, width: w, height: h, steps: Int.max)
        Labels.grow(&labels.map, within: foreground, width: w, height: h, steps: Int(neck.rounded(.up)) + 1)
        var sizes = [Int](repeating: 0, count: labels.sizes.count)
        for l in labels.map where l > 0 { sizes[Int(l) - 1] += 1 }

        // 4. Outlines, biggest first.
        let keep = sizes.indices.filter { sizes[$0] >= minPixels }.sorted { sizes[$0] > sizes[$1] }.prefix(maxParts)
        var members = [[Int]](repeating: [], count: sizes.count)
        for k in keep { members[k].reserveCapacity(sizes[k]) }
        let kept = Set(keep)
        for i in 0..<n {
            let l = Int(labels.map[i])
            if l > 0, kept.contains(l - 1) { members[l - 1].append(i) }
        }
        var patch = [Int32](repeating: 0, count: n)
        var nextPatch: Int32 = 0
        var out: [Region] = []
        for k in keep {
            let label = Int32(k + 1)
            guard let ring = Contour.outer(labels.map, label: label, first: members[k][0], width: w, height: h) else { continue }
            let pts = ring.map { CGPoint(x: origin.x + (CGFloat($0.x) + 0.5) / s, y: origin.y + (CGFloat($0.y) + 0.5) / s) }
            let outline = Simplify.rdp(pts + [pts[0]], 0.35).dropLast().map { $0 }
            guard outline.count >= 3 else { continue }
            var region = Region(outline: outline, bounds: bounds(outline), area: CGFloat(sizes[k]) / (s * s),
                                color: name(average(p, members[k])))
            region.areas = areas(p, labels.map, label: label, members: members[k], patch: &patch, next: &nextPatch,
                                 scale: s, origin: origin)
            out.append(region)
        }
        return out
    }

    /// The differently coloured patches of one part, when it has more than one big enough to matter.
    private static func areas(_ p: Pixels, _ map: [Int32], label: Int32, members: [Int], patch: inout [Int32],
                              next: inout Int32, scale s: CGFloat, origin: CGPoint) -> [Region] {
        let w = p.width, h = p.height
        let minPixels = max(Int(60 * s * s), members.count * 3 / 100)
        let t = (tolerance - 12) * (tolerance - 12)
        var patches: [(label: Int32, pixels: [Int])] = []
        var stack: [Int] = []
        p.rgb.withUnsafeBufferPointer { rgb in
            map.withUnsafeBufferPointer { map in
                patch.withUnsafeMutableBufferPointer { patch in
                    for i in members where patch[i] == 0 {
                        next += 1
                        let r = Int(rgb[i * 3]), g = Int(rgb[i * 3 + 1]), b = Int(rgb[i * 3 + 2])
                        var pixels: [Int] = []
                        stack.append(i)
                        patch[i] = next
                        while let j = stack.popLast() {
                            pixels.append(j)
                            let x = j % w
                            for k in [x > 0 ? j - 1 : -1, x < w - 1 ? j + 1 : -1, j >= w ? j - w : -1, j < (h - 1) * w ? j + w : -1]
                            where k >= 0 && patch[k] == 0 && map[k] == label {
                                let dr = Int(rgb[k * 3]) - r, dg = Int(rgb[k * 3 + 1]) - g, db = Int(rgb[k * 3 + 2]) - b
                                if dr * dr + dg * dg + db * db <= t {
                                    patch[k] = next
                                    stack.append(k)
                                }
                            }
                        }
                        if pixels.count >= minPixels { patches.append((next, pixels)) }
                    }
                }
            }
        }
        guard patches.count >= 2 else { return [] }
        let snapshot = patch
        return patches.sorted { $0.pixels.count > $1.pixels.count }.prefix(maxAreas).compactMap { a -> Region? in
            guard let ring = Contour.outer(snapshot, label: a.label, first: a.pixels.min() ?? a.pixels[0], width: w, height: h)
            else { return nil }
            let pts = ring.map { CGPoint(x: origin.x + (CGFloat($0.x) + 0.5) / s, y: origin.y + (CGFloat($0.y) + 0.5) / s) }
            let outline = Array(Simplify.rdp(pts + [pts[0]], 0.35).dropLast())
            guard outline.count >= 3 else { return nil }
            return Region(outline: outline, bounds: bounds(outline), area: CGFloat(a.pixels.count) / (s * s),
                          color: name(average(p, a.pixels)))
        }
    }

    /// Fills `into` with pixels connected to `seeds` whose colour is near `like`, never into `blocked` ones.
    private static func flood(_ p: Pixels, from seeds: [Int], like c: RGB, blocked: [Bool]? = nil, into mask: inout [Bool]) {
        let w = p.width, h = p.height
        let t = tolerance * tolerance
        var stack: [Int] = []
        p.rgb.withUnsafeBufferPointer { rgb in
            mask.withUnsafeMutableBufferPointer { mask in
                func ok(_ k: Int) -> Bool {
                    if mask[k] { return false }
                    if let blocked, blocked[k] { return false }
                    let dr = Int(rgb[k * 3]) - c.r, dg = Int(rgb[k * 3 + 1]) - c.g, db = Int(rgb[k * 3 + 2]) - c.b
                    return dr * dr + dg * dg + db * db <= t
                }
                for i in seeds where ok(i) {
                    mask[i] = true
                    stack.append(i)
                }
                while let i = stack.popLast() {
                    let x = i % w
                    if x > 0, ok(i - 1) { mask[i - 1] = true; stack.append(i - 1) }
                    if x < w - 1, ok(i + 1) { mask[i + 1] = true; stack.append(i + 1) }
                    if i >= w, ok(i - w) { mask[i - w] = true; stack.append(i - w) }
                    if i < (h - 1) * w, ok(i + w) { mask[i + w] = true; stack.append(i + w) }
                }
            }
        }
    }

    private static func average(_ p: Pixels, _ pixels: [Int]) -> RGB {
        guard !pixels.isEmpty else { return RGB(r: 0, g: 0, b: 0) }
        var r = 0, g = 0, b = 0
        for i in pixels {
            r += Int(p.rgb[i * 3]); g += Int(p.rgb[i * 3 + 1]); b += Int(p.rgb[i * 3 + 2])
        }
        return RGB(r: r / pixels.count, g: g / pixels.count, b: b / pixels.count)
    }

    static func bounds(_ pts: [CGPoint]) -> CGRect {
        pts.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    /// A plain name for a colour.
    static func name(_ c: RGB) -> String {
        let r = CGFloat(c.r) / 255, g = CGFloat(c.g) / 255, b = CGFloat(c.b) / 255
        let mx = max(r, g, b), mn = min(r, g, b)
        let sat = mx == 0 ? 0 : (mx - mn) / mx
        if sat < 0.18 {
            return mx > 0.85 ? "white" : mx < 0.25 ? "black" : "gray"
        }
        var hue: CGFloat
        let d = mx - mn
        if mx == r { hue = (g - b) / d } else if mx == g { hue = 2 + (b - r) / d } else { hue = 4 + (r - g) / d }
        hue = (hue * 60).truncatingRemainder(dividingBy: 360)
        if hue < 0 { hue += 360 }
        let base: String
        switch hue {
        case ..<15, 345...: base = "red"
        case ..<40: base = mx < 0.65 ? "brown" : "orange"
        case ..<70: base = mx < 0.6 ? "olive" : "yellow"
        case ..<165: base = "green"
        case ..<195: base = "teal"
        case ..<255: base = "blue"
        case ..<290: base = "purple"
        default: base = "pink"
        }
        return (sat < 0.45 && mx > 0.75 ? "light " : mx < 0.45 ? "dark " : "") + base
    }
}

// MARK: - Labelling

enum Labels {
    /// Connected pixels of `mask`, labelled 1…; `sizes[k-1]` is label k's pixel count.
    static func components(_ mask: [Bool], width w: Int, height h: Int, eight: Bool) -> (map: [Int32], sizes: [Int]) {
        var map = [Int32](repeating: 0, count: w * h)
        var sizes: [Int] = []
        var stack: [Int] = []
        mask.withUnsafeBufferPointer { mask in
            map.withUnsafeMutableBufferPointer { map in
                for start in 0..<(w * h) where mask[start] && map[start] == 0 {
                    let label = Int32(sizes.count + 1)
                    map[start] = label
                    stack.append(start)
                    var count = 0
                    while let i = stack.popLast() {
                        count += 1
                        let x = i % w, y = i / w
                        let y0 = y > 0 ? -1 : 0, y1 = y < h - 1 ? 1 : 0
                        let x0 = x > 0 ? -1 : 0, x1 = x < w - 1 ? 1 : 0
                        for dy in y0...y1 {
                            for dx in x0...x1 where (dx != 0 || dy != 0) && (eight || dx == 0 || dy == 0) {
                                let j = i + dy * w + dx
                                if mask[j] && map[j] == 0 {
                                    map[j] = label
                                    stack.append(j)
                                }
                            }
                        }
                    }
                    sizes.append(count)
                }
            }
        }
        return (map, sizes)
    }

    /// Distance from each pixel of `mask` to the nearest pixel outside it (chamfer 1, √2); the image's edge counts as
    /// outside.
    static func distance(_ mask: [Bool], width w: Int, height h: Int) -> [Float] {
        let big = Float(w + h)
        var out = mask.map { $0 ? big : 0 }
        let diag: Float = 1.4142
        out.withUnsafeMutableBufferPointer { d in
            for y in 0..<h {
                let row = y * w
                for x in 0..<w where d[row + x] > 0 {
                    var v = d[row + x]
                    v = min(v, (x > 0 ? d[row + x - 1] : 0) + 1)
                    if y > 0 {
                        let up = row - w
                        v = min(v, d[up + x] + 1)
                        v = min(v, (x > 0 ? d[up + x - 1] : 0) + diag)
                        v = min(v, (x < w - 1 ? d[up + x + 1] : 0) + diag)
                    } else {
                        v = min(v, 1)
                    }
                    d[row + x] = v
                }
            }
            for y in stride(from: h - 1, through: 0, by: -1) {
                let row = y * w
                for x in stride(from: w - 1, through: 0, by: -1) where d[row + x] > 0 {
                    var v = d[row + x]
                    v = min(v, (x < w - 1 ? d[row + x + 1] : 0) + 1)
                    if y < h - 1 {
                        let down = row + w
                        v = min(v, d[down + x] + 1)
                        v = min(v, (x < w - 1 ? d[down + x + 1] : 0) + diag)
                        v = min(v, (x > 0 ? d[down + x - 1] : 0) + diag)
                    } else {
                        v = min(v, 1)
                    }
                    d[row + x] = v
                }
            }
        }
        return out
    }

    /// Grows labels into unlabelled pixels of `within`, one pixel a step, for `steps` steps.
    static func grow(_ map: inout [Int32], within: [Bool], width w: Int, height h: Int, steps: Int) {
        var frontier = map.indices.filter { map[$0] > 0 }
        var next: [Int] = []
        var step = 0
        within.withUnsafeBufferPointer { within in
            map.withUnsafeMutableBufferPointer { map in
                while step < steps && !frontier.isEmpty {
                    step += 1
                    next.removeAll(keepingCapacity: true)
                    for i in frontier {
                        let l = map[i], x = i % w
                        if x > 0, within[i - 1], map[i - 1] == 0 { map[i - 1] = l; next.append(i - 1) }
                        if x < w - 1, within[i + 1], map[i + 1] == 0 { map[i + 1] = l; next.append(i + 1) }
                        if i >= w, within[i - w], map[i - w] == 0 { map[i - w] = l; next.append(i - w) }
                        if i < (h - 1) * w, within[i + w], map[i + w] == 0 { map[i + w] = l; next.append(i + w) }
                    }
                    swap(&frontier, &next)
                }
            }
        }
    }
}

// MARK: - Contours

enum Contour {
    struct Pixel: Equatable { var x: Int, y: Int }

    /// The outer boundary of the connected pixels labelled `label` that include the first one in reading order, as
    /// pixel positions, clockwise (Moore-neighbour tracing).
    static func outer(_ map: [Int32], label: Int32, first: Int? = nil, width w: Int, height h: Int) -> [Pixel]? {
        guard let first = first ?? map.firstIndex(of: label), map[first] == label else { return nil }
        let start = Pixel(x: first % w, y: first / w)
        // Clockwise on screen (y down), starting west.
        let dirs = [(-1, 0), (-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1)]
        func inside(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && map[y * w + x] == label }
        func direction(_ dx: Int, _ dy: Int) -> Int { dirs.firstIndex { $0.0 == dx && $0.1 == dy } ?? 0 }

        var ring = [start]
        var current = start
        var back = 0 // The pixel west of the start is outside (it's the first in reading order).
        let startBack = back
        let limit = 4 * w * h + 8
        for _ in 0..<limit {
            var moved = false
            for i in 1...8 {
                let d = (back + i) % 8
                let nx = current.x + dirs[d].0, ny = current.y + dirs[d].1
                guard inside(nx, ny) else { continue }
                let prev = (back + i - 1) % 8
                let bx = current.x + dirs[prev].0, by = current.y + dirs[prev].1
                current = Pixel(x: nx, y: ny)
                back = direction(bx - nx, by - ny)
                moved = true
                break
            }
            if !moved { return ring } // A single pixel.
            if current == start && back == startBack { break }
            if current == start, ring.count >= 2, ring[1] == nextStep(from: start, back: back, inside, dirs) { break }
            ring.append(current)
        }
        return ring
    }

    private static func nextStep(from p: Pixel, back: Int, _ inside: (Int, Int) -> Bool, _ dirs: [(Int, Int)]) -> Pixel? {
        for i in 1...8 {
            let d = (back + i) % 8
            if inside(p.x + dirs[d].0, p.y + dirs[d].1) { return Pixel(x: p.x + dirs[d].0, y: p.y + dirs[d].1) }
        }
        return nil
    }
}
