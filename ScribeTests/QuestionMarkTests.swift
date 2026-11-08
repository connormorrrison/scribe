import PencilKit
import XCTest
@testable import Scribe

/// A "?" written on its own beside something asks the agent about it; one at the end of a line of working doesn't.
final class QuestionMarkTests: XCTestCase {
    private func stroke(_ points: [CGPoint], at date: Date) -> PKStroke {
        let pts = points.enumerated().map { i, p in
            PKStrokePoint(location: p, timeOffset: Double(i) * 0.02, size: CGSize(width: 3, height: 3), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: pts, creationDate: date))
    }

    /// A ? about 40 pt tall at `x`, `y`: a hook, then a dot under it.
    private func questionMark(x: CGFloat, y: CGFloat, at date: Date) -> [PKStroke] {
        let hook = [CGPoint(x: x, y: y + 8), CGPoint(x: x + 6, y: y), CGPoint(x: x + 16, y: y + 2), CGPoint(x: x + 18, y: y + 10),
                    CGPoint(x: x + 12, y: y + 18), CGPoint(x: x + 9, y: y + 24), CGPoint(x: x + 9, y: y + 28)]
        let dot = [CGPoint(x: x + 9, y: y + 38), CGPoint(x: x + 10, y: y + 39)]
        return [stroke(hook, at: date), stroke(dot, at: date.addingTimeInterval(0.4))]
    }

    func testAHookAndADotIsAQuestionMark() throws {
        let now = Date()
        let mark = questionMark(x: 600, y: 200, at: now.addingTimeInterval(-1))
        XCTAssertTrue(QuestionMark.looksLikeQuestionMark(mark))
        let cluster = try XCTUnwrap(QuestionMark.latestCluster(mark, now: now))
        XCTAssertEqual(cluster.indices, 0..<2)
        // A line and a short stroke beside it, like "1 -", isn't.
        let notOne = [stroke([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 40)], at: now),
                      stroke([CGPoint(x: 10, y: 20), CGPoint(x: 30, y: 20)], at: now)]
        XCTAssertFalse(QuestionMark.looksLikeQuestionMark(notOne))
    }

    func testOnlyWhatWasJustWrittenCounts() {
        let now = Date()
        let old = questionMark(x: 600, y: 200, at: now.addingTimeInterval(-60))
        XCTAssertNil(QuestionMark.latestCluster(old, now: now), "an old ? (loaded, undone and redone) doesn't ask again")
        let earlier = stroke([CGPoint(x: 100, y: 500), CGPoint(x: 200, y: 520)], at: now.addingTimeInterval(-20))
        let cluster = QuestionMark.latestCluster([earlier] + questionMark(x: 600, y: 200, at: now.addingTimeInterval(-1)), now: now)
        XCTAssertEqual(cluster?.indices, 1..<3, "the ink before it isn't part of it")
    }

    func testAQuestionMarkInALineOfWorkingDoesntAsk() {
        let mark = CGRect(x: 600, y: 200, width: 20, height: 40)
        XCTAssertTrue(QuestionMark.standsAlone(mark, others: [CGRect(x: 100, y: 600, width: 200, height: 40)]))
        // "x = ?": their writing runs right up to it on its row.
        XCTAssertFalse(QuestionMark.standsAlone(mark, others: [CGRect(x: 480, y: 205, width: 110, height: 36)]))
    }

    func testReadsQuestionsFromHandwriting() {
        XCTAssertEqual(QuestionMark.question(in: "?"), "")
        XCTAssertEqual(QuestionMark.question(in: "why?"), "why")
        XCTAssertEqual(QuestionMark.question(in: " how do I start ? "), "how do I start")
        XCTAssertNil(QuestionMark.question(in: "x = 3"))
        XCTAssertNil(QuestionMark.question(in: "this is far too many words to be a quick question?"))
    }

    func testBoxesTheWholeQuestionItsBeside() throws {
        let q2 = PageObject(id: "txt_1", source: .pdfText, kind: "line", text: "2. Find d/dx (x³).",
                            bounds: CGRect(x: 80, y: 100, width: 300, height: 24))
        let q2b = PageObject(id: "txt_2", source: .pdfText, kind: "line", text: "Give your answer in full.",
                             bounds: CGRect(x: 110, y: 130, width: 260, height: 24))
        let q3 = PageObject(id: "txt_3", source: .pdfText, kind: "line", text: "3. Find d/dx (5x⁴ − 3x).",
                            bounds: CGRect(x: 80, y: 400, width: 320, height: 24))
        let mark = PageObject(id: "ink_1", source: .studentInk, kind: "handwriting", text: "?",
                              bounds: CGRect(x: 420, y: 98, width: 20, height: 36))
        let snapshot = PageMapSnapshot(pageSize: CGSize(width: 1100, height: 800), objects: [q2, q2b, q3, mark])
        let subject = try XCTUnwrap(QuestionMark.subject(of: mark.bounds, in: snapshot))
        XCTAssertEqual(subject, q2.bounds.union(q2b.bounds), "question 2, both its lines, and not question 3")
    }
}
