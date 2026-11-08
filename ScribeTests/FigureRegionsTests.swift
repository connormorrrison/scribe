import PDFKit
import SwiftUI
import XCTest
@testable import Scribe

/// Splitting figures into parts the agent can trace: continents of a map, the coloured areas inside one.
@MainActor
final class FigureRegionsTests: XCTestCase {
    private let sea: (UInt8, UInt8, UInt8) = (40, 100, 200)
    private let land: (UInt8, UInt8, UInt8) = (60, 170, 80)
    private let other: (UInt8, UInt8, UInt8) = (240, 150, 40)

    // MARK: Pixels alone

    func testTwoShapesJoinedByAThinNeckComeApart() {
        // Sea, with two blocks of land joined by a 2 px strip, and a white margin all round.
        let p = FigureRegions.Pixels(width: 300, height: 200) { x, y in
            if x < 10 || y < 10 || x >= 290 || y >= 190 { return (255, 255, 255) }
            let left = (40..<120).contains(x) && (40..<160).contains(y)
            let right = (180..<260).contains(x) && (40..<160).contains(y)
            let neck = (120..<180).contains(x) && (99..<101).contains(y)
            return left || right || neck ? self.land : self.sea
        }
        let parts = FigureRegions.split(p, scale: 1, origin: .zero)
        XCTAssertEqual(parts.count, 2, "the sea is background, and the neck is cut")
        let boxes = parts.map(\.bounds).sorted { $0.minX < $1.minX }
        XCTAssertEqual(boxes[0].minX, 40, accuracy: 1.5)
        XCTAssertEqual(boxes[0].minY, 40, accuracy: 1.5)
        XCTAssertEqual(boxes[0].maxY, 160, accuracy: 1.5)
        XCTAssertLessThan(boxes[0].maxX, 126, "only a stub of the neck stays")
        XCTAssertEqual(boxes[1].maxX, 260, accuracy: 1.5)
        XCTAssertTrue(parts.allSatisfy { $0.color == "green" })
        // The outline follows the block's edge.
        let left = parts.first { $0.bounds.minX < 100 }!
        XCTAssertTrue(PageMap.polygonContains(left.outline, CGPoint(x: 80, y: 100)))
        XCTAssertFalse(PageMap.polygonContains(left.outline, CGPoint(x: 30, y: 100)))
        XCTAssertEqual(left.area, 80 * 120, accuracy: 300)
    }

    func testAPartOfTwoColoursHasTwoAreas() {
        let p = FigureRegions.Pixels(width: 240, height: 160) { x, y in
            guard (40..<200).contains(x) && (40..<120).contains(y) else { return self.sea }
            return x < 100 ? self.other : self.land
        }
        let parts = FigureRegions.split(p, scale: 1, origin: CGPoint(x: 100, y: 50))
        XCTAssertEqual(parts.count, 1)
        let areas = parts[0].areas.sorted { $0.bounds.minX < $1.bounds.minX }
        XCTAssertEqual(areas.map(\.color), ["orange", "green"])
        XCTAssertEqual(areas[0].bounds.minX, 140, accuracy: 1.5, "in page points, from the origin")
        XCTAssertEqual(areas[1].bounds.maxX, 300, accuracy: 1.5)
    }

