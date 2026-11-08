import Foundation
import PDFKit

// Everything printed on a PDF page that isn't text: ruled lines, answer blanks, boxes, tables, diagrams and images.
// Read once per page from the PDF's content stream, in the same coordinates as the text and the page picture.

// MARK: - One coordinate frame

/// PDF user space → page points (origin top-left, y down), exactly as Scribe shows the page: the crop box, with its
/// rotation applied (`PDFPages.displaySize`), scaled to the note page's width. A crop box that doesn't start at 0,0
/// and /Rotate are both included, so text, images, vector lines and the rendered picture all line up. Every reader on
/// the PDF goes through this one type.
struct PageFrame {
    /// PDF user space → drawn space (bottom-up, starting at 0,0, in PDF points).
    let toDrawn: CGAffineTransform
    /// The page as drawn, in PDF points.
    let drawnSize: CGSize
    /// Page points per PDF point.
    let scale: CGFloat

    /// The page as Scribe shows it, `width` page points wide.
    init(page: PDFPage, width: CGFloat = NotePageMetrics.width) {
        let crop = page.bounds(for: .cropBox)
        let t = page.transform(for: .cropBox)
        let drawn = crop.applying(t)
        self.init(toDrawn: t.concatenating(CGAffineTransform(translationX: -drawn.minX, y: -drawn.minY)),
                  drawnSize: drawn.size, width: width)
    }

    /// For tests: an unrotated page whose box is `box`, shown `width` points wide (its own width by default).
    init(box: CGRect, width: CGFloat? = nil) {
        self.init(toDrawn: CGAffineTransform(translationX: -box.minX, y: -box.minY), drawnSize: box.size,
                  width: width ?? box.width)
    }

    /// For tests: a page rotated by `degrees` (a multiple of 90) clockwise, as /Rotate does.
    init(box: CGRect, rotation degrees: Int, width: CGFloat? = nil) {
        let turns = ((degrees / 90) % 4 + 4) % 4
        // Rotating clockwise on screen is rotating by -90° in PDF space (y up).
        let rotate = CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)
        let t = CGAffineTransform(translationX: -box.minX, y: -box.minY).concatenating(rotate)
        let drawn = CGRect(origin: .zero, size: box.size).applying(rotate)
        let size = drawn.size
        self.init(toDrawn: t.concatenating(CGAffineTransform(translationX: -drawn.minX, y: -drawn.minY)),
                  drawnSize: size, width: width ?? size.width)
    }

    private init(toDrawn: CGAffineTransform, drawnSize: CGSize, width: CGFloat) {
        self.toDrawn = toDrawn
        self.drawnSize = drawnSize
        scale = drawnSize.width > 0 ? width / drawnSize.width : 1
    }

    /// The page in page points.
    var size: CGSize { CGSize(width: drawnSize.width * scale, height: drawnSize.height * scale) }

    func point(_ p: CGPoint) -> CGPoint {
        let d = p.applying(toDrawn)
        return CGPoint(x: d.x * scale, y: (drawnSize.height - d.y) * scale)
    }

    func rect(_ r: CGRect) -> CGRect {
        let d = r.standardized.applying(toDrawn)
        return CGRect(x: d.minX * scale, y: (drawnSize.height - d.maxY) * scale, width: d.width * scale,
                      height: d.height * scale)
    }
}

// MARK: - Reading the content stream

/// Walks a page's content stream with its graphics state (q/Q, cm), into Form XObjects, and records every painted
/// path and every image, in page points.
enum PDFContentScanner {
    struct PaintedPath {
        /// Subpaths, flattened to polylines, in page points.
        var subpaths: [[CGPoint]]
        var stroked: Bool
        var filled: Bool
        /// The path came from a single `re` (an exact rectangle).
        var isRect: Bool
        /// In page points.
        var lineWidth: CGFloat
    }

    struct Result {
        var paths: [PaintedPath] = []
        var images: [CGRect] = []
        /// More paths than `maxPaths`: the rest were skipped (text drawn as outlines, dense art). The pixel grid still
        /// covers them.
        var truncated = false
    }

