import CoreText
import XCTest
@testable import Scribe

/// The eraser takes single letters (pixel) or words (stroke) out of the agent's writing, leaving the rest in place.
final class AgentEraserTests: XCTestCase {
    private let line = AgentText(text: "the quick fox", center: CGPoint(x: 300, y: 200), size: 24)

    /// Where the character at `offset` sits along the line, in page points, and the line's baseline.
    private func characterMidX(_ offset: Int) -> CGFloat {
        let font = Handwriting.font(size: line.size)
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
        let width = CGFloat(CTLineGetTypographicBounds(ct, nil, nil, nil))
        let x0 = CTLineGetOffsetForStringIndex(ct, offset, nil), x1 = CTLineGetOffsetForStringIndex(ct, offset + 1, nil)
        return line.center.x - width / 2 + (x0 + x1) / 2
    }

    private var baseline: CGFloat {
        let font = Handwriting.font(size: line.size)
        return line.center.y - font.lineHeight / 2 + font.ascender
    }

    /// A short dab on the x-height of the character at `offset`.
    private func dab(_ offset: Int) -> (CGPoint, CGPoint) {
        let y = baseline - 5
        let x = characterMidX(offset) + 5 * HandwritingLine.slant
        return (CGPoint(x: x, y: y - 1), CGPoint(x: x, y: y + 1))
    }

    func testPixelEraserTakesOneLetter() {
        let (a, b) = dab(6) // the "i" in "quick"
        let left = AgentEraser.erase(line, from: a, to: b, radius: 0.5, wholeWords: false)
        XCTAssertEqual(left.map(\.text), ["the qu", "ck fox"])
    }

    func testStrokeEraserTakesTheWord() {
        let (a, b) = dab(6)
        let left = AgentEraser.erase(line, from: a, to: b, radius: 0.5, wholeWords: true)
        XCTAssertEqual(left.map(\.text), ["the", "fox"])
    }

    func testPiecesStayWhereTheyWere() {
        let (a, b) = dab(6)
        let left = AgentEraser.erase(line, from: a, to: b, radius: 0.5, wholeWords: true)
        XCTAssertEqual(left.count, 2)
        // Each piece's first letter starts where it did in the whole line.
        let start = { (t: AgentText) in t.center.x - Handwriting.width(of: t.text, size: t.size) / 2 }
        XCTAssertEqual(start(left[0]), start(line), accuracy: 0.5)
        let font = Handwriting.font(size: line.size)
        let ct = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: font]))
        let foxOffset = CTLineGetOffsetForStringIndex(ct, 10, nil)
        XCTAssertEqual(start(left[1]), start(line) + foxOffset, accuracy: 1)
        XCTAssertEqual(left[1].center.y, line.center.y)
    }

    func testMissingTheWritingLeavesItWhole() {
        let a = CGPoint(x: 300, y: 100), b = CGPoint(x: 320, y: 100)
        XCTAssertEqual(AgentEraser.erase(.text(line), from: a, to: b, radius: 4, pixel: true), [.text(line)])
    }

    func testErasingEveryWordLeavesNothing() {
        let a = CGPoint(x: 0, y: baseline - 5), b = CGPoint(x: 600, y: baseline - 5)
        XCTAssertTrue(AgentEraser.erase(line, from: a, to: b, radius: 2, wholeWords: false).isEmpty)
    }
}
