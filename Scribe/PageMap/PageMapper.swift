import Observation
import PDFKit
import PencilKit
import SwiftUI

/// Builds `PageMapSnapshot`s for one note: the page picture plus everything on it with a stable ID. Printed content is
/// read once per PDF page; ink is regrouped when it changes; handwriting is read in the background, so a snapshot is
/// ready quickly once the person stops writing.
@MainActor @Observable
final class PageMapper {
    /// The latest snapshot of each page (the debug overlay draws it).
    private(set) var latest: [UUID: PageMapSnapshot] = [:]

    @ObservationIgnored private let pdfURL: URL?
    @ObservationIgnored private lazy var pdf: PDFDocument? = pdfURL.flatMap(PDFDocument.init(url:))
    /// Printed text and graphics, by PDF page.
    @ObservationIgnored private var printed: [Int: [PageObject]] = [:]
    /// OCR of PDF pages with no text layer (scans, photos of worksheets), by PDF page.
    @ObservationIgnored private var scanned: [Int: [PageObject]] = [:]
    @ObservationIgnored private var scanTasks: [Int: Task<[PageObject], Never>] = [:]
    @ObservationIgnored private var ink: [UUID: InkResult] = [:]
    @ObservationIgnored private var registries: [UUID: InkIDRegistry] = [:]
    @ObservationIgnored private var readings: [String: HandwritingReader.Reading?] = [:]
    @ObservationIgnored private var reading: [String: Task<Void, Never>] = [:]
    /// When the agent last finished a turn on each page: ink drawn after it is tagged "new".
    @ObservationIgnored private var lastTurn: [UUID: TimeInterval] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    /// Each figure's parts, by figure and where it sits (the paper doesn't change, so they're found once).
    @ObservationIgnored private var regions: [String: [FigureRegions.Region]] = [:]

    /// Longest side of the picture sent to the agent, in pixels.
    static let maxImageSide: CGFloat = 1568
    static let jpegQuality: CGFloat = 0.8
    /// How long a snapshot waits for handwriting still being read.
    static let readingBudget: Duration = .milliseconds(250)
    /// Strokes kept per traced shape or drawing.
    static let tracedStrokes = 30

    private struct InkResult {
        var drawing: PKDrawing
        var objects: [PageObject]
        var height: CGFloat
        var unread: [String]
        /// When each ink object's strokes were drawn (for "new", "latest", and crossing out).
        var timing: [String: PageRelations.InkTiming]
    }

    init(pdfURL: URL?) {
        self.pdfURL = pdfURL
    }

    // MARK: Building

    /// Starts the slow parts (printed content, OCR, reading handwriting) so `snapshot` finds them done.
    func prepare(_ page: NotePage) {
        _ = printedObjects(page.pdfPage)
        Task { [weak self] in
            guard let self else { return }
            _ = await self.scannedText(page.pdfPage)
            _ = self.inkObjects(page)
        }
    }