    static let maxPaths = 20000
    static let maxFormDepth = 8

    fileprivate final class State {
        var ctm = CGAffineTransform.identity
        var lineWidth: CGFloat = 1
        var fillIsWhite = false
        var stack: [(CGAffineTransform, CGFloat, Bool)] = []
        /// XObject dictionaries, the form being read last.
        var xobjects: [CGPDFDictionaryRef?] = []
        var subpaths: [[CGPoint]] = []
        var current: [CGPoint] = []
        var currentPoint = CGPoint.zero
        var startPoint = CGPoint.zero
        var onlyRects = true
        var result = Result()
        var depth = 0
        var table: CGPDFOperatorTableRef?
        /// The page's /Resources, for a form that has none of its own.
        var pageResources: CGPDFDictionaryRef?
        let frame: PageFrame
        init(frame: PageFrame) { self.frame = frame }

        func user(_ p: CGPoint) -> CGPoint { p.applying(ctm) }

        func closeCurrent() {
            if current.count > 1 { subpaths.append(current) }
            current = []
        }

        func push() { stack.append((ctm, lineWidth, fillIsWhite)) }

        func pop() {
            guard let t = stack.popLast() else { return }
            ctm = t.0
            lineWidth = t.1
            fillIsWhite = t.2
        }

        func paint(stroke: Bool, fill: Bool) {
            closeCurrent()
            defer { subpaths = []; onlyRects = true }
            guard stroke || fill, !subpaths.isEmpty else { return }
            // A white fill with no outline paints over things: a background or an eraser, not content.
            if fill && !stroke && fillIsWhite { return }
            guard result.paths.count < PDFContentScanner.maxPaths else { result.truncated = true; return }
            let pts = subpaths.map { $0.map(frame.point) }
            // Line widths scale with the CTM (roughly: the mean of the two axes' scales).
            let s = (hypot(ctm.a, ctm.b) + hypot(ctm.c, ctm.d)) / 2
            result.paths.append(PaintedPath(subpaths: pts, stroked: stroke, filled: fill,
                                            isRect: onlyRects && subpaths.count == 1,
                                            lineWidth: max(0.1, lineWidth * s * frame.scale)))
        }
    }

    static func scan(_ page: PDFPage, frame: PageFrame) -> Result {
        guard let cg = page.pageRef, let table = CGPDFOperatorTableCreate() else { return Result() }
        let state = State(frame: frame)
        state.xobjects = [resourceDictionary(cg.dictionary, "XObject")]
        if let dict = cg.dictionary {
            var r: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(dict, "Resources", &r) { state.pageResources = r }
        }
        state.table = table
        install(table)
        let content = CGPDFContentStreamCreateWithPage(cg)
        run(content, state)
        CGPDFContentStreamRelease(content)
        CGPDFOperatorTableRelease(table)
        return state.result
    }

    private static func run(_ content: CGPDFContentStreamRef, _ state: State) {
        guard let table = state.table else { return }
        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(content, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
    }

    private static func resourceDictionary(_ owner: CGPDFDictionaryRef?, _ key: String) -> CGPDFDictionaryRef? {
        guard let owner else { return nil }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(owner, "Resources", &resources), let resources else { return nil }
        var d: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(resources, key, &d) ? d : nil
    }

    fileprivate static func state(_ info: UnsafeMutableRawPointer?) -> State? {
        guard let info else { return nil }
        return Unmanaged<State>.fromOpaque(info).takeUnretainedValue()
    }

    fileprivate static func numbers(_ scanner: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
        var v = [CGPDFReal](repeating: 0, count: n)
        for i in (0..<n).reversed() { guard CGPDFScannerPopNumber(scanner, &v[i]) else { return nil } }
        return v.map { CGFloat($0) }
    }

    /// A Bézier as 8 straight pieces: plenty for tracing and bounds.
    fileprivate static func flatten(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint) -> [CGPoint] {
        (1...8).map { i in
            let t = CGFloat(i) / 8, u = 1 - t
            let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p3.x, y: a * p0.y + b * c1.y + c * c2.y + d * p3.y)
        }
    }

