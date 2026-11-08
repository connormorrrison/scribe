import PDFKit
import SwiftUI
import XCTest
@testable import Scribe

/// The page map on a real PDF worksheet: printed text, an answer blank, a table, a box and a diagram, on a plain page
/// and on a rotated one. Checks that what the map says lines up with the pixels of the page as Scribe draws it.
@MainActor
final class WorksheetMapTests: XCTestCase {
    /// Where the worksheet's pieces are drawn, in PDF points from the top-left of a 612×792 page.
    private enum Sheet {
        static let size = CGSize(width: 612, height: 792)
        static let heading = CGPoint(x: 60, y: 60)
        static let question = CGPoint(x: 60, y: 120)
        static let blank = CGRect(x: 80, y: 180, width: 200, height: 0)
        static let table = CGRect(x: 60, y: 260, width: 300, height: 120)
        static let box = CGRect(x: 420, y: 260, width: 120, height: 80)
        static let triangle = [CGPoint(x: 100, y: 600), CGPoint(x: 220, y: 460), CGPoint(x: 340, y: 600)]
    }

    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("worksheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A two-page worksheet; the second page is the first, turned 90° by /Rotate.
    private func worksheet() throws -> URL {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: Sheet.size)).pdfData { ctx in
            for _ in 0..<2 {
                ctx.beginPage()
                let font = UIFont.systemFont(ofSize: 18, weight: .semibold)
                ("Fractions practice" as NSString).draw(at: Sheet.heading, withAttributes: [.font: font])
                ("1. What is 1/2 + 1/4?" as NSString).draw(at: Sheet.question, withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                let cg = ctx.cgContext
                cg.setStrokeColor(UIColor.black.cgColor)
                cg.setLineWidth(1)
                cg.move(to: Sheet.blank.origin)
                cg.addLine(to: CGPoint(x: Sheet.blank.maxX, y: Sheet.blank.minY))
                cg.strokePath()
                for i in 0...3 {
                    let y = Sheet.table.minY + CGFloat(i) * Sheet.table.height / 3
                    cg.move(to: CGPoint(x: Sheet.table.minX, y: y))
                    cg.addLine(to: CGPoint(x: Sheet.table.maxX, y: y))
                }
                for i in 0...3 {
                    let x = Sheet.table.minX + CGFloat(i) * Sheet.table.width / 3
                    cg.move(to: CGPoint(x: x, y: Sheet.table.minY))
                    cg.addLine(to: CGPoint(x: x, y: Sheet.table.maxY))
                }
                cg.strokePath()
                ("½" as NSString).draw(at: CGPoint(x: Sheet.table.minX + 10, y: Sheet.table.minY + 10),
                                       withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                cg.stroke(Sheet.box)
                cg.move(to: Sheet.triangle[0])
                cg.addCurve(to: Sheet.triangle[1], control1: CGPoint(x: 130, y: 540), control2: CGPoint(x: 180, y: 480))
                cg.addLine(to: Sheet.triangle[2])
                cg.strokePath()
            }
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        document.page(at: 1)?.rotation = 90
        let url = directory.appendingPathComponent("worksheet.pdf")
        XCTAssertTrue(document.write(to: url))
        return url
    }

    /// Page points per PDF point on a 612-wide page.
    private let k = NotePageMetrics.width / Sheet.size.width

    private func render(_ url: URL) -> (NotePage, CGFloat) -> UIImage? {
        { page, scale in PageRenderer.image(of: page, background: .none, pixelWidth: NotePageMetrics.width * scale, pdf: url) { _ in nil } }
    }

    func testTheMapLinesUpWithThePrintedPage() async throws {
        let url = try worksheet()
        let pages = PDFPages.notePages(from: url)
        XCTAssertEqual(pages.count, 2)
        let mapper = PageMapper(pdfURL: url)
        let snapshot = await mapper.snapshot(of: pages[0], render: render(url))
        let grid = try XCTUnwrap(snapshot.occupancy)
        let objects = snapshot.objects

        // Text: where it was drawn, scaled to the note page.
        let question = try XCTUnwrap(objects.first { $0.kind == "line" && ($0.text ?? "").hasPrefix("1.") })
        XCTAssertEqual(question.bounds.minX, Sheet.question.x * k, accuracy: 6)
        XCTAssertEqual(question.bounds.minY, Sheet.question.y * k, accuracy: 10)
        XCTAssertGreaterThan(grid.coverage(question.bounds), 0.2, "the picture has ink where the text is said to be")
        XCTAssertTrue(objects.contains { $0.kind == "word" && $0.text == "1/2" && $0.parent == question.id })

        // The answer blank, the table and its cells, the box and the diagram.
        let blank = try XCTUnwrap(objects.first { $0.kind == "blank" })
        XCTAssertEqual(blank.bounds.midY, Sheet.blank.minY * k, accuracy: 3)
        XCTAssertEqual(blank.bounds.minX, Sheet.blank.minX * k, accuracy: 3)
        XCTAssertFalse(grid.isFree(blank.bounds.insetBy(dx: 0, dy: -2)))
        let table = try XCTUnwrap(objects.first { $0.kind == "table" })
        XCTAssertEqual(table.text, "3×3 cells")
        XCTAssertEqual(table.bounds.minX, Sheet.table.minX * k, accuracy: 3)
        XCTAssertEqual(table.bounds.maxY, Sheet.table.maxY * k, accuracy: 3)
        XCTAssertEqual(objects.first { $0.id == "\(table.id).r1c1" }?.text, "½")
        let box = try XCTUnwrap(objects.first { $0.kind == "box" })
        XCTAssertEqual(box.bounds.minX, Sheet.box.minX * k, accuracy: 3)
        let drawing = try XCTUnwrap(objects.first { $0.kind == "drawing" })
        XCTAssertNotNil(drawing.paths)
        XCTAssertEqual(drawing.bounds.maxY, Sheet.triangle[0].y * k, accuracy: 4)

        // Free spaces are clear in the picture, and never on the answer blank's writing band.
        XCTAssertFalse(snapshot.freeSpaces.isEmpty)
        for space in snapshot.freeSpaces {
            XCTAssertTrue(grid.isFree(space.bounds), "\(space.id) is clear")
            XCTAssertFalse(space.bounds.intersects(CGRect(x: blank.bounds.minX, y: blank.bounds.minY - 30, width: blank.bounds.width, height: 30)))
        }

        try saveForReview(snapshot, url: url, page: pages[0], name: "worksheet")
    }

    func testARotatedPageLinesUpToo() async throws {
        let url = try worksheet()
        let pages = PDFPages.notePages(from: url)
        XCTAssertGreaterThan(pages[1].bounds.width, 0)
        XCTAssertLessThan(pages[1].height, NotePageMetrics.width, "a page turned on its side is landscape")
        let snapshot = await PageMapper(pdfURL: url).snapshot(of: pages[1], render: render(url))
        let grid = try XCTUnwrap(snapshot.occupancy)
        let lines = snapshot.objects.filter { $0.kind == "line" }
        XCTAssertFalse(lines.isEmpty)
        for line in lines {
            XCTAssertGreaterThan(grid.coverage(line.bounds), 0.1, "“\(line.text ?? "")” is where the picture has ink")
        }
        let table = try XCTUnwrap(snapshot.objects.first { $0.kind == "table" })
        XCTAssertFalse(grid.isFree(CGRect(x: table.bounds.minX - 2, y: table.bounds.midY, width: 4, height: 4)),
                       "the table's left edge is drawn where the map puts it")
        try saveForReview(snapshot, url: url, page: pages[1], name: "worksheet-rotated")
    }

    func testTheAgentDrawsOnTheWorksheet() async throws {
        let url = try worksheet()
        var page = PDFPages.notePages(from: url)[0]
        let snapshot = await PageMapper(pdfURL: url).snapshot(of: page, render: render(url))
        var context = ActionValidator.ToolContext(snapshot: snapshot, marks: [])
        let question = try XCTUnwrap(snapshot.objects.first { $0.kind == "line" && ($0.text ?? "").hasPrefix("1.") })
        let drawing = try XCTUnwrap(snapshot.objects.first { $0.kind == "drawing" })
        let calls: [(String, JSONValue)] = [
            ("mark", ["kind": "underline", "target": ["id": .string(question.id), "match": "1/2"]]),
            ("write", ["text": "make the bottoms match first", "near": ["id": .string(question.id)], "side": "right"]),
            ("outline_region", ["target": ["id": .string(drawing.id)], "color": "orange", "label": "a curve"]),
            ("write", ["text": "1/2 = 2/4", "size": "math", "near": ["id": "free_1"]]),
        ]
        for (tool, input) in calls {
            let d = ActionValidator.validate(tool, input: input, context: &context)
            XCTAssertFalse(d.isError, "\(tool): \(d.result)")
            page.agentMarks += d.marks
        }
        // Nothing the agent wrote sits on printed text.
        let text = snapshot.objects.filter { $0.source == .pdfText && $0.kind == "line" }
        for mark in page.agentMarks where mark.kind == "note" {
            XCTAssertFalse(text.contains { $0.bounds.intersects(mark.bounds) }, "“\(mark.text ?? "")” is clear of the printed text")
        }
        let after = await PageMapper(pdfURL: url).snapshot(of: page, render: render(url))
        XCTAssertEqual(after.agentMarks.map(\.id), (1...page.agentMarks.count).map { "am_\($0)" })
        XCTAssertTrue(PageMapText.block(after).contains("YOUR MARKS: am_1 underline"))
        try saveForReview(after, url: url, page: page, name: "worksheet-marked")
    }

    /// With SCRIBE_REVIEW_DIR set, saves the fixture and a picture of the page with the overlay, to check by eye.
    private func saveForReview(_ snapshot: PageMapSnapshot, url: URL, page: NotePage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["SCRIBE_REVIEW_DIR"] else { return }
        let root = URL(fileURLWithPath: path)
        let folder = try PageFixture.save(snapshot, name: name, in: root)
        let size = page.bounds.size
        let view = ZStack(alignment: .topLeading) {
            if let picture = render(url)(page, 1) { Image(uiImage: picture).resizable() }
            PageMapOverlay(snapshot: snapshot, scale: 1)
        }
        .frame(width: size.width, height: size.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1.5
        try XCTUnwrap(renderer.uiImage?.pngData()).write(to: folder.appendingPathComponent("overlay.png"))
    }
}
