import XCTest
@testable import Scribe

/// Streamed tool calls become visualizations; pages are checked in the sandbox before they're shown.
final class VisualizationTests: XCTestCase {
    private func events(_ lines: [String]) throws -> (ClaudeClient.ToolTurn, [String]) {
        var stream = StreamAssembler()
        var started: [String] = []
        for line in lines {
            if let name = try stream.apply(JSONValue.parse(line)!) { started.append(name) }
        }
        return (stream.turn, started)
    }

    func testStreamAssemblesThinkingTextAndToolCall() throws {
        let (turn, started) = try events([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Plan."}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Let me "}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"show you."}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"show_visualization","input":{}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\"title\": \"Cube\", "}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"\"html\": \"<p>hi</p>\"}"}}"#,
            #"{"type":"content_block_stop","index":2}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#
        ])
        XCTAssertEqual(started, ["show_visualization"])
        XCTAssertEqual(turn.stopReason, "tool_use")
        XCTAssertEqual(turn.text, "Let me show you.")
        XCTAssertEqual(turn.content[0], ["type": "thinking", "thinking": "Plan.", "signature": "sig"])
        XCTAssertEqual(turn.toolUses.first?.id, "toolu_1")
        XCTAssertEqual(turn.toolUses.first?.input["title"], "Cube")
        XCTAssertTrue(turn.brokenToolIDs.isEmpty)
    }

    func testCutOffToolCallIsMarkedBroken() throws {
        let (turn, _) = try events([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_2","name":"show_visualization","input":{}}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"title\": \"Cu"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}"#
        ])
        XCTAssertEqual(turn.brokenToolIDs, ["toolu_2"])
        XCTAssertEqual(turn.content[0]["input"], [:])
    }

    func testStreamErrorThrows() {
        var stream = StreamAssembler()
        XCTAssertThrowsError(try stream.apply(JSONValue.parse(
            #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#)!))
    }

    func testToolInputBecomesVisualization() throws {
        let input: JSONValue = ["title": " Orbits ", "html": "<canvas></canvas>", "caption": "Drag the planet.", "height": 900]
        let v = try VisualizationTool.visualization(from: input).get()
        XCTAssertEqual(v.title, "Orbits")
        XCTAssertEqual(v.caption, "Drag the planet.")
        XCTAssertEqual(v.height, Visualization.heights.upperBound)
        XCTAssertThrowsError(try VisualizationTool.visualization(from: ["title": "No page"]).get())
    }

    func testFragmentIsWrappedWithTheSandboxPolicy() {
        let doc = CardSandbox.document("<p>hi</p>")
        XCTAssertTrue(doc.hasPrefix("<!doctype html>"))
        XCTAssertTrue(doc.contains("connect-src 'none'"))
        let whole = CardSandbox.document("<html><head><title>x</title></head><body></body></html>")
        XCTAssertTrue(whole.contains("<head><meta charset"))
    }

    @MainActor
    func testClosedCardCanBeReopenedWhereItWas() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CanvasStore(directory: root)
        let model = CanvasModel(store: store, document: store.createNote(title: "Cards", in: nil))
        for title in ["A", "B", "C"] { model.addVisualization(Visualization(title: title, html: "<p>\(title)</p>")) }
        let b = model.content.visualizations[1].id
        model.closeVisualization(b)
        XCTAssertEqual(model.content.visualizations.map(\.title), ["A", "C"])
        XCTAssertEqual(model.closedVisualization?.visualization.title, "B")
        model.reopenClosedVisualization()
        XCTAssertEqual(model.content.visualizations.map(\.title), ["A", "B", "C"])
        XCTAssertNil(model.closedVisualization)
    }

    // MARK: The sandbox, for real

    @MainActor
    func testThreePageLoadsCleanly() async {
        let html = """
        <script src="app://lib/three.min.js"></script>
        <script>
        const v = Card.three({distance: 4});
        const cube = new THREE.Mesh(new THREE.BoxGeometry(1.6, 1.6, 1.6), new THREE.MeshStandardMaterial({color: Card.color.curve}));
        v.scene.add(cube);
        v.label('6 faces', [0, 1.3, 0]);
        v.onFrame(dt => { cube.rotation.x += dt; });
        Card.readout('faces: 6');
        </script>
        """
        let problem = await WebCardProbe.check(html, timeout: 20)
        XCTAssertNil(problem)
    }

    @MainActor
    func testTimelineAndSliderPageLoadsCleanly() async {
        let html = """
        <script>
        const s = Card.stage();
        let k = 1;
        function draw(t) {
          s.clear();
          s.ctx.strokeStyle = Card.color.curve; s.ctx.lineWidth = 2; s.ctx.beginPath();
          for (let x = 0; x <= s.width; x += 4) {
            const y = s.height / 2 - Math.sin(x / 30 * k) * 60 * Card.phase(t, 0);
            x === 0 ? s.ctx.moveTo(x, y) : s.ctx.lineTo(x, y);
          }
          s.ctx.stroke();
        }
        const tl = Card.timeline({duration: 2, phases: [["Grow", 1]], onFrame: draw});
        Card.slider({label: 'k', min: 0.5, max: 3, value: 1, step: 0.1, onInput: v => { k = v; draw(tl.t); }});
        Card.onResize(() => draw(tl.t));
        </script>
        """
        let problem = await WebCardProbe.check(html, timeout: 20)
        XCTAssertNil(problem)
    }

    @MainActor
    func testThrowingPageIsReported() async {
        let problem = await WebCardProbe.check("<script>undefinedFunction();</script>", timeout: 20)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("threw") == true, problem ?? "")
    }

    @MainActor
    func testBlankCanvasIsReported() async {
        let problem = await WebCardProbe.check("<script>const s = Card.stage();</script>", timeout: 20)
        XCTAssertTrue(problem?.contains("blank") == true, problem ?? "nil")
    }

    @MainActor
    func testNetworkIsBlocked() async {
        let problem = await WebCardProbe.check(#"<script src="https://cdn.jsdelivr.net/npm/three@0.149.0/build/three.min.js"></script><script>new THREE.Scene()</script>"#, timeout: 20)
        XCTAssertNotNil(problem)
    }
}