    private static func install(_ table: CGPDFOperatorTableRef) {
        // Graphics state
        CGPDFOperatorTableSetCallback(table, "q") { _, info in PDFContentScanner.state(info)?.push() }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in PDFContentScanner.state(info)?.pop() }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 6) else { return }
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "w") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 1) else { return }
            s.lineWidth = v[0]
        }
        // Fill colour: only "is it white?" matters.
        CGPDFOperatorTableSetCallback(table, "g") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 1) else { return }
            s.fillIsWhite = v[0] > 0.97
        }
        CGPDFOperatorTableSetCallback(table, "rg") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 3) else { return }
            s.fillIsWhite = v.allSatisfy { $0 > 0.97 }
        }
        CGPDFOperatorTableSetCallback(table, "k") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 4) else { return }
            s.fillIsWhite = v.allSatisfy { $0 < 0.03 }
        }

        // Path construction (in user space; the CTM in effect applies).
        CGPDFOperatorTableSetCallback(table, "m") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 2) else { return }
            s.closeCurrent()
            let p = s.user(CGPoint(x: v[0], y: v[1]))
            s.current = [p]
            s.currentPoint = p
            s.startPoint = p
        }
        CGPDFOperatorTableSetCallback(table, "l") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 2) else { return }
            let p = s.user(CGPoint(x: v[0], y: v[1]))
            if s.current.isEmpty { s.current = [s.currentPoint] }
            s.current.append(p)
            s.currentPoint = p
            s.onlyRects = false
        }
        CGPDFOperatorTableSetCallback(table, "c") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 6) else { return }
            let c1 = s.user(CGPoint(x: v[0], y: v[1])), c2 = s.user(CGPoint(x: v[2], y: v[3]))
            let p = s.user(CGPoint(x: v[4], y: v[5]))
            if s.current.isEmpty { s.current = [s.currentPoint] }
            s.current += PDFContentScanner.flatten(s.currentPoint, c1, c2, p)
            s.currentPoint = p
            s.onlyRects = false
        }
        CGPDFOperatorTableSetCallback(table, "v") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 4) else { return }
            let c2 = s.user(CGPoint(x: v[0], y: v[1])), p = s.user(CGPoint(x: v[2], y: v[3]))
            if s.current.isEmpty { s.current = [s.currentPoint] }
            s.current += PDFContentScanner.flatten(s.currentPoint, s.currentPoint, c2, p)
            s.currentPoint = p
            s.onlyRects = false
        }
        CGPDFOperatorTableSetCallback(table, "y") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 4) else { return }
            let c1 = s.user(CGPoint(x: v[0], y: v[1])), p = s.user(CGPoint(x: v[2], y: v[3]))
            if s.current.isEmpty { s.current = [s.currentPoint] }
            s.current += PDFContentScanner.flatten(s.currentPoint, c1, p, p)
            s.currentPoint = p
            s.onlyRects = false
        }
        CGPDFOperatorTableSetCallback(table, "h") { _, info in
            guard let s = PDFContentScanner.state(info) else { return }
            if s.current.count > 1 { s.current.append(s.startPoint) }
            s.currentPoint = s.startPoint
        }
        CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
            guard let s = PDFContentScanner.state(info), let v = PDFContentScanner.numbers(scanner, 4) else { return }
            s.closeCurrent()
            let corners = [CGPoint(x: v[0], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1]), CGPoint(x: v[0] + v[2], y: v[1] + v[3]),
                           CGPoint(x: v[0], y: v[1] + v[3]), CGPoint(x: v[0], y: v[1])].map(s.user)
            s.subpaths.append(corners)
            s.currentPoint = corners[0]
            s.startPoint = corners[0]
        }

        // Painting
        CGPDFOperatorTableSetCallback(table, "S") { _, info in PDFContentScanner.state(info)?.paint(stroke: true, fill: false) }
        CGPDFOperatorTableSetCallback(table, "s") { _, info in
            guard let s = PDFContentScanner.state(info) else { return }
            if s.current.count > 1 { s.current.append(s.startPoint) }
            s.paint(stroke: true, fill: false)
        }
        for op in ["f", "F", "f*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in PDFContentScanner.state(info)?.paint(stroke: false, fill: true) }
        }
        for op in ["B", "B*", "b", "b*"] {
            CGPDFOperatorTableSetCallback(table, op) { _, info in PDFContentScanner.state(info)?.paint(stroke: true, fill: true) }
        }
        // `n` ends a path without painting it (clipping paths).
        CGPDFOperatorTableSetCallback(table, "n") { _, info in
            guard let s = PDFContentScanner.state(info) else { return }
            s.current = []
            s.subpaths = []
            s.onlyRects = true
        }

        // Images and forms
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let s = PDFContentScanner.state(info) else { return }
            var name: UnsafePointer<CChar>?
            guard CGPDFScannerPopName(scanner, &name), let name, let xobjects = s.xobjects.last ?? nil else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFDictionaryGetStream(xobjects, name, &stream), let stream,
                  let dict = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<CChar>?
            guard CGPDFDictionaryGetName(dict, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                let r = s.frame.rect(CGRect(x: 0, y: 0, width: 1, height: 1).applying(s.ctm))
                if r.width > 4 && r.height > 4 { s.result.images.append(r) }
            case "Form":
                guard s.depth < PDFContentScanner.maxFormDepth else { return }
                // A form is a little page of its own: its /Matrix, its own resources, drawn with the current state.
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dict, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var v = [CGPDFReal](repeating: 0, count: 6)
                    for i in 0..<6 { _ = CGPDFArrayGetNumber(array, i, &v[i]) }
                    matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
                }
                var own: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(dict, "Resources", &own)
                guard let resources = own ?? s.pageResources else { return }
                var inner: CGPDFDictionaryRef?
                _ = CGPDFDictionaryGetDictionary(resources, "XObject", &inner)
                // The form's paths are separate from whatever path was being built around it.
                let pending = (s.subpaths, s.current, s.onlyRects)
                s.subpaths = []
                s.current = []
                s.push()
                s.ctm = matrix.concatenating(s.ctm)
                s.xobjects.append(inner ?? xobjects)
                s.depth += 1
                let content = CGPDFContentStreamCreateWithStream(stream, resources, CGPDFScannerGetContentStream(scanner))
                PDFContentScanner.run(content, s)
                CGPDFContentStreamRelease(content)
                s.depth -= 1
                s.xobjects.removeLast()
                s.pop()
                (s.subpaths, s.current, s.onlyRects) = pending
            default:
                break
            }
        }
    }
}

