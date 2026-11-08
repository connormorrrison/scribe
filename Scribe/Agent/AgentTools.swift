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

    static let color: JSONValue = [
        "type": "string",
        "description": "A colour name (blue, red, green, orange, purple, yellow, teal, pink, gray, black) or #RRGGBB. Default: your blue ink.",
    ]

    static let side: JSONValue = [
        "type": "string", "enum": ["right", "below", "above", "left"],
        "description": "Which side of `near` to put it. The app finds clear space there (or on another side).",
    ]

    static let point: JSONValue = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]

    // MARK: The tools

    static let all: [Tool] = [
        Tool(name: "write", description: """
            Handwrite a short note, label or bit of maths on the page in your blue ink. Keep it short: a few words a \
            line, at most 3 lines (split lines with \\n), lowercase, no full stops. Give `near` and `side` and the app \
            puts it in clear space there, never over their writing or the printed text; `near` a free_N space writes \
            inside that space. Use `at` [x, y] (the text's centre, in page points) only when it must go exactly there, \
            like a label on a figure. Don't write the answer to a question they're working on unless they already have it. \
            Example: {"text": "area = length × width", "size": "math", "near": {"id": "ink_4"}, "side": "right"}
            """,
             properties: [
                "text": ["type": "string"],
                "size": ["type": "string", "enum": ["note", "label", "math"],
                         "description": "label is small, note is normal (the default), math is a little larger."],
                "near": target,
                "side": side,
                "at": point,
                "color": color,
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

        Tool(name: "extend_page", description: """
            Add blank space at the bottom of the page when there's no room left to write or draw. Placement does this \
            by itself when nothing fits, so you rarely need it. Example: {"height": 300}
            """,
             properties: ["height": ["type": "number", "description": "Points to add, 100–800."]],
             required: ["height"]),

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
        You can write and draw on it with write, mark, outline_region and draw. Do it when it helps more than words: \
        check their work, point something out, label, sketch a quick diagram, show a step. Keep it light, a few marks \
        a turn, and say a line about what you drew. \
        Always target things by their id from the page map. Never guess coordinates from the picture: every object has \
        exact bounds. To write in empty space, use near {"id": "free_N"}. Use outline_region on a ·traceable object to \
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
