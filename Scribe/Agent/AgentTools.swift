import Foundation

/// The tools the agent draws and writes on the page with. `ActionValidator` turns each call into marks. Every
/// description lives here, so tuning how the agent uses the page happens in one place.
enum AgentTools {
    struct Tool {
        var name: String
        var description: String
        var properties: [String: JSONValue]
        var required: [String]
    }

    // MARK: Shared schema pieces

    static let target: JSONValue = [
        "type": "object",
        "description": "Something on the page. Prefer an id from the page map: {\"id\":\"ink_7\"}. A part of a figure (a continent of a map, a piece of a diagram): {\"id\":\"img_1.p3\"}, or a coloured area inside it: {\"id\":\"img_1.p3.a2\"}. A word inside a printed line or handwriting: {\"id\":\"txt_3\",\"match\":\"continents\"}. A free space: {\"id\":\"free_2\"}. Only when nothing in the map fits, raw page points: {\"box\":[x,y,w,h]} or {\"point\":[x,y]}.",
        "properties": [
            "id": ["type": "string"],
            "match": ["type": "string"],
            "box": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4],
            "point": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
        ],
        "additionalProperties": false,
    ]

    static let part: JSONValue = [
        "type": "object",
        "description": "A piece of writing: `text` (exactly as written), in this line unless `in` names another (\"previous\", am_N, txt_N, ink_N). `nth` picks a repeat, from 1.",
        "properties": [
            "text": ["type": "string"],
            "in": ["type": "string"],
            "nth": ["type": "integer"],
        ],
        "required": ["text"],
        "additionalProperties": false,
    ]

    static let annotation: JSONValue = [
        "type": "object",
        "properties": [
            "kind": ["type": "string", "enum": ["arrow", "circle", "underline", "box", "strike", "highlight"]],
            "on": part,
            "from": part,
            "to": part,
            "label": ["type": "string"],
            "color": color,
        ],
        "required": ["kind"],
        "additionalProperties": false,
    ]

    static let color: JSONValue = [
        "type": "string",
        "description": "A colour name (blue, red, green, orange, purple, yellow, teal, pink, gray, black) or #RRGGBB. Default: your blue ink.",
    ]

    static let side: JSONValue = [
        "type": "string", "enum": ["right", "below", "above", "left"],
        "description": "Which side of `near` to put it (default right: beside their work). The app finds clear space there (or on another side).",
    ]

    static let point: JSONValue = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]

    // MARK: The tools

    static let all: [Tool] = [
        Tool(name: "steps", description: """
            Work something through, step by step: the way to show any working (maths, a method, a derivation). Give \
            every step at once; the app lays them out as one well-spaced column beside `near`, each step on its own \
            line in blue, a grey arrow down between steps with the step's `why` beside it (the move that got here, \
            2–4 words: "bring the 3 down", "take one off"), and the last step's answer boxed in green. Each step is \
            one line of maths, one move on from the last: never two moves in one step. `annotate` on a step draws the \
            move on its characters in orange, as in write: an arrow from the 3 of x³ in the step before ({"text": "³", \
            "in": "previous"}, or "step_1") to where it lands in this one, a circle on what changes, a strike through \
            what cancels. Give `answer` when the answer isn't everything after the last "=" of the last step; \
            box_answer false only when the working stops before the answer. \
            Example: {"near": {"id": "txt_2"}, "steps": [{"text": "x³"}, {"text": "3x³⁻¹", "why": "bring the 3 down", \
            "annotate": [{"kind": "arrow", "from": {"text": "³", "in": "previous"}, "to": {"text": "3"}}]}, \
            {"text": "= 3x²", "why": "take one off", "annotate": [{"kind": "circle", "on": {"text": "²"}}]}]}
            """,
             properties: [
                "steps": ["type": "array", "minItems": 1, "maxItems": 8, "items": [
                    "type": "object",
                    "properties": [
                        "text": ["type": "string"],
                        "why": ["type": "string"],
                        "annotate": ["type": "array", "maxItems": 5, "items": annotation],
                    ],
                    "required": ["text"],
                    "additionalProperties": false,
                ]],
                "near": target,
                "side": side,
                "answer": ["type": "string"],
                "box_answer": ["type": "boolean"],
             ],
             required: ["steps", "near"]),

        Tool(name: "write", description: """
            Handwrite one line of maths, or a tiny label, on the page in your blue ink. For working in more than one \
            step, use steps instead: it spaces them out and joins them up. Prefer maths and symbols to \
            words: "2 × 2 = 4 ✓" beats "two times two is four". Words only as a label of at most 4 words, lowercase, \
            no full stops, never a sentence or a question. One step per call: for working, write each step as its \
            own call, the first `near` their work with side "right", each next one `near` your previous step (its \
            am_N) with side "below", so the steps stack into a column. Use \\n only for a short two-line equation. \
            The app puts it in clear space there, never over their writing, the printed text or the app's buttons. \
            `near` a free_N space writes inside that space. Use `at` [x, y] (the text's centre, in page points) only \
            when it must go exactly there, like a label on a figure. \
            `annotate` draws on the characters themselves, in a second colour (orange unless you give one), after the \
            line is written: what a teacher draws at the board to show what moved or changed. Kinds: arrow (`from` → \
            `to`), circle, underline, box, strike (a stroke through something that cancels), highlight, each `on` a part, with an \
            optional `label` of 1–3 words. A part is {"text": "³"} in this line, {"text": "³", "in": "previous"} in the \
            line you wrote last, {"text": "x", "in": "am_4"} in one of your marks, or {"text": "2x", "in": "txt_3"} in \
            printed text or their writing; `nth` picks a repeat. Use plain characters and superscripts (x³, x², 3x²), \
            not ^. An arrow within a line arcs over it; between lines it swoops from one to the other. \
            Example, the power rule in two steps: {"text": "x³", "size": "math", "near": {"id": "txt_2"}, "side": "right"} \
            then {"text": "3x³⁻¹ = 3x²", "size": "math", "near": {"id": "am_1"}, "side": "below", "annotate": [\
            {"kind": "arrow", "from": {"text": "³", "in": "previous"}, "to": {"text": "3"}, "label": "to the front"}, \
            {"kind": "circle", "on": {"text": "⁻¹"}, "label": "drop one"}]}
            """,
             properties: [
                "text": ["type": "string"],
                "size": ["type": "string", "enum": ["note", "label", "math"],
                         "description": "label is small, note is normal (the default), math is a little larger."],
                "near": target,
                "side": side,
                "at": point,
                "color": color,
                "annotate": ["type": "array", "maxItems": 6, "items": annotation],
             ],
             required: ["text"]),

        Tool(name: "mark", description: """
            Mark something on the page in your ink: circle, underline, highlight, check (✓ beside it), cross (✗ beside \
            it), box, or arrow. For an arrow give `from` and `to` instead of `target`. Checking work: tick what's right, \
            circle what's wrong. Don't use it to write words (use write). \
            Examples: {"kind": "circle", "target": {"id": "ink_3"}} · {"kind": "underline", "target": {"id": "txt_2", "match": "photosynthesis"}} · \
            {"kind": "arrow", "from": {"id": "ink_2"}, "to": {"id": "txt_5"}}
            """,
             properties: [
                "kind": ["type": "string", "enum": ["circle", "underline", "highlight", "check", "cross", "box", "arrow"]],
                "target": target,
                "from": target,
                "to": target,
                "color": color,
             ],
             required: ["kind"]),

        Tool(name: "outline_region", description: """
            Trace something on the page exactly, in colour: one part of a figure (a continent on a map, an organ in a \
            diagram), a printed diagram, an answer line, a box or table cell, or their own drawing. Objects marked \
            ·traceable have their real outline or lines, and the app follows them to within half a point; anything else \
            is outlined around its box. Figures are split into parts (`img_1.p1…`, listed under the figure with colour \
            and box) and parts into coloured areas (`img_1.p1.a1…`). Look at the picture to decide which part is which, \
            then trace by id. Several at once (a continent and its islands) go in `targets`; give each its own call \
            when each needs its own colour or label. A label on a figure's part goes on the part itself, so pick a colour \
            that stands out against it (each part is listed with its colour). Optionally fill it lightly. \
            Examples: {"target": {"id": "vec_4"}, "color": "orange", "fill": true, "label": "the triangle"} · \
            {"targets": [{"id": "img_1.p2"}, {"id": "img_1.p9"}], "color": "green", "label": "africa"}
            """,
             properties: [
                "target": target,
                "targets": ["type": "array", "items": target, "maxItems": 40],
                "color": color,
                "fill": ["type": "boolean"],
                "label": ["type": "string", "description": "A short name, written beside it."],
             ],
             required: []),

        Tool(name: "draw", description: """
            Draw a simple picture in your ink, like a tutor at a whiteboard: a labelled diagram of 3–6 parts, a process \
            with arrows, a number line, a quick graph, a shape with its sides marked. It goes in its own box, `size` \
            [w, h] in points (default [360, 260], at most [760, 560]), with x right and y DOWN from (0, 0) at the box's \
            top-left. The app puts the box beside `near` in clear space (or inside a free_N space), like write; or give \
            `at` [x, y], the box's top-left in page points, to add to their own drawing. \
            Plan 3–6 main parts spread over the box with room between them. Give parts an `id` and connect them by id: \
            {"type": "arrow", "from": "sun", "to": "leaf"}; the app runs the arrow from edge to edge. Name a part with \
            {"type": "label", "text": "leaf", "for": "leaf"} (the app finds room beside it, or "inside": true). \
            Shapes (at most 30), each with optional color, dashed, id: line/arrow {from, to, label?} (from/to: an id or \
            [x, y]) · path {points [[x, y]…], closed?, smooth?, fill?} · circle {center, r, fill?} · ellipse {box \
            [x, y, w, h], fill?} · rect {box, rounded?, fill?} · text {at, text, size?: label|note} · label {text, for, inside?}. \
            Example: {"size": [320, 180], "near": {"id": "ink_2"}, "side": "right", "shapes": [\
            {"type": "circle", "id": "sun", "center": [40, 40], "r": 24, "color": "orange", "fill": true}, \
            {"type": "path", "id": "leaf", "points": [[160, 120], [210, 80], [270, 95], [290, 135], [235, 165], [175, 155]], \
            "closed": true, "smooth": true, "color": "green", "fill": true}, \
            {"type": "arrow", "from": "sun", "to": "leaf", "label": "light"}, \
            {"type": "label", "text": "leaf", "for": "leaf"}]}
            """,
             properties: [
                "shapes": ["type": "array", "items": ["type": "object"], "minItems": 1, "maxItems": 30,
                           "description": "Each shape: {\"type\": line|arrow|path|circle|ellipse|rect|text|label, …}; see the description."],
                "size": point,
                "near": target,
                "side": side,
                "at": point,
             ],
             required: ["shapes"]),

        Tool(name: "erase_marks", description: """
            Erase some of your own marks (am_N from YOUR MARKS, or the ids your tool results gave), for example a \
            mark in the wrong place or one they asked you to remove. Never touches their ink. \
            Example: {"ids": ["am_3"]}
            """,
             properties: ["ids": ["type": "array", "items": ["type": "string"], "minItems": 1]],
             required: ["ids"]),
    ]

    static var names: Set<String> { Set(all.map(\.name)) }

    /// The tool definitions for the request.
    static var definitions: [JSONValue] {
        all.map { t in
            [
                "name": .string(t.name),
                "description": .string(t.description),
                "input_schema": [
                    "type": "object",
                    "properties": .object(t.properties),
                    "required": .array(t.required.map(JSONValue.string)),
                    "additionalProperties": false,
                ],
                "eager_input_streaming": true,
            ]
        }
    }

    /// What the system prompt says about the page and these tools.
    static let guidance = """
        You can see the page they're on: every request comes with a picture of it and a page map listing everything on \
        it (their writing and drawings as ink_N, printed text as txt_N, printed lines, boxes and tables as vec_N, photos, \
        your own marks as am_N), each with exact bounds in page points, plus the FREE SPACE where you can write. \
        You can write and draw on it with write, mark, outline_region and draw, like a tutor with a pen beside \
        their work. On the page, show, don't tell: maths, symbols, arrows, circles and sketches, not sentences. \
        Draw more than you write. Show working with the steps tool, all of it in one call: one small move per \
        step, each with its why, so it reads line by line down the page. Every step that changes something shows the \
        change with `annotate`: an arrow carrying a number or term to where it goes, a circle on what's about to \
        change, a strike through what cancels. A line of maths with nothing drawn on it is a missed chance. The \
        final answer is always boxed in green (steps does it; with write, annotate a green box). \
        Colours mean something, so keep to them: blue for working, orange for moves (the default for annotate), \
        green for the answer and what's right (ticks), red for a mistake (cross it, circle it), and a yellow \
        highlight on what the question gives you (the numbers and conditions to use, highlighted on the question \
        with mark before you start, when it helps to see them). Grey is the app's, for arrows between steps. \
        And whenever the idea has a shape (a graph, a tangent, a number line, an area model, \
        a force diagram, a timeline, a cycle), sketch it with draw beside the steps, labelled: a picture they can \
        see is often what makes it click. Keep words on the page to labels of a few words. After drawing or \
        writing on the page, keep your reply to one short sentence saying what you did, like "I worked it through \
        step by step." or "I sketched the graph for you." Don't explain it again: the page shows it. \
        Always target things by their id from the page map. Never guess coordinates from the picture: every object has \
        exact bounds. Put each thing beside what it's about: `near` its id. Use a free_N space only for something that         isn't about anything already on the page, and then the one nearest their work and on screen, not simply the         first listed. Spread your marks out and leave room around them rather than packing them together. Use outline_region on a ·traceable object to \
        trace its real lines; figures like maps are split into parts you can trace one by one. Each result says where your mark went; if it says something was moved, that's fine.
        """
}

/// A tool call's input as a `Decodable` type.
enum ToolInput {
    static func decode<T: Decodable>(_ type: T.Type, from input: JSONValue) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSONEncoder().encode(input))
        } catch let DecodingError.keyNotFound(key, _) {
            throw ToolInputError("`\(key.stringValue)` is missing")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let field = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw ToolInputError("`\(field)` has the wrong type")
        } catch let DecodingError.dataCorrupted(context) {
            throw ToolInputError(context.debugDescription)
        }
    }
}

struct ToolInputError: Error {
    let reason: String
    init(_ reason: String) { self.reason = reason }
}