// MARK: - From paths to things

/// Turns painted paths into page objects (`vec_N`, source `.printed`):
/// - `blank`: a short horizontal line with nothing on it: an answer line the person writes on
/// - `rule`: a long horizontal or vertical line (a divider, a margin)
/// - `underline`: a line right under printed text (parent: that line)
/// - `box`: a rectangle (an answer box, a frame); `checkbox` when small and square
/// - `table`: crossing horizontal and vertical lines; its cells are `vec_N.r1c1…` (kind `cell`, parent the table)
/// - `drawing`: any other cluster of lines and curves (a diagram, a number line, a graph's axes), with its `paths`
///   so the agent can trace it
/// Each carries its exact geometry: `outline` for closed shapes, `paths` for open ones.
enum VectorShapes {
    static let maxDrawings = 40
    static let maxPathPoints = 6000

    struct Piece {
        enum Kind { case hLine, vLine, rect, other }
        var kind: Kind
        var bounds: CGRect
        var points: [CGPoint]
    }

    private struct Found {
        var kind: String
        var bounds: CGRect
        var outline: [CGPoint]? = nil
        var paths: [[CGPoint]]? = nil
        var parent: String? = nil
        var cells: [[CGRect]]? = nil
    }

    /// Lines and rectangles are measured in page points; Scribe pages are wider than PDF pages, so thin lines
    /// (≤ 2.5 PDF points thick) are scaled by `scale` (page points per PDF point).
    static func objects(_ scan: PDFContentScanner.Result, pageSize: CGSize, textLines: [PageObject],
                        scale: CGFloat = 1) -> [PageObject] {
        let pieces = classify(scan.paths, pageSize: pageSize, scale: scale)
        var used = [Bool](repeating: false, count: pieces.count)
        var found: [Found] = []

        // 1. Tables: connected sets of horizontal and vertical lines (or rectangles), at least two of each direction
        //    and at least three of one.
        let gridIndices = pieces.indices.filter { pieces[$0].kind != .other }
        for comp in components(gridIndices, pieces, gap: 2 * scale) where comp.count >= 4 {
            let hs = comp.filter { pieces[$0].kind == .hLine || pieces[$0].kind == .rect }
            let vs = comp.filter { pieces[$0].kind == .vLine || pieces[$0].kind == .rect }
            let ys = merge(hs.flatMap { i -> [CGFloat] in
                pieces[i].kind == .rect ? [pieces[i].bounds.minY, pieces[i].bounds.maxY] : [pieces[i].bounds.midY]
            }, within: 2 * scale)
            let xs = merge(vs.flatMap { i -> [CGFloat] in
                pieces[i].kind == .rect ? [pieces[i].bounds.minX, pieces[i].bounds.maxX] : [pieces[i].bounds.midX]
            }, within: 2 * scale)
            guard ys.count >= 3 || xs.count >= 3, ys.count >= 2, xs.count >= 2 else { continue }
            let b = comp.reduce(CGRect.null) { $0.union(pieces[$1].bounds) }
            var cells: [[CGRect]] = []
            for r in 0..<(ys.count - 1) {
                cells.append((0..<(xs.count - 1)).map { c in
                    CGRect(x: xs[c], y: ys[r], width: xs[c + 1] - xs[c], height: ys[r + 1] - ys[r])
                })
            }
            // Tiny cells mean a pattern (hatching), not a table.
            guard cells.joined().allSatisfy({ $0.width >= 8 * scale && $0.height >= 8 * scale }) else { continue }
            comp.forEach { used[$0] = true }
            found.append(Found(kind: "table", bounds: b, outline: rectOutline(b), cells: cells))
        }

        // 2. Lines and boxes on their own.
        for i in pieces.indices where !used[i] {
            let p = pieces[i]
            let b = p.bounds
            switch p.kind {
            case .hLine:
                used[i] = true
                let path = [[CGPoint(x: b.minX, y: b.midY), CGPoint(x: b.maxX, y: b.midY)]]
                // Right under printed text: that text is underlined.
                if let line = textLines.first(where: { t in
                    let below = b.minY - t.bounds.maxY
                    return below > -3 * scale && below < 4 * scale
                        && overlapX(t.bounds, b) > 0.5 * min(t.bounds.width, b.width)
                }) {
                    found.append(Found(kind: "underline", bounds: b, paths: path, parent: line.id))
                    continue
                }
                found.append(Found(kind: b.width < 0.6 * pageSize.width ? "blank" : "rule", bounds: b, paths: path))
            case .vLine:
                used[i] = true
                found.append(Found(kind: "rule", bounds: b, paths: [[CGPoint(x: b.midX, y: b.minY), CGPoint(x: b.midX, y: b.maxY)]]))
            case .rect:
                used[i] = true
                guard b.width >= 5 * scale, b.height >= 5 * scale else { continue }
                let square = abs(b.width - b.height) < 0.2 * max(b.width, b.height)
                found.append(Found(kind: square && b.width <= 20 * scale ? "checkbox" : "box", bounds: b, outline: rectOutline(b)))
            case .other:
                break
            }
        }

        // 3. Everything else: clusters of curves and lines are drawings.
        let rest = pieces.indices.filter { !used[$0] }
        let clusters = components(rest, pieces, gap: 6 * scale).sorted { area($0, pieces) > area($1, pieces) }
        for comp in clusters.prefix(maxDrawings) {
            let b = comp.reduce(CGRect.null) { $0.union(pieces[$1].bounds) }
            guard max(b.width, b.height) >= 6 * scale else { continue }
            var paths: [[CGPoint]] = []
            var budget = maxPathPoints
            for i in comp.sorted(by: { pieces[$0].bounds.minY < pieces[$1].bounds.minY }) where budget > 2 {
                let simple = Array(Simplify.rdp(pieces[i].points, 0.3 * scale).prefix(budget))
                budget -= simple.count
                paths.append(simple)
            }
            // A cluster too detailed to send whole (shading, text drawn as outlines) keeps only its bounds.
            found.append(Found(kind: "drawing", bounds: b, paths: budget > 2 ? paths : nil))
        }

        // IDs in reading order.
        found.sort { a, b in
            abs(a.bounds.minY - b.bounds.minY) > 2 ? a.bounds.minY < b.bounds.minY : a.bounds.minX < b.bounds.minX
        }
        var out: [PageObject] = []
        for (n, f) in found.enumerated() {
            let id = "vec_\(n + 1)"
            let text = f.cells.map { "\($0.count)×\($0.first?.count ?? 0) cells" }
            out.append(PageObject(id: id, source: .printed, kind: f.kind, text: text, bounds: f.bounds, outline: f.outline,
                                  parent: f.parent, paths: f.paths))
            for (r, row) in (f.cells ?? []).enumerated() {
                for (c, cell) in row.enumerated() {
                    out.append(PageObject(id: "\(id).r\(r + 1)c\(c + 1)", source: .printed, kind: "cell",
                                          text: textInside(cell, textLines), bounds: cell, outline: rectOutline(cell), parent: id))
                }
            }
        }
        return out
    }

