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
        progress through phase i. Card.slider({label, min, max, value, step, onInput: v => …, format: v => text}) adds a \
        slider above it (label: a symbol like θ or <i>n</i>, or one short word). Card.choice({label, options: ["Sine", \
        "Cosine"] or [["Sine", "sin"], …], value, onChange: v => …}) adds a row of buttons, one chosen (shapes, modes, \
        functions, presets). Card.toggle({label: "Tangent", value: true, onChange: on => …}) adds an on/off button (show \
        or hide a part, a trail, labels, axes); toggles share one row. Each returns {value, set(v)}. \
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
        Give almost every visualization controls, so the person can play with it rather than just watch: one to three \
        Card.slider for the quantities that matter (an angle, a speed, a mass, a number of sides, n, a frequency, a \
        coefficient), Card.choice to switch between cases, Card.toggle to show or hide parts, and Card.timeline when it \
        plays out over time. Every control changes the picture live, and the readout shows the numbers it changes. \
        Only leave controls out when there is truly nothing to vary. \
        The page: one self-contained document ≤ 60 KB, `height` pt tall (default \(Int(Visualization.defaultHeight))) and \
        300–400 pt wide depending on the screen (the person can also enlarge it to fill the screen); the controls take \
        about 44 pt each from that height, so make `height` taller when there are several. Size everything from the \
        stage's width and height, never fixed pixels. \
        No network, no storage, no alerts, no external URLs; everything inline. Make it animate by itself at first, then \
        let the person drag, scrub or slide. Keep the maths and science right: compute values in code, don't hard-code \
        them. The app shows `title` and `caption` around the page; don't draw your own title bar. The title just \
        names the thing, as a heading would ("The solar system", "Pendulum", "A cube's faces"): never add "in 3D", \
        "visualization", "interactive", "model of" or the like. \
        \(cardKit) \
        If the page throws an error while loading, or draws nothing, you get the problem back: fix it and call \
        \(name) once more. \
        Example: {"title": "Prisms", "caption": "Drag to turn it; change the number of sides.", "height": 380, "html": \
        "<script src=\\"app://lib/three.min.js\\"></script><script>const v = Card.three({distance: 5}); \
        const mat = new THREE.MeshStandardMaterial({color: Card.color.curve}); let prism; \
        function build(n) { if (prism) v.scene.remove(prism); prism = new THREE.Mesh(new THREE.CylinderGeometry(1.2, 1.2, 1.8, n), mat); \
        v.scene.add(prism); Card.readout(`faces: ${n + 2} · edges: ${3 * n} · vertices: ${2 * n}`); } \
        build(4); Card.slider({label: 'sides', min: 3, max: 12, step: 1, value: 4, onInput: build}); \
        Card.toggle({label: 'Wireframe', value: false, onChange: on => { mat.wireframe = on; }});</script>"}
        """

    static var definition: JSONValue {
        [
            "name": .string(name),
            "description": .string(description),
            "input_schema": [
                "type": "object",
                "properties": [
                    "title": ["type": "string", "description": "What it shows, as a plain heading, ≤ 5 words (\"The solar system\", \"Pendulum\"); never \"in 3D\" or \"visualization\". Maths may use ^ (f(x) = x^3)."],
                    "html": ["type": "string", "description": "The whole page, ≤ 60 KB."],
                    "caption": ["type": "string", "description": "One line under the card: what the person can try with it (\"Drag to turn it; slide the angle.\")."],
                    "height": ["type": "number", "description": "Page height in points, controls included, 220–560. Default 300."]
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
