import XCTest
@testable import Scribe

/// Worked steps carry marks on their own characters: the arrow that takes x³'s exponent to the front of 3x², a circle
/// on the −1, a stroke through what cancels.
final class StepAnnotationTests: XCTestCase {
    private func context() -> ActionValidator.ToolContext {
        let problem = PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "Differentiate x³",
                                 bounds: CGRect(x: 80, y: 100, width: 200, height: 24))
        let free = FreeSpace(id: "free_1", bounds: CGRect(x: 400, y: 80, width: 600, height: 600), near: nil, visible: true)
        return ActionValidator.ToolContext(snapshot: PageMapSnapshot(pageSize: CGSize(width: 1100, height: 800),
                                                                     objects: [problem], freeSpaces: [free]),
                                           marks: [])
    }

    private func strokes(_ mark: AgentMark) -> [AgentStroke] {
        mark.items.compactMap { if case .stroke(let s) = $0 { s } else { nil } }
    }

    private func texts(_ mark: AgentMark) -> [AgentText] {
        mark.items.compactMap { if case .text(let t) = $0 { t } else { nil } }
    }

    func testFindsTheInkOfASuperscript() throws {
        let line = AgentText(text: "x³", center: CGPoint(x: 300, y: 200), size: 26)
        let x = try XCTUnwrap(AgentGeometry.inkBox(of: "x", in: [line]))
        let cube = try XCTUnwrap(AgentGeometry.inkBox(of: "³", in: [line]))
        XCTAssertGreaterThan(cube.minX, x.midX, "the exponent comes after the x")
        XCTAssertLessThan(cube.midY, x.midY, "the exponent sits higher than the x")
        XCTAssertLessThan(cube.height, line.bounds.height)
        XCTAssertTrue(line.bounds.insetBy(dx: -4, dy: -4).contains(cube))
    }

    func testPicksTheNthRepeat() throws {
        let line = AgentText(text: "2x + 2", center: CGPoint(x: 300, y: 200), size: 26)
        let first = try XCTUnwrap(AgentGeometry.inkBox(of: "2", nth: 1, in: [line]))
        let second = try XCTUnwrap(AgentGeometry.inkBox(of: "2", nth: 2, in: [line]))
        XCTAssertGreaterThan(second.minX, first.maxX)
        XCTAssertNil(AgentGeometry.inkBox(of: "2", nth: 3, in: [line]))
    }

    func testThePowerRuleArrowRunsFromTheExponentToTheFront() throws {
        var c = context()
        let first = ActionValidator.validate("write", input: [
            "text": "x³", "size": "math", "near": ["id": "txt_1"], "side": "right",
        ], context: &c)
        XCTAssertFalse(first.isError, first.result)
        let second = ActionValidator.validate("write", input: [
            "text": "3x³⁻¹ = 3x²", "size": "math", "near": ["id": "am_1"], "side": "below",
            "annotate": [
                ["kind": "arrow", "from": ["text": "³", "in": "previous"], "to": ["text": "3"], "label": "to the front"],
                ["kind": "circle", "on": ["text": "⁻¹"], "label": "drop one"],
            ],
        ], context: &c)
        XCTAssertFalse(second.isError, second.result)
        XCTAssertFalse(second.result.contains("skipped"), second.result)

        let mark = try XCTUnwrap(second.marks.first)
        // The line, the arrow's shaft and head, its label, the circle and its label.
        XCTAssertEqual(texts(mark).map(\.text), ["3x³⁻¹ = 3x²", "to the front", "drop one"])
        XCTAssertEqual(strokes(mark).count, 3)

        let exponent = try XCTUnwrap(AgentGeometry.inkBox(of: "³", in: texts(first.marks[0])))
        let coefficient = try XCTUnwrap(AgentGeometry.inkBox(of: "3", in: [texts(mark)[0]]))
        let shaft = strokes(mark)[0].points
        let start = try XCTUnwrap(shaft.first), end = try XCTUnwrap(shaft.last)
        XCTAssertLessThan(hypot(start.x - exponent.midX, start.y - exponent.midY), 24, "starts at the exponent")
        XCTAssertLessThan(hypot(end.x - coefficient.midX, end.y - coefficient.midY), 24, "ends at the new coefficient")
        XCTAssertGreaterThan(end.y, start.y, "runs down to the next line")
        // Pen order: the step is written first, then the marks on it.
        guard case .text = mark.items[0] else { return XCTFail("the line comes first") }
    }

    func testAnArcWithinALineGetsRoomAboveIt() throws {
        var c = context()
        let d = ActionValidator.validate("write", input: [
            "text": "x³", "size": "math", "near": ["id": "txt_1"], "side": "right",
            "annotate": [["kind": "arrow", "from": ["text": "³"], "to": ["text": "x"], "label": "bring down"]],
        ], context: &c)
        XCTAssertFalse(d.isError, d.result)
        let mark = try XCTUnwrap(d.marks.first)
        let line = texts(mark)[0].bounds
        let arc = strokes(mark)[0].points
        XCTAssertLessThan(arc.map(\.y).min()!, line.minY, "it arcs over the line")
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 1100, height: 800).contains(mark.bounds))
        // The label sits over the arc, not on the line.
        XCTAssertLessThan(texts(mark)[1].bounds.maxY, line.minY + 4)
    }

    func testAMissingPartIsSkippedButTheStepIsWritten() throws {
        var c = context()
        let d = ActionValidator.validate("write", input: [
            "text": "3x²", "near": ["id": "txt_1"],
            "annotate": [["kind": "circle", "on": ["text": "7"]], ["kind": "box", "on": ["text": "3x²"]]],
        ], context: &c)
        XCTAssertFalse(d.isError, d.result)
        XCTAssertTrue(d.result.contains("skipped"), d.result)
        XCTAssertTrue(d.result.contains("“7”"), d.result)
        XCTAssertEqual(strokes(try XCTUnwrap(d.marks.first)).count, 1, "the box is still drawn")
    }

    func testStepsGoDownOneColumnWithArrowsBetweenAndTheAnswerBoxed() throws {
        var c = context()
        let d = ActionValidator.validate("steps", input: [
            "near": ["id": "txt_1"],
            "steps": [
                ["text": "x³"],
                ["text": "3x³⁻¹", "why": "bring the 3 down",
                 "annotate": [["kind": "arrow", "from": ["text": "³", "in": "previous"], "to": ["text": "3"]]]],
                ["text": "= 3x²", "why": "take one off", "annotate": [["kind": "circle", "on": ["text": "²"]]]],
            ],
        ], context: &c)
        XCTAssertFalse(d.isError, d.result)
        XCTAssertFalse(d.result.contains("skipped"), d.result)
        XCTAssertEqual(d.marks.count, 3, "each step is its own mark, written one after another")

        let lines = d.marks.map { texts($0).first { $0.size > 20 }! }
        XCTAssertEqual(lines.map(\.text), ["x³", "3x³⁻¹", "= 3x²"])
        for (above, below) in zip(lines, lines.dropFirst()) {
            XCTAssertGreaterThan(below.bounds.minY - above.bounds.maxY, 36, "room between steps for the arrow and why")
            XCTAssertEqual(above.bounds.minX, below.bounds.minX, accuracy: 1, "one column, left aligned")
        }
        // The arrow down and its why come before the step's line; the answer's box is green.
        XCTAssertTrue(texts(d.marks[1]).contains { $0.text == "bring the 3 down" && $0.color == ActionValidator.connectorColor })
        XCTAssertTrue(strokes(d.marks[2]).contains { $0.color == ActionValidator.answerColor && $0.closed })
        XCTAssertEqual(ActionValidator.answerPart(of: "= 3x²"), "3x²")
        // Nothing lands on the question.
        XCTAssertFalse(d.marks.contains { $0.bounds.intersects(CGRect(x: 80, y: 100, width: 200, height: 24)) })
    }

    func testStrikeAndUnderlineOnPrintedText() throws {
        var c = context()
        let d = ActionValidator.validate("write", input: [
            "text": "d/dx", "near": ["id": "txt_1"],
            "annotate": [["kind": "underline", "on": ["text": "x³", "in": "txt_1"]]],
        ], context: &c)
        XCTAssertFalse(d.isError, d.result)
        XCTAssertFalse(d.result.contains("skipped"), d.result)
        XCTAssertEqual(strokes(try XCTUnwrap(d.marks.first)).count, 1)
    }
}