    // MARK: Pieces

    static func classify(_ paths: [PDFContentScanner.PaintedPath], pageSize: CGSize, scale: CGFloat = 1) -> [Piece] {
        let page = CGRect(origin: .zero, size: pageSize)
        let thin = 2.5 * scale, long = 10 * scale
        var out: [Piece] = []
        for p in paths {
            for sub in p.subpaths {
                var b = sub.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                if p.stroked { b = b.insetBy(dx: -p.lineWidth / 2, dy: -p.lineWidth / 2) }
                guard !b.isNull, b.intersects(page) else { continue }
                // The page's own background, or a frame around the whole page.
                if b.width > 0.9 * pageSize.width && b.height > 0.9 * pageSize.height { continue }
                let axisRect = p.isRect || isAxisAlignedRect(sub)
                if b.height <= thin && b.width >= long && (axisRect || isStraight(sub)) {
                    out.append(Piece(kind: .hLine, bounds: b, points: sub))
                } else if b.width <= thin && b.height >= long && (axisRect || isStraight(sub)) {
                    out.append(Piece(kind: .vLine, bounds: b, points: sub))
                } else if axisRect {
                    out.append(Piece(kind: .rect, bounds: b, points: sub))
                } else {
                    // Curves, diagonals, polygons: parts of a drawing.
                    out.append(Piece(kind: .other, bounds: b, points: sub))
                }
            }
        }
        return out
    }