    func testAPlainDiagramOnWhiteIsNotPeeled() {
        // Black outlines of two shapes on white: the shapes are the parts, the white between them is background.
        let p = FigureRegions.Pixels(width: 200, height: 120) { x, y in
            let a = (20..<80).contains(x) && (20..<100).contains(y)
            let b = (120..<180).contains(x) && (20..<100).contains(y)
            let inside = ((24..<76).contains(x) && (24..<96).contains(y)) || ((124..<176).contains(x) && (24..<96).contains(y))
            if (a || b) && !inside { return (0, 0, 0) }
            return (255, 255, 255)
        }
        let parts = FigureRegions.split(p, scale: 1, origin: .zero)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].bounds.width, 60, accuracy: 1.5)
    }

    // MARK: A worksheet with a map

    /// A map picture: white margin, sea, "africa" joined to "asia" by a thin isthmus, an orange "europe" on asia, and
    /// an island.
    private func mapImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { ctx in
            let cg = ctx.cgContext
            func fill(_ c: (UInt8, UInt8, UInt8)) {
                cg.setFillColor(UIColor(red: CGFloat(c.0) / 255, green: CGFloat(c.1) / 255, blue: CGFloat(c.2) / 255, alpha: 1).cgColor)
            }
            UIColor.white.setFill()
            cg.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            fill(sea); cg.fill(CGRect(x: 20, y: 20, width: 560, height: 360))
            fill(land)
            cg.fillEllipse(in: Map.africa)
            cg.fillEllipse(in: Map.asia)
            cg.fill(CGRect(x: 225, y: 171, width: 90, height: 2))
            cg.fillEllipse(in: Map.island)
            fill(other)
            cg.saveGState()
            cg.addEllipse(in: Map.asia)
            cg.clip()
            cg.fill(CGRect(x: 0, y: 0, width: 360, height: 400))
            cg.restoreGState()
        }
    }

    private enum Map {
        static let africa = CGRect(x: 80, y: 120, width: 160, height: 200)
        static let asia = CGRect(x: 300, y: 60, width: 220, height: 160)
        static let island = CGRect(x: 500, y: 280, width: 40, height: 40)
        /// Where the picture sits on the 612×792 PDF page.
        static let placed = CGRect(x: 60, y: 200, width: 480, height: 320)
    }

    /// Page points for a point of the picture.
    private func page(_ p: CGPoint) -> CGPoint {
        let k = NotePageMetrics.width / 612
        return CGPoint(x: (Map.placed.minX + p.x * Map.placed.width / 600) * k, y: (Map.placed.minY + p.y * Map.placed.height / 400) * k)
    }

    private func worksheet() throws -> URL {
        let image = mapImage()
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { ctx in
            ctx.beginPage()
            ("Label the continents" as NSString).draw(at: CGPoint(x: 60, y: 80), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            image.draw(in: Map.placed)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("map-\(UUID().uuidString).pdf")
        try data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testEachContinentOfAMapIsItsOwnTraceablePart() async throws {
        let url = try worksheet()
        let notePage = try XCTUnwrap(PDFPages.notePages(from: url).first)
        let render: (NotePage, CGFloat) -> UIImage? = { page, scale in
            PageRenderer.image(of: page, background: .none, pixelWidth: NotePageMetrics.width * scale, pdf: url) { _ in nil }
        }
        let snapshot = await PageMapper(pdfURL: url).snapshot(of: notePage, render: render)
        let figure = try XCTUnwrap(snapshot.objects.first { $0.kind == "figure" })
        let parts = snapshot.objects.filter { $0.kind == "part" && $0.parent == figure.id }
        XCTAssertEqual(parts.count, 3, "africa, asia and the island; not the sea: \(parts.map { PageMap.format($0.bounds) })")

        // Africa: where it was drawn, to within a couple of points, though it touches asia by the isthmus.
        let topLeft = page(Map.africa.origin), bottomRight = page(CGPoint(x: Map.africa.maxX, y: Map.africa.maxY))
        let africa = try XCTUnwrap(parts.first { $0.bounds.contains(page(CGPoint(x: Map.africa.midX, y: Map.africa.midY))) })
        XCTAssertEqual(africa.bounds.minX, topLeft.x, accuracy: 2.5)
        XCTAssertEqual(africa.bounds.minY, topLeft.y, accuracy: 2.5)
        XCTAssertEqual(africa.bounds.maxY, bottomRight.y, accuracy: 2.5)
        // It keeps its half of the isthmus, no more.
        XCTAssertLessThan(africa.bounds.maxX, page(CGPoint(x: 270, y: 0)).x, "it stops halfway along the isthmus")
        XCTAssertEqual(africa.text, "green")
        let outline = try XCTUnwrap(africa.outline)
        XCTAssertGreaterThan(outline.count, 20, "a real outline, not a box")
        // Every outline point is on africa's edge.
        let c = page(CGPoint(x: Map.africa.midX, y: Map.africa.midY))
        let rx = bottomRight.x - c.x, ry = bottomRight.y - c.y
        let off = outline.filter { p in
            let e = pow((p.x - c.x) / rx, 2) + pow((p.y - c.y) / ry, 2)
            return abs(sqrt(e) - 1) > 0.04 && p.x < c.x + rx * 0.85
        }
        XCTAssertLessThan(off.count, outline.count / 20, "the outline follows the coast")

        // Asia carries its two coloured areas: "europe" and the rest.
        let asia = try XCTUnwrap(parts.first { $0.bounds.contains(page(CGPoint(x: Map.asia.midX, y: Map.asia.midY))) })
        let areas = snapshot.objects.filter { $0.kind == "area" && $0.parent == asia.id }
        XCTAssertEqual(Set(areas.compactMap(\.text)), ["orange", "green"])

        // The agent reads them under the figure, and none of them crowd the object list.
        let text = PageMapText.block(snapshot)
        XCTAssertTrue(text.contains("parts of \(figure.id)"))
        XCTAssertTrue(text.contains("areas of \(asia.id)"))
        XCTAssertFalse(text.contains("\n\(africa.id) "))

        // Tracing africa follows its outline; a point on europe snaps to europe's area.
        var context = ActionValidator.ToolContext(snapshot: snapshot, marks: [])
        let d = ActionValidator.validate("outline_region", input: [
            "targets": [["id": .string(africa.id)]], "color": "green", "label": "africa",
        ], context: &context)
        XCTAssertFalse(d.isError, d.result)
        XCTAssertTrue(d.result.contains("outline of \(africa.id)"), d.result)
        guard case .stroke(let ring) = try XCTUnwrap(d.marks.first?.items.first) else { return XCTFail("a stroke") }
        XCTAssertTrue(ring.closed)
        XCTAssertEqual(ring.points.count, outline.count)
        // The label goes on africa itself, like a map's.
        let labelled = d.marks.first?.items.compactMap { item -> AgentText? in
            if case .text(let t) = item { return t } else { return nil }
        }.first
        XCTAssertTrue(PageMap.polygonContains(outline, try XCTUnwrap(labelled).center), "the label is on africa")
        let europe = try XCTUnwrap(areas.first { $0.text == "orange" })
        let snapped = snapshot.map.resolve(target: .point(CGPoint(x: europe.bounds.midX, y: europe.bounds.midY)))
        XCTAssertEqual(snapped?.objectID, europe.id)

        // Several parts as one mark.
        let both = ActionValidator.validate("outline_region", input: [
            "targets": [["id": .string(asia.id)], ["id": .string(parts.first { $0.id != africa.id && $0.id != asia.id }!.id)]],
        ], context: &context)
        XCTAssertFalse(both.isError, both.result)
        XCTAssertEqual(both.marks.first?.items.count, 2)

        // With SCRIBE_REVIEW_DIR set: the page, its parts, and the traced marks, to check by eye.
        if let dir = ProcessInfo.processInfo.environment["SCRIBE_REVIEW_DIR"] {
            var marked = notePage
            marked.agentMarks = d.marks + both.marks
            let view = ZStack(alignment: .topLeading) {
                if let picture = render(marked, 1) { Image(uiImage: picture).resizable() }
                PageMapOverlay(snapshot: snapshot, scale: 1)
            }
            .frame(width: marked.bounds.width, height: marked.bounds.height)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1.5
            try renderer.uiImage?.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("map.png"))
        }
    }
}
