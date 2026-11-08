import Foundation

/// A visualization the agent made: its own small web page (HTML, CSS, JavaScript), shown as a card hovering over the
/// pages. Saved with the note, newest last.
struct Visualization: Identifiable, Codable, Equatable {
    var id = UUID()
    var date = Date()
    var title: String
    /// One line under the card: what the person can try.
    var caption: String?
    /// The whole page, run in `CardSandbox`.
    var html: String
    /// The page's height in points (the header and caption are extra).
    var height: CGFloat = Visualization.defaultHeight

    /// A typical card width (300 to 400, with the screen); pages must fit any width.
    static let pageWidth: CGFloat = 360
    static let defaultHeight: CGFloat = 300
    /// The heights the agent (or the page itself) may ask for.
    static let heights: ClosedRange<CGFloat> = 220...560
    /// The heights the person can drag a card to.
    static let resizableHeights: ClosedRange<CGFloat> = 160...760
    /// The largest page the agent may send, in UTF-8 bytes.
    static let maxBytes = 80_000
}

/// The tool the agent opens a visualization with. Every description lives here, so tuning how the agent makes
/// visualizations happens in one place.
enum VisualizationTool {
    static let name = "show_visualization"

    /// The card kit every page gets, described once for the model. Keep in step with Web/card-kit.js.
    static let cardKit = """
        The app injects a dark stylesheet and a small kit into every page; use them so visualizations look alike. \
        CSS variables: --stage (#0E0E10 background), --curve #58C4DD (main curve), --result #FFFF00 (result, tangent), \
        --second #F0AC5F, --rise #83C167, --primary #FFF, --grid, --axes, --warn #FF9F0A, --ok #7EE29A, --red, --muted, \
        --text, --label; classes .math (STIX serif maths; use <i> for variables), .readout, .note. \
        JS (global `Card`, ready before your scripts run): \
        const s = Card.stage() → {canvas, ctx, width, height, clear()}: a canvas filling the card above the dock, ctx \
        already scaled for the screen; width/height stay current, redraw in Card.onResize(fn). \
        Card.timeline({duration: s, phases: [["Build", 1], ["Spin", 2]], onFrame: t => draw(t), loop: false}) adds the \
        app's play/scrub bar and plays once by itself (t 0→1; phases are relative shares); Card.phase(t, i) is the eased \
        progress through phase i. Card.slider({label, min, max, value, step, onInput: v => …}) adds a slider above it. \
        Card.readout(text) sets the live readout in the card's header. Card.ease(t), Card.lerp(a, b, t), Card.clamp(x, a, b). \
        Card.color.curve etc. hold the colours above. \
        3D: load <script src="app://lib/three.min.js"></script> (three r149, global THREE; no addons, no OrbitControls) \
        before your script, then const v = Card.three({distance: 6, elevation: 1.1, target: [0, 0, 0], autoRotate: true}) → \
        {THREE, scene, camera, renderer, orbit, onFrame(fn(dt, elapsed)), label(html, position)}: lights, a camera that \
        orbits the target (drag to turn, pinch to zoom, gentle auto-rotation until touched) and the render loop are done \
        for you; add meshes to v.scene, animate them in v.onFrame, and pin text to a point or object with v.label. \
        Use MeshStandardMaterial or MeshPhongMaterial with the colours above. \
        2D data: <script src="app://lib/d3.min.js"></script> (d3 v7, global d3).
        """

    static let description = """
        Open an interactive visualization as a card in the top right, over the person's page: your own small web page (HTML, CSS, \
        JavaScript) running in a sandbox on a dark stage. Use it when the person asks to see, visualize, show, model or \
        simulate something: a real thing to look at (the solar system with its planets orbiting, a cell, a molecule, an \
        atom), a shape to turn in 3D (a cube, a cone, a cross-section, a 3D graph), motion over time (a pendulum, a \
        wave, secant → tangent), or data with a slider to explore. Prefer 3D (three.js) whenever the subject is a \
        physical object or a shape in space. \
        Each call adds one new visualization below the earlier ones; keep it focused on one idea. \
        The page: one self-contained document ≤ 60 KB, `height` pt tall (default \(Int(Visualization.defaultHeight))) and \
        300–400 pt wide depending on the screen (the person can also make it taller or shorter); size everything from the stage's width and height, never fixed pixels. \
        No network, no storage, no alerts, no external URLs; everything inline. Make it animate by itself at first, then \
        let the person drag, scrub or slide. Keep the maths and science right: compute values in code, don't hard-code \
        them. The app shows `title` and `caption` around the page; don't draw your own title bar. \
        \(cardKit) \
        If the page throws an error while loading, or draws nothing, you get the problem back: fix it and call \
        \(name) once more. \
        Example: {"title": "A cube has 6 faces", "caption": "Drag to turn it.", "height": 360, "html": \
        "<script src=\\"app://lib/three.min.js\\"></script><script>const v = Card.three({distance: 4}); \
        const cube = new THREE.Mesh(new THREE.BoxGeometry(1.6, 1.6, 1.6), new THREE.MeshStandardMaterial({color: Card.color.curve})); \
        v.scene.add(cube); v.label('6 faces', [0, 1.3, 0]);</script>"}
        """

    static var definition: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "Short, ≤ 6 words. Maths may use ^ (f(x) = x^3)."],
                    "html": ["type": "string", "description": "The whole page, ≤ 60 KB."],
                    "caption": ["type": "string", "description": "One line under the card: what the person can try (\"Drag to turn it.\")."],
                    "height": ["type": "number", "description": "Page height in points, 220–560. Default 300."]
                ],
                "required": ["title", "html"],
                "additionalProperties": false
            ],
            "eager_input_streaming": true
        ]
    }

    /// A visualization from the tool's input, or why it can't be one.
    static func visualization(from input: JSONValue) -> Result<Visualization, InputError> {
        guard let title = input["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return .failure(InputError("`title` is missing"))
        }
        guard let html = input["html"]?.string, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure(InputError("`html` is missing"))
        }
        guard html.utf8.count <= Visualization.maxBytes else {
            return .failure(InputError("the page is \(html.utf8.count / 1000) KB; keep it under 60 KB"))
        }
        let caption = input["caption"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        let height = input["height"]?.number.map { min(max(CGFloat($0), Visualization.heights.lowerBound),
                                                      Visualization.heights.upperBound) }
        return .success(Visualization(title: String(title.prefix(80)), caption: caption?.isEmpty == false ? caption : nil,
                                      html: html, height: height ?? Visualization.defaultHeight))
    }

    struct InputError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