    static func isStraight(_ pts: [CGPoint]) -> Bool {
        guard pts.count >= 2, let a = pts.first, let b = pts.last else { return false }
        return hypot(b.x - a.x, b.y - a.y) >= 0.97 * Simplify.length(pts)
    }

    static func isAxisAlignedRect(_ pts: [CGPoint]) -> Bool {
        guard pts.count == 4 || pts.count == 5 else { return false }
        if pts.count == 5, hypot(pts[4].x - pts[0].x, pts[4].y - pts[0].y) > 0.5 { return false }
        let ring = Array(pts.prefix(4))
        for i in 0..<4 {
            let a = ring[i], b = ring[(i + 1) % 4]
            if abs(a.x - b.x) > 0.5 && abs(a.y - b.y) > 0.5 { return false }
        }
        return true
    }

    /// Groups of pieces whose bounds are within `gap` of each other (union–find over a coarse bucket grid).
    private static func components(_ indices: [Int], _ pieces: [Piece], gap: CGFloat) -> [[Int]] {
        guard !indices.isEmpty else { return [] }
        var parent = Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })
        func find(_ x: Int) -> Int {
            var x = x
            while let p = parent[x], p != x {
                parent[x] = parent[p] ?? p
                x = p
            }
            return x
        }
        func unite(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        let bucket: CGFloat = 64
        var buckets: [Int: [Int]] = [:]
        func key(_ x: Int, _ y: Int) -> Int { x &* 73_856_093 ^ y &* 19_349_663 }
        for i in indices {
            let b = pieces[i].bounds.insetBy(dx: -gap, dy: -gap)
            let x0 = Int((b.minX / bucket).rounded(.down)), x1 = Int((b.maxX / bucket).rounded(.down))
            let y0 = Int((b.minY / bucket).rounded(.down)), y1 = Int((b.maxY / bucket).rounded(.down))
            for x in x0...x1 {
                for y in y0...y1 {
                    for j in buckets[key(x, y)] ?? [] where PageMap.gap(pieces[i].bounds, pieces[j].bounds) <= gap { unite(i, j) }
                    buckets[key(x, y), default: []].append(i)
                }
            }
        }
        return Array(Dictionary(grouping: indices, by: find).values).map { $0.sorted() }
    }

    private static func merge(_ values: [CGFloat], within: CGFloat) -> [CGFloat] {
        var out: [CGFloat] = []
        for v in values.sorted() {
            if let last = out.last, v - last <= within { continue }
            out.append(v)
        }
        return out
    }

    private static func area(_ comp: [Int], _ pieces: [Piece]) -> CGFloat {
        PageMap.area(comp.reduce(CGRect.null) { $0.union(pieces[$1].bounds) })
    }

    private static func overlapX(_ a: CGRect, _ b: CGRect) -> CGFloat { max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) }

    static func rectOutline(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    private static func textInside(_ cell: CGRect, _ lines: [PageObject]) -> String? {
        let t = lines.filter { cell.contains(CGPoint(x: $0.bounds.midX, y: $0.bounds.midY)) }.compactMap(\.text)
            .joined(separator: " ")
        return t.isEmpty ? nil : t
    }
}

