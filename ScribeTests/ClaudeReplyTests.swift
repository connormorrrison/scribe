import XCTest
@testable import Scribe

/// Replies from the Messages API turn into an answer to show, or an error that says why there isn't one.
final class ClaudeReplyTests: XCTestCase {
    private func reply(_ json: String) throws -> ClaudeClient.Reply {
        try JSONDecoder().decode(ClaudeClient.Reply.self, from: Data(json.utf8))
    }

    func testAnswerSkipsThinking() throws {
        let r = try reply("""
        {"model":"claude-haiku-5-5","stop_reason":"end_turn","content":[
          {"type":"thinking","thinking":"","signature":"abc"},
          {"type":"text","text":"  Hello there. "}]}
        """)
        XCTAssertEqual(try r.answer(), "Hello there.")
    }

    func testRefusalIsAnError() throws {
        let r = try reply(#"{"model":"claude-haiku-5-5","stop_reason":"refusal","content":[]}"#)
        XCTAssertThrowsError(try r.answer()) { XCTAssertEqual($0 as? ClaudeClient.ReplyError, .declined) }
    }

    func testCutOffDuringThinkingIsAnError() throws {
        let r = try reply("""
        {"model":"claude-haiku-5-5","stop_reason":"max_tokens","content":[
          {"type":"thinking","thinking":"","signature":"abc"}]}
        """)
        XCTAssertThrowsError(try r.answer()) { XCTAssertEqual($0 as? ClaudeClient.ReplyError, .cutOff) }
    }
}
