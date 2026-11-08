import CoreGraphics
import PencilKit
import XCTest
@testable import Scribe

/// The page map's pure parts: the occupancy grid and free spaces, relations, vector shapes, snapping, placement and
/// the PDF coordinate frame.
final class PageMapTests: XCTestCase {
    // MARK: Occupancy grid

    /// A white picture of `size` points at one pixel per point, with black where `rects` are.
    private func picture(_ size: CGSize, black rects: [CGRect]) -> CGImage {
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setFillColor(gray: 0, alpha: 1)
        // CGContext is bottom-up; the grid reads the picture top-down.
        for r in rects { ctx.fill(CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height)) }
        return ctx.makeImage()!
    }

    func testGridReadsDrawnPixelsTopDown() {
        let size = CGSize(width: 200, height: 100)
        let grid = OccupancyGrid.from(image: picture(size, black: [CGRect(x: 20, y: 10, width: 40, height: 8)]), pageSize: size)
        XCTAssertFalse(grid.isFree(CGRect(x: 30, y: 12, width: 4, height: 4)))
        XCTAssertTrue(grid.isFree(CGRect(x: 30, y: 60, width: 40, height: 30)), "the bottom of the page is blank")
        XCTAssertTrue(grid.isFree(CGRect(x: 100, y: 10, width: 60, height: 8)))
        XCTAssertEqual(grid.coverage(CGRect(x: 20, y: 10, width: 40, height: 8)), 1, accuracy: 0.001)
    }

    func testGridScalesPicturesOfAnotherSize() {
        // A 400×200 px picture of a 200×100 pt page.
        let grid = OccupancyGrid.from(image: picture(CGSize(width: 400, height: 200), black: [CGRect(x: 0, y: 0, width: 40, height: 40)]),
                                      pageSize: CGSize(width: 200, height: 100))
        XCTAssertFalse(grid.isFree(CGRect(x: 4, y: 4, width: 4, height: 4)))
        XCTAssertTrue(grid.isFree(CGRect(x: 24, y: 24, width: 8, height: 8)), "40 px is 20 pt")
    }

    func testMarkingAndSpaceBeyondTheGrid() {
        let grid = OccupancyGrid(size: CGSize(width: 100, height: 100)).marking([CGRect(x: 10, y: 10, width: 20, height: 20)])
        XCTAssertFalse(grid.isFree(CGRect(x: 15, y: 15, width: 2, height: 2)))
        XCTAssertTrue(grid.isFree(CGRect(x: 50, y: 50, width: 20, height: 20)))
        XCTAssertTrue(grid.isFree(CGRect(x: 10, y: 120, width: 50, height: 50)), "space added below the page is free")
        let dilated = grid.dilated()
        // Marking takes whole 4 pt cells: x 10–30 takes cells up to x 32.
        XCTAssertFalse(dilated.isFree(CGRect(x: 33, y: 15, width: 2, height: 2)), "dilating adds a cell all round")
        XCTAssertTrue(grid.isFree(CGRect(x: 33, y: 15, width: 2, height: 2)))
    }

    func testNearestFreeAvoidsTakenCells() {
        let grid = OccupancyGrid(size: CGSize(width: 300, height: 300)).marking([CGRect(x: 100, y: 100, width: 100, height: 100)])
        let anchor = CGRect(x: 140, y: 140, width: 20, height: 20)
        let spot = grid.nearestFree(size: CGSize(width: 40, height: 20), near: anchor, in: CGRect(x: 0, y: 0, width: 300, height: 300))
        XCTAssertNotNil(spot)
        XCTAssertTrue(grid.isFree(spot!))
        XCTAssertLessThan(OccupancyGrid.gap(spot!, CGRect(x: 100, y: 100, width: 100, height: 100)), 8, "right next to the block")
        XCTAssertNil(grid.nearestFree(size: CGSize(width: 40, height: 20), near: anchor, in: CGRect(x: 0, y: 0, width: 300, height: 300),
                                      maxDistance: 10), "nothing clear within 10 pt of the anchor")
    }

    func testFreeRectsAreLargeDisjointAndClear() {
        // Text across the top, a figure on the left: the big clear spaces are on the right and at the bottom.
        let grid = OccupancyGrid(size: CGSize(width: 400, height: 400))
            .marking([CGRect(x: 0, y: 0, width: 400, height: 60), CGRect(x: 0, y: 60, width: 150, height: 200)])
        let free = grid.freeRects(minSize: CGSize(width: 72, height: 26), max: 5, in: CGRect(x: 0, y: 0, width: 400, height: 400))
        XCTAssertFalse(free.isEmpty)
        for (i, a) in free.enumerated() {
            XCTAssertTrue(grid.isFree(a))
            XCTAssertGreaterThanOrEqual(a.width, 72)
            XCTAssertGreaterThanOrEqual(a.height, 26)
            for b in free.dropFirst(i + 1) { XCTAssertFalse(a.intersects(b)) }
        }
        XCTAssertGreaterThanOrEqual(PageMap.area(free[0]), PageMap.area(free.last!))
        // Beside the figure, from the text down: x 152–400 (the figure's last cell ends at 152), y 60–400.
        XCTAssertEqual(free[0], CGRect(x: 152, y: 60, width: 248, height: 340))
    }

    func testGridRoundTripsThroughJSON() throws {
        let grid = OccupancyGrid(size: CGSize(width: 123, height: 77)).marking([CGRect(x: 5, y: 9, width: 30, height: 13)])
        let decoded = try JSONDecoder().decode(OccupancyGrid.self, from: JSONEncoder().encode(grid))
        XCTAssertEqual(decoded, grid)
        XCTAssertFalse(decoded.isFree(CGRect(x: 10, y: 12, width: 2, height: 2)))
    }

    func testLayoutReservesAnswerSpacesAndNamesNeighbours() {
        let objects = [
            PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "1. What is 3 × 4?", bounds: CGRect(x: 40, y: 40, width: 300, height: 20)),
            PageObject(id: "vec_1", source: .printed, kind: "blank", bounds: CGRect(x: 40, y: 120, width: 200, height: 1)),
        ]
        let reserved = PageLayout.answerSpaces(objects, inkHeight: 20)
        XCTAssertEqual(reserved.count, 1)
        XCTAssertEqual(reserved[0].bounds.maxY, 121, accuracy: 0.01)
        XCTAssertEqual(reserved[0].bounds.minY, 120 - 32, accuracy: 0.01, "1.6 handwriting heights above the line")

        let layout = PageLayout.build(image: nil, pageSize: CGSize(width: 600, height: 400), objects: objects, inkHeight: 20,
                                      viewport: CGRect(x: 0, y: 0, width: 600, height: 200))
        XCTAssertFalse(layout.free.isEmpty)
        for space in layout.free {
            XCTAssertFalse(space.bounds.intersects(reserved[0].bounds), "free space never covers an answer space")
            XCTAssertFalse(space.bounds.intersects(objects[0].bounds))
        }
        XCTAssertTrue(layout.free.contains { $0.near != nil })
        XCTAssertTrue(layout.free.contains { !$0.visible }, "spaces below the viewport are off screen")
        XCTAssertEqual(layout.free.map(\.id), (1...layout.free.count).map { "free_\($0)" })
    }

    // MARK: Relations

    func testRelationsTagNewLatestAnswerSpaceAndQuestion() {
        let objects = [
            PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "1. Add 2 + 2", bounds: CGRect(x: 40, y: 40, width: 200, height: 20)),
            PageObject(id: "vec_1", source: .printed, kind: "blank", bounds: CGRect(x: 40, y: 120, width: 200, height: 1)),
            PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "4", bounds: CGRect(x: 60, y: 96, width: 16, height: 22)),
            PageObject(id: "ink_2", source: .studentInk, kind: "handwriting", text: "old", bounds: CGRect(x: 400, y: 300, width: 40, height: 20)),
        ]
        let timing = ["ink_1": PageRelations.InkTiming(start: 200, end: 201), "ink_2": PageRelations.InkTiming(start: 10, end: 11)]
        let tagged = PageRelations.annotate(objects, timing: timing, lastTurn: 100, inkHeight: 20)
        let ink1 = tagged.first { $0.id == "ink_1" }!.tags ?? []
        let ink2 = tagged.first { $0.id == "ink_2" }!.tags ?? []
        XCTAssertTrue(ink1.contains("new"))
        XCTAssertTrue(ink1.contains("latest"))
        XCTAssertTrue(ink1.contains("in vec_1"))
        XCTAssertTrue(ink1.contains("answers txt_1"))
        XCTAssertFalse(ink2.contains("new"), "drawn before the agent's last turn")
        XCTAssertFalse(ink2.contains("latest"))
    }

    func testRelationsCrossingOutAndWorking() {
        let objects = [
            PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "x = 5", bounds: CGRect(x: 100, y: 100, width: 80, height: 20)),
            PageObject(id: "ink_2", source: .studentInk, kind: "shape", text: "line", bounds: CGRect(x: 95, y: 108, width: 90, height: 4)),
            PageObject(id: "ink_3", source: .studentInk, kind: "handwriting", text: "2x = 8", bounds: CGRect(x: 100, y: 200, width: 80, height: 20)),
            PageObject(id: "ink_4", source: .studentInk, kind: "handwriting", text: "x = 4", bounds: CGRect(x: 102, y: 228, width: 70, height: 20)),
        ]
        let timing = ["ink_1": PageRelations.InkTiming(start: 1, end: 2), "ink_2": PageRelations.InkTiming(start: 5, end: 6),
                      "ink_3": PageRelations.InkTiming(start: 7, end: 8), "ink_4": PageRelations.InkTiming(start: 9, end: 10)]
        let tagged = Dictionary(uniqueKeysWithValues: PageRelations.annotate(objects, timing: timing, lastTurn: nil, inkHeight: 20)
            .map { ($0.id, $0.tags ?? []) })
        XCTAssertTrue(tagged["ink_1"]!.contains("crossed out"))
        XCTAssertTrue(tagged["ink_2"]!.contains("strikes ink_1"))
        XCTAssertTrue(tagged["ink_3"]!.contains("work_1 step 1/2"))
        XCTAssertTrue(tagged["ink_4"]!.contains("work_1 step 2/2"))
        XCTAssertFalse(tagged["ink_1"]!.contains { $0.hasPrefix("work_") }, "crossed-out lines aren't working")
    }

    func testAnUnderlineDrawnFirstIsNotAStrike() {
        let objects = [
            PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "title", bounds: CGRect(x: 100, y: 100, width: 80, height: 20)),
            PageObject(id: "ink_2", source: .studentInk, kind: "shape", text: "line", bounds: CGRect(x: 95, y: 108, width: 90, height: 4)),
        ]
        let timing = ["ink_1": PageRelations.InkTiming(start: 5, end: 6), "ink_2": PageRelations.InkTiming(start: 1, end: 2)]
        let tagged = PageRelations.annotate(objects, timing: timing, lastTurn: nil, inkHeight: 20)
        XCTAssertFalse(tagged[0].tags?.contains("crossed out") ?? false)
    }

    func testQuestionNumbers() {
        for q in ["1. Add these", "12) Solve", "(b) Explain", "Q3 Find x", "Question 4", "a. Label the parts"] {
            XCTAssertTrue(PageRelations.isQuestion(q), q)
        }
        for t in ["The cell", "e.g. this", "1999 was a year", ""] { XCTAssertFalse(PageRelations.isQuestion(t), t) }
    }

    // MARK: Vector shapes

    private func line(_ a: CGPoint, _ b: CGPoint, width: CGFloat = 1) -> PDFContentScanner.PaintedPath {
        PDFContentScanner.PaintedPath(subpaths: [[a, b]], stroked: true, filled: false, isRect: false, lineWidth: width)
    }

    private func rect(_ r: CGRect) -> PDFContentScanner.PaintedPath {
        PDFContentScanner.PaintedPath(subpaths: [VectorShapes.rectOutline(r) + [r.origin]], stroked: true, filled: false,
                                      isRect: true, lineWidth: 1)
    }

    func testVectorShapesClassifiesLinesBoxesAndDrawings() {
        let text = [PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "Heading", bounds: CGRect(x: 50, y: 30, width: 100, height: 14))]
        var scan = PDFContentScanner.Result()
        scan.paths = [
            line(CGPoint(x: 50, y: 46), CGPoint(x: 150, y: 46)),             // under the heading
            line(CGPoint(x: 60, y: 200), CGPoint(x: 200, y: 200)),           // an answer blank
            line(CGPoint(x: 20, y: 300), CGPoint(x: 580, y: 300)),           // a rule across the page
            rect(CGRect(x: 300, y: 100, width: 120, height: 60)),            // a box
            rect(CGRect(x: 450, y: 100, width: 12, height: 12)),             // a checkbox
            PDFContentScanner.PaintedPath(subpaths: [[CGPoint(x: 100, y: 400), CGPoint(x: 150, y: 450), CGPoint(x: 200, y: 400)]],
                                          stroked: true, filled: false, isRect: false, lineWidth: 1), // a diagram
        ]
        let objects = VectorShapes.objects(scan, pageSize: CGSize(width: 600, height: 800), textLines: text)
        func kind(at p: CGPoint) -> PageObject? { objects.first { $0.bounds.insetBy(dx: -2, dy: -2).contains(p) } }
        XCTAssertEqual(kind(at: CGPoint(x: 100, y: 46))?.kind, "underline")
        XCTAssertEqual(kind(at: CGPoint(x: 100, y: 46))?.parent, "txt_1")
        XCTAssertEqual(kind(at: CGPoint(x: 100, y: 200))?.kind, "blank")
        XCTAssertEqual(kind(at: CGPoint(x: 300, y: 300))?.kind, "rule")
        XCTAssertEqual(kind(at: CGPoint(x: 360, y: 101))?.kind, "box")
        XCTAssertEqual(kind(at: CGPoint(x: 456, y: 106))?.kind, "checkbox")
        let drawing = objects.first { $0.kind == "drawing" }
        XCTAssertNotNil(drawing)
        XCTAssertEqual(drawing?.paths?.first?.count, 3, "a drawing keeps its lines for tracing")
        XCTAssertEqual(objects.filter { $0.parent == nil || $0.kind == "underline" }.map(\.id).sorted(),
                       (1...objects.count).map { "vec_\($0)" }.sorted())
    }

    func testVectorShapesFindsTablesAndCells() {
        var scan = PDFContentScanner.Result()
        for y in [100.0, 140, 180] { scan.paths.append(line(CGPoint(x: 100, y: y), CGPoint(x: 400, y: y))) }
        for x in [100.0, 250, 400] { scan.paths.append(line(CGPoint(x: x, y: 100), CGPoint(x: x, y: 180))) }
        let text = [PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "Name", bounds: CGRect(x: 110, y: 110, width: 50, height: 14))]
        let objects = VectorShapes.objects(scan, pageSize: CGSize(width: 600, height: 800), textLines: text)
        let table = objects.first { $0.kind == "table" }
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.text, "2×2 cells")
        let cells = objects.filter { $0.kind == "cell" }
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells.first { $0.id == "\(table!.id).r1c1" }?.text, "Name")
        XCTAssertEqual(cells.first { $0.id == "\(table!.id).r2c2" }?.bounds, CGRect(x: 250, y: 140, width: 150, height: 40))
    }

    func testVectorShapesScaleWithThePage() {
        // A PDF page shown 1.8 times bigger: a 1.5 pt rule becomes 2.7 page points thick and is still a line.
        var scan = PDFContentScanner.Result()
        scan.paths = [line(CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 200), width: 2.7)]
        let objects = VectorShapes.objects(scan, pageSize: CGSize(width: 1100, height: 1400), textLines: [], scale: 1.8)
        XCTAssertEqual(objects.first?.kind, "blank")
    }

    // MARK: The PDF frame

    func testPageFrameWithAnOffsetBox() {
        let frame = PageFrame(box: CGRect(x: 30, y: 40, width: 600, height: 800))
        XCTAssertEqual(frame.size, CGSize(width: 600, height: 800))
        XCTAssertEqual(frame.point(CGPoint(x: 30, y: 840)), CGPoint(x: 0, y: 0), "the box's top-left is the page's origin")
        XCTAssertEqual(frame.rect(CGRect(x: 130, y: 740, width: 50, height: 20)), CGRect(x: 100, y: 80, width: 50, height: 20))
    }

    func testPageFrameScalesToTheNoteWidth() {
        let frame = PageFrame(box: CGRect(x: 0, y: 0, width: 550, height: 800), width: 1100)
        XCTAssertEqual(frame.scale, 2)
        XCTAssertEqual(frame.size, CGSize(width: 1100, height: 1600))
        XCTAssertEqual(frame.point(CGPoint(x: 100, y: 700)), CGPoint(x: 200, y: 200))
    }

    func testPageFrameWithARotatedPage() {
        // /Rotate 90 shows a portrait page as landscape: its bottom-left corner ends up at the top-left.
        let frame = PageFrame(box: CGRect(x: 0, y: 0, width: 600, height: 800), rotation: 90)
        XCTAssertEqual(frame.size.width, 800, accuracy: 0.001)
        XCTAssertEqual(frame.size.height, 600, accuracy: 0.001)
        let corner = frame.point(.zero)
        XCTAssertEqual(corner.x, 0, accuracy: 0.001)
        XCTAssertEqual(corner.y, 0, accuracy: 0.001)
        let topLeft = frame.point(CGPoint(x: 0, y: 800))
        XCTAssertEqual(topLeft.x, 800, accuracy: 0.001, "the page's top-left ends up at the top-right")
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.001)
    }

    // MARK: Snapping

    private func snapshot(_ objects: [PageObject], free: [FreeSpace] = [], size: CGSize = CGSize(width: 1100, height: 800)) -> PageMapSnapshot {
        PageMapSnapshot(pageSize: size, objects: objects, freeSpaces: free)
    }

    private let figure = PageObject(id: "img_1", source: .printed, kind: "figure", bounds: CGRect(x: 100, y: 100, width: 500, height: 400))
    private let word = PageObject(id: "txt_1.w2", source: .pdfText, kind: "word", text: "cells", bounds: CGRect(x: 700, y: 100, width: 50, height: 18),
                                  parent: "txt_1")
    private let line = PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "All cells divide", bounds: CGRect(x: 650, y: 100, width: 160, height: 18))

    func testABoxThatMatchesAnObjectSnapsToIt() {
        let map = snapshot([figure]).map
        let r = map.resolve(target: .box(CGRect(x: 95, y: 110, width: 510, height: 380)))
        XCTAssertEqual(r?.objectID, "img_1")
        XCTAssertTrue(r?.snapped ?? false)
    }

    func testABoxInsideABigObjectStaysRaw() {
        let map = snapshot([figure]).map
        let box = CGRect(x: 150, y: 150, width: 80, height: 60)
        let r = map.resolve(target: .box(box))
        XCTAssertNil(r?.objectID)
        XCTAssertEqual(r?.bounds, box)
        XCTAssertTrue(r?.note.contains("inside img_1") ?? false)
    }

    func testPointsSnapOnlyToSmallObjects() {
        let map = snapshot([figure, word, line]).map
        XCTAssertNil(map.resolve(target: .point(CGPoint(x: 300, y: 300)))?.objectID, "a point on a big figure stays a point")
        XCTAssertEqual(map.resolve(target: .point(CGPoint(x: 720, y: 108)))?.objectID, "txt_1.w2")
    }

    func testWordsAndPhrasesInsideALine() {
        let words = [
            PageObject(id: "txt_1.w1", source: .pdfText, kind: "word", text: "All", bounds: CGRect(x: 650, y: 100, width: 40, height: 18), parent: "txt_1"),
            word,
            PageObject(id: "txt_1.w3", source: .pdfText, kind: "word", text: "divide.", bounds: CGRect(x: 760, y: 100, width: 50, height: 18), parent: "txt_1"),
        ]
        let map = snapshot([line] + words).map
        XCTAssertEqual(map.resolve(target: .id("txt_1", match: "Cells"))?.objectID, "txt_1.w2")
        XCTAssertEqual(map.resolve(target: .id("txt_1", match: "divide"))?.objectID, "txt_1.w3", "punctuation doesn't matter")
        XCTAssertEqual(map.resolve(target: .id("txt_1", match: "cells divide"))?.bounds, CGRect(x: 700, y: 100, width: 110, height: 18))
        XCTAssertEqual(map.resolve(target: .id("txt_1", match: "mitosis"))?.objectID, "txt_1", "no such word: the whole line")
        XCTAssertNil(map.resolve(target: .id("txt_9")))
    }

    func testTargetsAfterExtendingThePage() {
        let map = snapshot([]).map
        let below = map.resolve(target: .box(CGRect(x: 100, y: 900, width: 200, height: 50)), pageSize: CGSize(width: 1100, height: 1200))
        XCTAssertEqual(below?.bounds, CGRect(x: 100, y: 900, width: 200, height: 50), "the new space isn't clamped away")
        let clamped = map.resolve(target: .box(CGRect(x: 100, y: 900, width: 200, height: 50)))
        XCTAssertEqual(clamped?.bounds.height, 0, "without the new size it's past the bottom")
        XCTAssertEqual(map.resolve(target: .point(CGPoint(x: 10, y: 1000)), pageSize: CGSize(width: 1100, height: 1200))?.bounds.minY, 1000)
    }

    func testFreeSpacesResolveAsFreeSpaces() {
        let free = FreeSpace(id: "free_1", bounds: CGRect(x: 600, y: 300, width: 300, height: 200), near: "right of img_1", visible: true)
        let r = snapshot([figure], free: [free]).map.resolve(target: .id("free_1"))
        XCTAssertTrue(r?.isFreeSpace ?? false)
        XCTAssertEqual(r?.bounds, free.bounds)
    }

    // MARK: Placement

    func testPlacementBesideTheAnchorAvoidsDrawnPixels() {
        let page = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let anchor = CGRect(x: 100, y: 100, width: 100, height: 30)
        // Something drawn (that no parser saw) right of the anchor.
        let grid = OccupancyGrid(size: page.size).marking([CGRect(x: 205, y: 60, width: 300, height: 120)])
        let found = Placement.find(size: CGSize(width: 120, height: 40), near: anchor, side: .right, page: page, obstacles: [anchor],
                                   occupancy: grid)
        XCTAssertNotNil(found)
        XCTAssertTrue(grid.isFree(found!.rect))
        XCTAssertFalse(found!.rect.intersects(anchor))
        let blind = Placement.find(size: CGSize(width: 120, height: 40), near: anchor, side: .right, page: page, obstacles: [anchor])
        XCTAssertEqual(blind?.side, .right, "without the grid it would have written over the drawing")
        XCTAssertFalse(grid.isFree(blind!.rect))
    }

    // MARK: The validator

    private func context(_ objects: [PageObject] = [], free: [FreeSpace] = [], grid: OccupancyGrid? = nil) -> ActionValidator.ToolContext {
        var s = snapshot(objects, free: free)
        s.occupancy = grid
        return ActionValidator.ToolContext(snapshot: s, marks: [])
    }

    func testWriteInsideAFreeSpaceStacksDownward() {
        let free = FreeSpace(id: "free_1", bounds: CGRect(x: 600, y: 300, width: 400, height: 300), near: nil, visible: true)
        var c = context(free: [free])
        let first = ActionValidator.validate("write", input: ["text": "first", "near": ["id": "free_1"]], context: &c)
        let second = ActionValidator.validate("write", input: ["text": "second", "near": ["id": "free_1"]], context: &c)
        XCTAssertFalse(first.isError, first.result)
        XCTAssertFalse(second.isError, second.result)
        let a = first.marks[0].bounds, b = second.marks[0].bounds
        XCTAssertTrue(free.bounds.contains(a))
        XCTAssertTrue(free.bounds.contains(b))
        XCTAssertGreaterThan(b.minY, a.minY, "later writes go under earlier ones")
        XCTAssertTrue(first.result.contains("am_1"))
        XCTAssertTrue(second.result.contains("am_2"))
    }

    func testWriteAtMovesOffTheirInk() {
        let ink = PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "x", bounds: CGRect(x: 400, y: 400, width: 120, height: 40))
        var c = context([ink])
        let d = ActionValidator.validate("write", input: ["text": "here", "at": [460, 420]], context: &c)
        XCTAssertFalse(d.isError, d.result)
        XCTAssertFalse(d.marks[0].bounds.intersects(ink.bounds), d.result)
        XCTAssertTrue(d.result.contains("moved"))
    }

    func testNothingGoesUnderTheControls() {
        let free = FreeSpace(id: "free_1", bounds: CGRect(x: 0, y: 0, width: 1100, height: 800), near: nil, visible: true)
        var c = context(free: [free])
        let back = CGRect(x: 0, y: 0, width: 1100, height: 90) // The top controls, edge to edge.
        c.chrome = [back]
        let inside = ActionValidator.validate("write", input: ["text": "(x + 1)² = x² + 2x + 1", "near": ["id": "free_1"]], context: &c)
        XCTAssertFalse(inside.isError, inside.result)
        XCTAssertFalse(inside.marks[0].bounds.intersects(back), inside.result)
        let exact = ActionValidator.validate("write", input: ["text": "x = 2", "at": [60, 40]], context: &c)
        XCTAssertFalse(exact.marks[0].bounds.intersects(back), exact.result)
        let drawing = ActionValidator.validate("draw", input: ["size": [200, 100], "at": [20, 10],
                                                               "shapes": [["type": "circle", "center": [50, 50], "r": 30]]], context: &c)
        XCTAssertFalse(drawing.marks[0].bounds.intersects(back), drawing.result)
    }

    func testWritingSizeMatchesTheLandingPage() {
        let ink = PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "x² = 4", bounds: CGRect(x: 200, y: 200, width: 400, height: 160))
        var s = snapshot([ink])
        s.studentInkHeight = 160 // Big writing doesn't make the agent's big.
        var c = ActionValidator.ToolContext(snapshot: s, marks: [])
        let d = ActionValidator.validate("write", input: ["text": "2 × 2 = 4", "near": ["id": "ink_1"]], context: &c)
        guard case .text(let t)? = d.marks.first?.items.first else { return XCTFail(d.result) }
        XCTAssertEqual(t.size, 24)
        XCTAssertGreaterThan(d.marks[0].bounds.minX, ink.bounds.maxX, "to the right of their work")
    }

    func testHandwritingIsWrittenLetterByLetter() {
        let line = HandwritingLine.make("2 × 2 = 4", size: 24)
        XCTAssertEqual(line.letters.count, 5, "spaces have no ink")
        var last = -CGFloat.infinity
        for p in stride(from: 0.0, through: 1.0, by: 0.02) {
            let x = line.reveal(at: p)
            XCTAssertGreaterThanOrEqual(x, last, "the ink only ever grows")
            last = x
        }
        let tip = line.tip(at: line.letters[2].start + 0.01)
        XCTAssertLessThan(abs(tip.x - line.letters[2].minX), 24, "the pen is at the letter it's writing")
    }

    func testMarkCursorStartsAndEndsOnItsInk() {
        let a = AgentStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)])
        let b = AgentStroke(points: [CGPoint(x: 0, y: 50), CGPoint(x: 100, y: 50)])
        let mark = AgentMark(turn: UUID(), kind: "drawing", items: [.stroke(a), .stroke(b)])
        XCTAssertEqual(mark.tip(at: 0), CGPoint(x: 0, y: 0))
        XCTAssertEqual(mark.tip(at: 1), CGPoint(x: 100, y: 50))
        XCTAssertEqual(mark.duration, AgentInk.stroke(a).duration + AgentInk.stroke(b).duration + AgentMark.penLift, accuracy: 0.0001)
    }

    func testAPageNeverGrows() {
        var c = context(grid: OccupancyGrid(size: CGSize(width: 1100, height: 800)).marking([CGRect(x: 0, y: 0, width: 1100, height: 800)]))
        let d = ActionValidator.validate("write", input: ["text": "no room", "near": ["box": [100, 100, 50, 50]]], context: &c)
        XCTAssertTrue(d.overflow, d.result)
        XCTAssertTrue(d.marks.isEmpty)
        XCTAssertEqual(c.pageSize.height, 800)
        XCTAssertTrue(ActionValidator.validate("extend_page", input: ["height": 300], context: &c).isError)
        XCTAssertEqual(c.pageSize.height, 800)
    }

    func testADrawingShrinksToFitBeforeItOverflows() {
        // Only the top-left 300×220 is free: a 360×260 drawing fits there at 70%.
        let full = CGRect(x: 0, y: 0, width: 1100, height: 800)
        let busy = [CGRect(x: 0, y: 260, width: 1100, height: 540), CGRect(x: 340, y: 0, width: 760, height: 260)]
        var c = context(grid: OccupancyGrid(size: full.size).marking(busy))
        let shapes: JSONValue = [["type": "rect", "box": [0, 0, 360, 260]]]
        let d = ActionValidator.validate("draw", input: ["shapes": shapes, "size": [360, 260], "near": ["box": [20, 20, 10, 10]]],
                                         context: &c)
        XCTAssertFalse(d.isError, d.result)
        XCTAssertFalse(d.overflow)
        XCTAssertTrue(d.result.contains("shrunk"), d.result)
        let b = d.marks[0].bounds
        XCTAssertLessThan(b.width, 340)
        XCTAssertLessThan(b.maxY, 262)
        XCTAssertEqual(c.pageSize.height, 800)

        var full2 = context(grid: OccupancyGrid(size: full.size).marking([full]))
        let none = ActionValidator.validate("draw", input: ["shapes": shapes, "near": ["box": [20, 20, 10, 10]]], context: &full2)
        XCTAssertTrue(none.overflow, none.result)
    }

    func testAScratchPageFillsFromTheTop() {
        var c = ActionValidator.ToolContext(snapshot: PageMapSnapshot(pageSize: CGSize(width: 1100, height: 800)), marks: [])
        c.scratch = true
        c.chrome = [CGRect(x: 0, y: 0, width: 1100, height: 80)]
        let first = ActionValidator.validate("write", input: ["text": "x = 2", "near": ["id": "ink_9"]], context: &c)
        let second = ActionValidator.validate("write", input: ["text": "x = -2", "near": ["id": "ink_9"]], context: &c)
        XCTAssertFalse(first.isError, first.result)
        XCTAssertGreaterThan(first.marks[0].bounds.minY, 80, "clear of the controls")
        XCTAssertLessThan(first.marks[0].bounds.minY, 200, "at the top")
        XCTAssertGreaterThan(second.marks[0].bounds.minY, first.marks[0].bounds.minY, "the next one goes under it")
    }

    func testTheStrokeEraserTakesWholePiecesThePixelEraserCuts() {
        let line = AgentInk.stroke(AgentStroke(points: [CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 0)]))
        let a = CGPoint(x: 100, y: -20), b = CGPoint(x: 100, y: 20)
        XCTAssertEqual(AgentEraser.erase(line, from: a, to: b, radius: 5, pixel: false), [])
        let cut = AgentEraser.erase(line, from: a, to: b, radius: 5, pixel: true)
        XCTAssertEqual(cut.count, 2, "two pieces either side of the cut")
        let missed = AgentEraser.erase(line, from: CGPoint(x: 100, y: 30), to: CGPoint(x: 120, y: 40), radius: 5, pixel: true)
        XCTAssertEqual(missed, [line])
        let words = AgentInk.text(AgentText(text: "x = 2", center: CGPoint(x: 300, y: 300), size: 24))
        // Writing loses only the letters the pixel eraser crosses: through the "=", the "x" and the "2" stay.
        let left = AgentEraser.erase(words, from: CGPoint(x: 300, y: 300), to: CGPoint(x: 302, y: 300), radius: 5, pixel: true)
        XCTAssertEqual(left.compactMap { if case .text(let t) = $0 { t.text } else { nil } }, ["x", "2"])
    }

    func testMarksAndTheirTargets() {
        let ink = PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "12", bounds: CGRect(x: 400, y: 400, width: 60, height: 30))
        var c = context([ink])
        let circle = ActionValidator.validate("mark", input: ["kind": "circle", "target": ["id": "ink_1"]], context: &c)
        XCTAssertEqual(circle.marks.first?.target, "ink_1")
        XCTAssertTrue(circle.marks[0].bounds.contains(ink.bounds))
        let tick = ActionValidator.validate("mark", input: ["kind": "check", "target": ["id": "ink_1"]], context: &c)
        XCTAssertGreaterThan(tick.marks[0].bounds.minX, ink.bounds.maxX, "ticks go to the right")
        let arrow = ActionValidator.validate("mark", input: ["kind": "arrow", "target": ["id": "ink_1"]], context: &c)
        XCTAssertTrue(arrow.isError)
        let unknown = ActionValidator.validate("mark", input: ["kind": "circle", "target": ["id": "ink_9"]], context: &c)
        XCTAssertTrue(unknown.isError)
        XCTAssertTrue(unknown.result.contains("ink_9"))
    }

    func testTracingFollowsTheObjectsOwnLines() {
        let drawing = PageObject(id: "vec_1", source: .printed, kind: "drawing", bounds: CGRect(x: 100, y: 100, width: 200, height: 100),
                                 paths: [[CGPoint(x: 100, y: 200), CGPoint(x: 200, y: 100), CGPoint(x: 300, y: 200)]])
        var c = context([drawing])
        let d = ActionValidator.validate("outline_region", input: ["target": ["id": "vec_1"], "color": "orange"], context: &c)
        XCTAssertFalse(d.isError, d.result)
        guard case .stroke(let s)? = d.marks.first?.items.first else { return XCTFail("no stroke") }
        XCTAssertEqual(s.points, drawing.paths![0])
        XCTAssertEqual(s.color, "#C93400")
    }

    func testEraseByMarkID() {
        let mark = AgentMark(turn: UUID(), kind: "note", items: [.text(AgentText(text: "hi", center: CGPoint(x: 100, y: 100), size: 28))])
        var s = snapshot([])
        s.agentMarks = [AgentMarkSummary(id: "am_1", kind: "note", text: "hi", bounds: mark.bounds)]
        var c = ActionValidator.ToolContext(snapshot: s, marks: [mark])
        XCTAssertEqual(ActionValidator.validate("erase_marks", input: ["ids": ["am_1"]], context: &c).erase, [mark.id])
        XCTAssertTrue(ActionValidator.validate("erase_marks", input: ["ids": ["am_7"]], context: &c).isError)
    }

    func testDrawConnectsShapesByID() {
        var c = context()
        let d = ActionValidator.validate("draw", input: [
            "size": [300, 200], "near": ["box": [100, 100, 10, 10]],
            "shapes": [
                ["type": "circle", "id": "a", "center": [50, 100], "r": 30],
                ["type": "rect", "id": "b", "box": [200, 70, 80, 60]],
                ["type": "arrow", "from": "a", "to": "b", "label": "goes"],
                ["type": "label", "text": "start", "for": "a"],
            ],
        ], context: &c)
        XCTAssertFalse(d.isError, d.result)
        XCTAssertEqual(d.marks.count, 1)
        let texts = d.marks[0].items.compactMap { if case .text(let t) = $0 { t.text } else { nil } }
        XCTAssertEqual(Set(texts), ["goes", "start"])
        let bad = ActionValidator.validate("draw", input: ["shapes": [["type": "circle", "id": "a", "center": [50, 50], "r": 20],
                                                                    ["type": "arrow", "from": "a", "to": "nowhere"]]], context: &c)
        XCTAssertTrue(bad.isError)
        XCTAssertTrue(bad.result.contains("nowhere"), bad.result)
    }

    func testTheTurnHasABudget() {
        var c = context()
        c.drawn = ActionValidator.budget
        XCTAssertTrue(ActionValidator.validate("write", input: ["text": "more", "near": ["box": [10, 10, 10, 10]]], context: &c).isError)
    }

    // MARK: Text block

    func testTextBlockListsLinesFreeSpaceAndMarks() {
        var s = snapshot([line, word,
                          PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "4", bounds: CGRect(x: 60, y: 96, width: 16, height: 22),
                                     confidence: 0.4, tags: ["new"])],
                         free: [FreeSpace(id: "free_1", bounds: CGRect(x: 600, y: 300, width: 300, height: 200), near: "below txt_1", visible: false)])
        s.agentMarks = [AgentMarkSummary(id: "am_1", kind: "circle", bounds: .zero, target: "ink_1")]
        let block = PageMapText.block(s)
        XCTAssertTrue(block.contains("txt_1"))
        XCTAssertFalse(block.contains("txt_1.w2"), "words aren't listed")
        XCTAssertTrue(block.contains("handwriting \"4\" (unsure) [new]"))
        XCTAssertTrue(block.contains("free_1   600,300,300,200 · below txt_1 · off screen"))
        XCTAssertTrue(block.contains("am_1 circle around ink_1"))
    }

    // MARK: Saved pages

    func testPagesSavedBeforeMarksStillOpen() throws {
        var page = NotePage()
        page.agentMarks = [AgentMark(turn: UUID(), kind: "check", items: [.stroke(AgentStroke(points: [.zero, CGPoint(x: 5, y: 5)]))])]
        let data = try JSONEncoder().encode(page)
        XCTAssertEqual(try JSONDecoder().decode(NotePage.self, from: data), page)

        var old = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        old["agentMarks"] = nil
        let decoded = try JSONDecoder().decode(NotePage.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded.agentMarks, [])
        XCTAssertEqual(decoded.id, page.id)
    }

    func testStrokeIdentitySurvivesASaveAndLoad() throws {
        let points = (0..<5).map { PKStrokePoint(location: CGPoint(x: 10 + $0 * 5, y: 20), timeOffset: Double($0) * 0.01,
                                                 size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSinceReferenceDate: 1000)))
        let drawing = PKDrawing(strokes: [stroke])
        let reloaded = try PKDrawing(data: drawing.dataRepresentation())
        XCTAssertEqual(reloaded.strokes.first?.mapID, stroke.mapID)
    }
}