// MARK: - Images on the paper

/// The images drawn on a PDF page (`img_N`, kind `figure`), images inside forms included.
enum EmbeddedImages {
    static func objects(from scan: PDFContentScanner.Result, startingAt first: Int = 1) -> [PageObject] {
        scan.images.enumerated().map { i, b in
            PageObject(id: "img_\(first + i)", source: .printed, kind: "figure", bounds: b)
        }
    }
}

// MARK: - Simplifying lines

enum Simplify {
    static func length(_ pts: [CGPoint]) -> CGFloat {
        zip(pts, pts.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }

    /// Ramer–Douglas–Peucker, loosening the tolerance until there are at most `max` points.
    static func limited(_ pts: [CGPoint], max: Int) -> [CGPoint] {
        guard pts.count > max else { return pts }
        var tolerance: CGFloat = 0.5
        var out = pts
        while out.count > max {
            out = rdp(pts, tolerance)
            tolerance *= 1.5
        }
        return out
    }

    static func rdp(_ pts: [CGPoint], _ eps: CGFloat) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var keep = [Bool](repeating: false, count: pts.count)
        keep[0] = true
        keep[pts.count - 1] = true
        var stack = [(0, pts.count - 1)]
        while let (a, b) = stack.popLast() {
            guard b > a + 1 else { continue }
            var best = 0, dmax: CGFloat = -1
            for i in (a + 1)..<b {
                let d = distance(pts[i], pts[a], pts[b])
                if d > dmax { dmax = d; best = i }
            }
            if dmax > eps {
                keep[best] = true
                stack.append((a, best))
                stack.append((best, b))
            }
        }
        return pts.enumerated().filter { keep[$0.offset] }.map(\.element)
    }

    private static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        return abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
    }
}