    /// The person drew: regroup and start reading new handwriting after a pause; with the debug overlay on, map again.
    func inkChanged(_ page: NotePage, rebuild: @escaping @MainActor () -> Void) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            _ = self.inkObjects(page)
            if PageMapDebug.shared.showOverlay { rebuild() }
        }
    }

    /// The agent finished a turn on the page: what the person draws from now on is "new" in the next snapshot.
    func markTurn(pageID: UUID) {
        lastTurn[pageID] = Date().timeIntervalSinceReferenceDate
    }

    /// The page as the agent sees it now. Logs how long it took and the size of the text block.
    func snapshot(of page: NotePage, render: (NotePage, CGFloat) -> UIImage?) async -> PageMapSnapshot {
        let clock = ContinuousClock()
        let start = clock.now
        let size = page.bounds.size
        var objects = printedObjects(page.pdfPage) + (await scannedText(page.pdfPage))
        var inkResult = inkObjects(page)
        if !inkResult.unread.isEmpty {
            await waitForReadings(inkResult.unread, until: start + Self.readingBudget)
            inkResult = inkObjects(page)
        }
        objects += photoObjects(page)
        objects += await figureParts(page, objects, render: render)
        objects += inkResult.objects
        let marks = agentMarks(page)
        objects += marks.map { PageObject(id: $0.id, source: .agentInk, kind: $0.kind, text: $0.text, bounds: $0.bounds) }
        objects += cardObjects(page)
        // Structure: what's new, crossed out, in which blank, answering which question, which lines are working.
        objects = PageRelations.annotate(objects, timing: inkResult.timing, lastTurn: lastTurn[page.id],
                                         inkHeight: inkResult.height)

        let scale = Self.imageScale(for: size)
        let picture = render(page, scale)
        let image = picture?.jpegData(compressionQuality: Self.jpegQuality) ?? Data()
        let viewport = CGRect(origin: .zero, size: size)
        // What's drawn where, from the picture's own pixels, and the free spaces read from it.
        let cgImage = picture?.cgImage
        let found = objects
        let height = inkResult.height
        let layout = await Task.detached(priority: .userInitiated) {
            PageLayout.build(image: cgImage, pageSize: size, objects: found, inkHeight: height, viewport: viewport)
        }.value

        let snapshot = PageMapSnapshot(pageID: page.id, pageSize: size, image: image, imageScale: scale, objects: objects,
                                       agentMarks: marks, studentInkHeight: inkResult.height, viewport: viewport,
                                       occupancy: layout.grid, freeSpaces: layout.free)
        let elapsed = start.duration(to: clock.now)
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        let tokens = PageMapText.estimatedTokens(PageMapText.block(snapshot))
        latest[page.id] = snapshot
        PageMapDebug.shared.record(.init(page: page.id, milliseconds: ms, objects: objects.count, tokens: tokens,
                                         freeSpaces: layout.free.count))
        PageMapDebug.log.info("Page map: \(objects.count) objects, \(layout.free.count) free spaces, ~\(tokens) tokens, \(Int(ms)) ms")
        return snapshot
    }

    /// Pixels per page point for the picture: the long side at most `maxImageSide`.
    static func imageScale(for size: CGSize) -> CGFloat {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return 1 }
        return min(maxImageSide / longest, 2)
    }

    // MARK: Printed content

    /// Text, images and vector graphics (lines, blanks, boxes, tables, diagrams) of a PDF page, in one `PageFrame`.
    func printedObjects(_ index: Int?) -> [PageObject] {
        guard let index else { return [] }
        if let cached = printed[index] { return cached }
        var out: [PageObject] = []
        if let page = pdf?.page(at: index) {
            let frame = PageFrame(page: page)
            let text = PrintedText.objects(for: page, frame: frame)
            let scan = PDFContentScanner.scan(page, frame: frame)
            out += text
            out += EmbeddedImages.objects(from: scan)
            out += VectorShapes.objects(scan, pageSize: frame.size, textLines: text.filter { $0.kind == "line" },
                                        scale: frame.scale)
            if scan.truncated {
                PageMapDebug.log.info("PDF page \(index + 1) has more than \(PDFContentScanner.maxPaths) vector paths; the rest are covered by the pixel grid only")
            }
        }
        printed[index] = out
        return out
    }

    /// A PDF page with no text layer gets its text from OCR of the printed picture (once, in the background).
    private func scannedText(_ index: Int?) async -> [PageObject] {
        guard let index, let url = pdfURL else { return [] }
        if let s = scanned[index] { return s }
        if let task = scanTasks[index] { return await task.value }
        guard !printedObjects(index).contains(where: { $0.source == .pdfText }), let page = pdf?.page(at: index) else {
            scanned[index] = []
            return []
        }
        let size = PageFrame(page: page).size
        let task = Task.detached(priority: .userInitiated) { () -> [PageObject] in
            guard let image = PDFPages.image(url: url, page: index, pixelWidth: 2200)?.cgImage else { return [] }
            return PrintedText.objects(from: ScannedText.words(image: image, area: CGRect(origin: .zero, size: size)))
        }
        scanTasks[index] = task
        let objects = await task.value
        scanned[index] = objects
        scanTasks[index] = nil
        return objects
    }

    /// Photos placed on the page (`photo_N`).
    private func photoObjects(_ page: NotePage) -> [PageObject] {
        page.images.enumerated().map { i, placed in
            PageObject(id: "photo_\(i + 1)", source: .printed, kind: "photo", bounds: placed.bounds)
        }
    }

    // MARK: Figures, split into their parts

    /// Figures (`img_N`, `photo_N`, printed drawings) worth splitting.
    static func figures(_ objects: [PageObject]) -> [PageObject] {
        objects.filter { o in
            o.source == .printed && o.parent == nil && ["figure", "photo", "drawing"].contains(o.kind)
                && o.bounds.width >= FigureRegions.minFigureSide && o.bounds.height >= FigureRegions.minFigureSide
        }
    }

    /// The parts of each figure (`img_1.p3`) and their coloured areas (`img_1.p3.a2`), traced from the paper alone
    /// (no ink or marks), so the agent can point at one continent of a map and the app can trace it exactly.
    private func figureParts(_ page: NotePage, _ objects: [PageObject],
                             render: (NotePage, CGFloat) -> UIImage?) async -> [PageObject] {
        let figures = Self.figures(objects)
        guard !figures.isEmpty else { return [] }
        func key(_ o: PageObject) -> String {
            let photo = o.kind == "photo" ? page.images.first { $0.bounds == o.bounds }?.fileName ?? "" : ""
            return "\(page.pdfPage ?? -1)|\(photo)|\(o.kind)|\(PageMap.format(o.bounds))"
        }
        let missing = figures.filter { regions[key($0)] == nil }
        if !missing.isEmpty {
            var paper = page
            paper.drawing = PKDrawing()
            paper.agentDrawing = PKDrawing()
            paper.agentMarks = []
            paper.cards = []
            let scale = FigureRegions.maxScale
            if let picture = render(paper, scale)?.cgImage {
                let boxes = missing.map(\.bounds)
                let found = await Task.detached(priority: .userInitiated) {
                    boxes.map { FigureRegions.regions(in: picture, scale: scale, figure: $0) }
                }.value
                for (o, r) in zip(missing, found) { regions[key(o)] = r }
            }
        }
        var out: [PageObject] = []
        for figure in figures {
            for (k, part) in (regions[key(figure)] ?? []).enumerated() {
                let id = "\(figure.id).p\(k + 1)"
                out.append(PageObject(id: id, source: .printed, kind: "part", text: part.color, bounds: part.bounds,
                                      outline: part.outline, parent: figure.id))
                for (j, area) in part.areas.enumerated() {
                    out.append(PageObject(id: "\(id).a\(j + 1)", source: .printed, kind: "area", text: area.color,
                                          bounds: area.bounds, outline: area.outline, parent: id))
                }
            }
        }
        return out
    }

    // MARK: The person's ink

    private func inkObjects(_ page: NotePage) -> InkResult {
        let drawing = page.drawing
        if let cached = ink[page.id], cached.drawing == drawing, cached.unread.allSatisfy({ readings[$0] == nil }) {
            return cached
        }
        let strokes = drawing.strokes.map(\.mapStroke)
        let byID = Dictionary(strokes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let strokesByID = Dictionary(zip(strokes.map(\.id), drawing.strokes), uniquingKeysWith: { first, _ in first })

        struct Group {
            var strokes: [StrokeID]
            var kind: String
            var text: String?
            var confidence: Float?
        }
        var groups: [Group] = []
        let measured = InkGrouping.groupAndMeasure(strokes)
        let h0 = measured.inkHeight
        var unread: [String] = []
        for g in measured.groups {
            let ids = g.map(\.id)
            if let shape = ShapeClassifier.classify(g, inkHeight: h0) {
                groups.append(Group(strokes: ids, kind: "shape", text: shape))
                continue
            }
            let key = ids.sorted().joined(separator: "|")
            let box = g.reduce(CGRect.null) { $0.union($1.bounds) }
            if let cached = readings[key] {
                if let r = cached, r.confidence >= HandwritingReader.minimumConfidence,
                   r.text.contains(where: { $0.isLetter || $0.isNumber }) {
                    groups.append(Group(strokes: ids, kind: "handwriting", text: r.text, confidence: r.confidence))
                } else {
                    groups.append(Group(strokes: ids, kind: "drawing"))
                }
            } else {
                startReading(key: key, strokes: ids.compactMap { strokesByID[$0] })
                unread.append(key)
                groups.append(Group(strokes: ids, kind: box.height < 3.5 * h0 ? "handwriting" : "drawing"))
            }
        }

        // Stable IDs.
        var registry = registries[page.id] ?? InkIDRegistry()
        let ids = registry.assign(groups.map { Set($0.strokes) })
        registries[page.id] = registry
        var objects: [PageObject] = []
        var timing: [String: PageRelations.InkTiming] = [:]
        for (i, g) in groups.enumerated() {
            let mine = g.strokes.compactMap { byID[$0] }
            let b = mine.map(\.bounds).reduce(CGRect.null) { $0.union($1) }
            guard !b.isNull else { continue }
            // Shapes and drawings carry their strokes' exact lines, so the agent can trace or extend them.
            var paths: [[CGPoint]]?
            if g.kind == "shape" || g.kind == "drawing" {
                paths = mine.sorted { $0.start < $1.start }.prefix(Self.tracedStrokes)
                    .map { Simplify.limited(Simplify.rdp($0.points, 0.8), max: 64) }
            }
            objects.append(PageObject(id: ids[i], source: .studentInk, kind: g.kind, text: g.text, bounds: b,
                                      strokeIDs: g.strokes, paths: paths, confidence: g.confidence))
            if let start = mine.map(\.start).min(), let end = mine.map(\.end).max() {
                timing[ids[i]] = PageRelations.InkTiming(start: start, end: end)
            }
        }
        objects.sort { a, b in a.bounds.minY != b.bounds.minY ? a.bounds.minY < b.bounds.minY : a.id < b.id }

        // Handwriting height: from the handwriting's own strokes when there are enough.
        let handwriting = Set(objects.filter { $0.kind == "handwriting" }.flatMap { $0.strokeIDs ?? [] })
        let written = strokes.filter { handwriting.contains($0.id) }
        let height = written.count >= 3 ? InkGrouping.groupAndMeasure(written).inkHeight : h0

        let result = InkResult(drawing: drawing, objects: objects, height: height, unread: unread, timing: timing)
        ink[page.id] = result
        return result
    }

    private func startReading(key: String, strokes: [PKStroke]) {
        guard reading[key] == nil, !strokes.isEmpty else { return }
        reading[key] = Task { [weak self] in
            // Rendering ink is slow for big groups: never on the main thread.
            let result = await Task.detached(priority: .userInitiated) { () -> HandwritingReader.Reading? in
                HandwritingReader.image(of: strokes).flatMap(HandwritingReader.read)
            }.value
            guard let self else { return }
            self.readings[key] = .some(result)
            self.reading[key] = nil
        }
    }

    private func waitForReadings(_ keys: [String], until deadline: ContinuousClock.Instant) async {
        let tasks = keys.compactMap { reading[$0] }
        guard !tasks.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { for task in tasks { await task.value } }
            group.addTask { try? await Task.sleep(until: deadline, clock: .continuous) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: The agent's marks and cards

    /// `am_1…` in the order they were drawn.
    private func agentMarks(_ page: NotePage) -> [AgentMarkSummary] {
        page.agentMarks.enumerated().compactMap { i, mark in
            let bounds = mark.bounds
            guard !bounds.isNull else { return nil }
            return AgentMarkSummary(id: "am_\(i + 1)", kind: mark.kind, text: mark.text, bounds: bounds, target: mark.target)
        }
    }

    /// `card_1…` in the order they were made.
    private func cardObjects(_ page: NotePage) -> [PageObject] {
        page.cards.enumerated().map { i, card in
            PageObject(id: "card_\(i + 1)", source: .card, kind: card.kind.rawValue, text: card.title, bounds: card.frame)
        }
    }

    // MARK: Debug

    /// The smallest object under a point (the overlay's tap), ignoring words.
    func object(at p: CGPoint, page: UUID) -> PageObject? {
        guard let snapshot = latest[page] else { return nil }
        return snapshot.objects.filter { $0.kind != "word" && $0.bounds.insetBy(dx: -3, dy: -3).contains(p) }
            .min { PageMap.area($0.bounds) < PageMap.area($1.bounds) }
    }
}
