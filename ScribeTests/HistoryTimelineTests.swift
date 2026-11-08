import XCTest
@testable import Scribe

/// History shows the agent's steps between what was said, and typed answers stay open long enough to read.
final class HistoryTimelineTests: XCTestCase {
    private func mark(_ kind: String, text: String? = nil, target: String? = nil) -> AgentMark {
        AgentMark(turn: UUID(), kind: kind, text: text, target: target, items: [])
    }

    func testDescribesWriting() {
        let step = AgentStep.describe(drawn: [mark("note", text: "x = 3")], erased: 0, page: 2)
        XCTAssertEqual(step?.text, "Wrote “x = 3” on page 2")
    }

    func testDescribesMarksByWhatTheyreOn() {
        XCTAssertEqual(AgentStep.describe(drawn: [mark("circle", target: "ink_4")], erased: 0, page: 1)?.text,
                       "Circled your writing on page 1")
        XCTAssertEqual(AgentStep.describe(drawn: [mark("underline", target: "txt_2")], erased: 0, page: 3)?.text,
                       "Underlined the text on page 3")
    }

    func testCutsLongWritingAtAWord() {
        let long = "the quick brown fox jumps over the lazy dog and keeps on running"
        let text = AgentStep.describe(drawn: [mark("note", text: long)], erased: 0, page: 1)?.text ?? ""
        XCTAssertTrue(text.hasPrefix("Wrote “the quick brown fox jumps over the lazy…”"), text)
    }

    func testErasingAloneIsAStepAndNothingIsNot() {
        XCTAssertEqual(AgentStep.describe(drawn: [], erased: 2, page: 1)?.text, "Erased 2 of its marks on page 1")
        XCTAssertNil(AgentStep.describe(drawn: [], erased: 0, page: 1))
    }

    func testTimelinePutsStepsBetweenQuestionAndAnswer() {
        let start = Date()
        var content = NoteContent()
        content.conversation = [
            ConversationTurn(date: start, speaker: .you, text: "help", spoken: false),
            ConversationTurn(date: start.addingTimeInterval(10), speaker: .agent, text: "there", spoken: false),
        ]
        content.history = [
            HistoryEntry(date: start.addingTimeInterval(5), author: .agent, text: "Wrote “x” on page 1"),
            HistoryEntry(date: start.addingTimeInterval(6), author: .you, text: "Added page 2"),
        ]
        let order = HistoryItem.timeline(content).map { item -> String in
            switch item {
            case .turn(let turn): turn.text
            case .step(let step): step.text
            }
        }
        XCTAssertEqual(order, ["help", "Wrote “x” on page 1", "there"])
    }

    func testReadingTimeGrowsWithLengthWithinBounds() {
        XCTAssertEqual(AgentReply(text: "Yes.").readingTime, 5)
        let long = AgentReply(text: Array(repeating: "word", count: 500).joined(separator: " "))
        XCTAssertEqual(long.readingTime, 30)
        let medium = AgentReply(text: Array(repeating: "word", count: 70).joined(separator: " "))
        XCTAssertEqual(medium.readingTime, 22, accuracy: 0.01)
    }

    func testOldHistoryStillDecodes() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":0,"author":"agent","text":"Drew on page 1"}"#
        let entry = try JSONDecoder().decode(HistoryEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.symbol)
        XCTAssertNil(entry.pageID)
        XCTAssertNil(entry.markIDs)
    }

    func testStepRemembersTheMarksItDrewForItsPicture() {
        let marks = [mark("circle", target: "ink_1"), mark("note", text: "here")]
        let step = AgentStep.entry(drawn: marks, erased: 0, page: 1, pageID: UUID())
        XCTAssertEqual(step?.markIDs, marks.map(\.id))
        XCTAssertNil(AgentStep.entry(drawn: [], erased: 1, page: 1, pageID: UUID())?.markIDs)
    }

    func testPreviewRegionHoldsTheMarksAndStaysOnThePage() {
        let page = CGRect(x: 0, y: 0, width: 1100, height: 850)
        // A small tick in the corner: widened to show what's around it, and slid back onto the page.
        let tick = CGRect(x: 1080, y: 5, width: 15, height: 15)
        let r = CanvasModel.previewRegion(around: tick, in: page)
        XCTAssertTrue(page.contains(r))
        XCTAssertTrue(r.contains(tick))
        XCTAssertGreaterThanOrEqual(r.width, 220)
        XCTAssertGreaterThanOrEqual(r.height, 110)
        // A tall drawing is widened, so it isn't a thin strip.
        let tall = CGRect(x: 400, y: 100, width: 60, height: 500)
        let t = CanvasModel.previewRegion(around: tall, in: page)
        XCTAssertTrue(t.contains(tall))
        XCTAssertEqual(t.width, t.height, accuracy: 1)
        XCTAssertTrue(CanvasModel.previewRegion(around: .null, in: page).isNull)
    }
}
