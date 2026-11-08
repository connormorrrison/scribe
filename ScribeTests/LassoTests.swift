import PencilKit
import XCTest
@testable import Scribe

/// The lasso selects the ink inside its loop, and tells the agent what's in the region.
final class LassoTests: XCTestCase {
    private let square = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 100, y: 300)]

    private func stroke(from a: CGPoint, to b: CGPoint) -> PKStroke {
        let points = (0...20).map { i -> PKStrokePoint in
            let t = CGFloat(i) / 20
            return PKStrokePoint(location: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                                 timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1,
                                 force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
    }

    func testContainsPointsInsideTheLoopOnly() {
        XCTAssertTrue(LassoGeometry.contains(square, CGPoint(x: 200, y: 200)))
        XCTAssertFalse(LassoGeometry.contains(square, CGPoint(x: 50, y: 200)))
        XCTAssertFalse(LassoGeometry.contains(square, CGPoint(x: 200, y: 400)))
    }

    func testSelectsStrokesMostlyInside() {
        let drawing = PKDrawing(strokes: [
            stroke(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 250, y: 250)), // inside
            stroke(from: CGPoint(x: 400, y: 400), to: CGPoint(x: 500, y: 500)), // outside
            stroke(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 260, y: 200)), // inside
            stroke(from: CGPoint(x: 250, y: 200), to: CGPoint(x: 550, y: 200)), // mostly outside
        ])
        XCTAssertEqual(LassoGeometry.strokes(in: square, of: drawing), IndexSet([0, 2]))
    }

    func testFocusListsObjectsMostlyInsideTheRegion() {
        let snapshot = PageMapSnapshot(pageSize: CGSize(width: 1100, height: 850), objects: [
            PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "2x + 3 = 7",
                       bounds: CGRect(x: 120, y: 120, width: 120, height: 30)),
            PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "Solve for x",
                       bounds: CGRect(x: 90, y: 90, width: 400, height: 20)),
            PageObject(id: "txt_1.w1", source: .pdfText, kind: "word", text: "Solve",
                       bounds: CGRect(x: 110, y: 110, width: 40, height: 20)),
        ])
        let focus = LassoFocus(pageID: snapshot.pageID, bounds: CGRect(x: 100, y: 100, width: 200, height: 200),
                               action: .help(level: 1))
        let objects = focus.objects(in: snapshot)
        XCTAssertEqual(objects.map(\.id), ["ink_1"])
        let text = focus.instructions(objects: objects, style: .show)
        XCTAssertTrue(text.contains("ink_1 (handwriting) “2x + 3 = 7”"))
        XCTAssertTrue(text.contains("{\"box\": [100, 100, 200, 200]}"))
        // Help is line by line from the first press: the steps tool, all the way to the answer with Show Me.
        XCTAssertTrue(text.contains("always with the steps tool"))
        XCTAssertTrue(text.contains("all the way to the answer"))
        XCTAssertTrue(focus.instructions(objects: objects, style: .coach).contains("first step or two"))
    }

    func testHelpClimbsOnTheSameSpotAndStartsOverElsewhere() {
        var ladder = HelpLadder()
        let page = UUID()
        let spot = CGRect(x: 100, y: 100, width: 200, height: 120)
        XCTAssertEqual(ladder.level(for: page, bounds: spot), 1)
        ladder.climbed(to: 1, pageID: page, bounds: spot)
        // Lassoed again a little differently: still the same spot.
        let again = spot.offsetBy(dx: 20, dy: -10)
        XCTAssertEqual(ladder.level(for: page, bounds: again), 2)
        ladder.climbed(to: 2, pageID: page, bounds: again)
        ladder.climbed(to: 3, pageID: page, bounds: spot)
        XCTAssertEqual(ladder.level(for: page, bounds: spot), 3) // Stays at the top.
        XCTAssertEqual(ladder.level(for: page, bounds: CGRect(x: 600, y: 500, width: 100, height: 100)), 1)
        XCTAssertEqual(ladder.level(for: UUID(), bounds: spot), 1)
        XCTAssertEqual(LassoAction.help(level: 2).title, "More Help")
    }
}
