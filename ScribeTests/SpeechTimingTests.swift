import XCTest
@testable import Scribe

/// ElevenLabs times each character it speaks; the agent bar needs when each word starts.
final class SpeechTimingTests: XCTestCase {
    func testWordsStartAtTheirFirstCharacter() {
        let text = "Hi there,  you."
        let characters = text.map(String.init)
        let times = characters.indices.map { Double($0) / 10 }
        let starts = ElevenLabsClient.wordStarts(characters: characters, times: times,
                                                 words: AgentReply.words(in: text).count)
        XCTAssertEqual(starts, [0.0, 0.3, 1.1])
    }

    func testMismatchedWordsGiveNoTiming() {
        XCTAssertNil(ElevenLabsClient.wordStarts(characters: ["a", " ", "b"], times: [0, 0.1, 0.2], words: 3))
        XCTAssertNil(ElevenLabsClient.wordStarts(characters: ["a"], times: [0, 0.1], words: 1))
    }
}
