import CoreText
import SwiftUI
import UIKit

// Minimal versions of the canvas-agent types `LandingView` draws with. They cover only what the landing screen
// needs (pacing, colours, handwritten labels, the dotted page and page fitting) and can grow into the real thing.

// MARK: - Pacing

enum AgentPacing {
    /// Cursor flight between marks.
    static let travel: Double = 0.35
    static let circle: Double = 1.0
    static let arrow: Double = 0.6
    static let check: Double = 0.35

    /// A freehand stroke: quicker per point the longer it is, within sensible bounds.
    static func strokeDuration(length: CGFloat) -> Double {
        min(1.4, max(0.25, 0.15 + Double(length) / 700))
    }

    /// Handwriting speed for a label of `characters` characters: unhurried enough to see each letter form.
    static func write(characters: Int) -> Double { 0.3 + 0.07 * Double(characters) }
}

enum Easing {
    static func inOut(_ x: Double) -> Double { Ease.inOut(x) }
}

// MARK: - Colour

struct AgentColor {
    let color: Color

    /// `"#RRGGBB"`.
    init(_ hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        color = Color(red: Double((value >> 16) & 0xFF) / 255,
                      green: Double((value >> 8) & 0xFF) / 255,
                      blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Actions

enum AgentAction {
    /// Handwritten text centred on `at`.
    case writeLabel(text: String, at: CGPoint, color: AgentColor, size: CGFloat)

    var duration: Double {
        switch self {
        case let .writeLabel(text, _, _, _): AgentPacing.write(characters: text.count)
        }
    }
}

/// The agent's handwriting face and its metrics. All agent writing uses Caveat (bundled, see DESIGN.md).
enum Handwriting {
    static let fontName = "Caveat-Regular"
    /// Caveat runs small for its point size; this brings it up to match the agent's pen strokes.
    static let sizeScale: CGFloat = 1.25
    /// Caveat is a variable font; 600 reads like a felt-tip next to 3 pt ink strokes.
    static let weight: CGFloat = 600

    static func font(size: CGFloat) -> UIFont {
        guard let base = UIFont(name: fontName, size: size * sizeScale) else { return .systemFont(ofSize: size) }
        let wght = 0x7767_6874 // 'wght'
        let descriptor = base.fontDescriptor.addingAttributes([
            UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight],
        ])
        return UIFont(descriptor: descriptor, size: size * sizeScale)
    }

    static func swiftUIFont(size: CGFloat) -> Font { Font(font(size: size) as CTFont) }

    /// Agent writing as SwiftUI text. It opts out of the app-wide `.fontDesign(.rounded)`, which would otherwise
    /// swap Caveat for SF Pro Rounded (wider, so it overflows its measured width and gets clipped).
    static func text(_ string: String, size: CGFloat) -> Text {
        Text(string).font(swiftUIFont(size: size)).fontDesign(nil)
    }

    static func width(of text: String, size: CGFloat) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font(size: size)]).width
    }
}

enum AgentGeometry {
    /// Where the cursor tip is a fraction `progress` of the way through `action`.
    static func cursorPoint(for action: AgentAction, progress: Double) -> CGPoint? {
        switch action {
        case let .writeLabel(text, at, _, size):
            // The pen works through each letter's ink, top to bottom and back, as it's written.
            let line = HandwritingLine.make(text, size: size)
            let tip = line.tip(at: progress)
            let origin = line.origin(centeredOn: at)
            return CGPoint(x: origin.x + tip.x, y: origin.y + tip.y)
        }
    }
}

enum AgentRenderer {
    /// Draws `action` as far as `progress` (0…1): handwriting appears letter by letter, each letter growing under the
    /// pen along Caveat's slant, with a pause between words.
    static func draw(_ action: AgentAction, progress: Double, seed: Double, in context: inout GraphicsContext) {
        switch action {
        case let .writeLabel(text, at, color, size):
            guard progress > 0 else { return }
            let ink = Handwriting.text(text, size: size).foregroundColor(color.color)
            // Finished writing is never clipped: Caveat's slanted strokes reach past the width it reports.
            guard progress < 1 else {
                context.draw(ink, at: at, anchor: .center)
                return
            }
            let line = HandwritingLine.make(text, size: size)
            let origin = line.origin(centeredOn: at)
            let front = origin.x + line.reveal(at: progress)
            guard front > origin.x - size else { return }
            // Everything left of the pen, with the edge leaning like the letters do.
            let top = origin.y - line.ascent - size * 0.3, bottom = origin.y + line.descent + size * 0.3
            let lean = HandwritingLine.slant
            var clip = Path()
            clip.move(to: CGPoint(x: origin.x - size, y: top))
            clip.addLine(to: CGPoint(x: front + (origin.y - top) * lean, y: top))
            clip.addLine(to: CGPoint(x: front - (bottom - origin.y) * lean, y: bottom))
            clip.addLine(to: CGPoint(x: origin.x - size, y: bottom))
            clip.closeSubpath()
            var reveal = context
            reveal.clip(to: clip)
            reveal.draw(ink, at: at, anchor: .center)
        }
    }
}

/// A line of the agent's handwriting, letter by letter: where each letter sits, when the pen reaches it, and the path
/// its tip takes through the letter's ink. Coordinates run from the line's left end on the baseline, y down.
final class HandwritingLine {
    struct Letter {
        var minX: CGFloat
        var maxX: CGFloat
        /// When the pen starts and finishes this letter, as fractions of the whole line.
        var start: Double
        var end: Double
        /// The pen's way through the ink: down and up across the letter, left to right.
        var track: [CGPoint]
    }

    /// How far Caveat leans: x per unit of height.
    static let slant: CGFloat = 0.2

    let letters: [Letter]
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let lineHeight: CGFloat

    private init(letters: [Letter], width: CGFloat, ascent: CGFloat, descent: CGFloat, lineHeight: CGFloat) {
        self.letters = letters
        self.width = width
        self.ascent = ascent
        self.descent = descent
        self.lineHeight = lineHeight
    }

    private static var cache: [String: HandwritingLine] = [:]

    static func make(_ text: String, size: CGFloat) -> HandwritingLine {
        let key = "\(size)|\(text)"
        if let line = cache[key] { return line }
        let line = build(text, size: size)
        if cache.count > 400 { cache.removeAll() }
        cache[key] = line
        return line
    }

    /// The left end of the baseline, for the line drawn centred on `at` (as `Handwriting.text` is).
    func origin(centeredOn at: CGPoint) -> CGPoint {
        CGPoint(x: at.x - width / 2, y: at.y - lineHeight / 2 + ascent)
    }

    /// How far right the ink shows at `progress`.
    func reveal(at progress: Double) -> CGFloat {
        guard progress < 1 else { return width + ascent }
        var x: CGFloat = -.infinity
        for letter in letters {
            if progress >= letter.end {
                x = max(x, letter.maxX)
            } else if progress > letter.start {
                let t = (progress - letter.start) / (letter.end - letter.start)
                x = max(x, letter.minX + (letter.maxX - letter.minX) * CGFloat(t))
                break
            } else {
                break
            }
        }
        return x
    }

    /// Where the pen tip is at `progress`: in a letter's ink, or lifting across to the next one.
    func tip(at progress: Double) -> CGPoint {
        let p = min(1, max(0, progress))
        guard let first = letters.first else { return CGPoint(x: width * p, y: 0) }
        if p <= first.start { return first.track.first ?? CGPoint(x: first.minX, y: 0) }
        for (i, letter) in letters.enumerated() {
            if p <= letter.end {
                if p >= letter.start {
                    let t = (p - letter.start) / max(letter.end - letter.start, 0.0001)
                    return Self.along(letter.track, t)
                }
                // Between letters (or words): the pen lifts and moves across.
                let prev = letters[i - 1]
                let from = prev.track.last ?? CGPoint(x: prev.maxX, y: 0)
                let to = letter.track.first ?? CGPoint(x: letter.minX, y: 0)
                let t = Ease.inOutSine((p - prev.end) / max(letter.start - prev.end, 0.0001))
                let lift = -ascent * 0.25 * sin(.pi * t)
                return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t + lift)
            }
        }
        return letters.last?.track.last ?? CGPoint(x: width, y: 0)
    }

    private static func along(_ track: [CGPoint], _ t: Double) -> CGPoint {
        guard track.count > 1 else { return track.first ?? .zero }
        let f = min(1, max(0, t)) * Double(track.count - 1)
        let i = min(Int(f), track.count - 2)
        let k = CGFloat(f - Double(i))
        return CGPoint(x: track[i].x + (track[i + 1].x - track[i].x) * k, y: track[i].y + (track[i + 1].y - track[i].y) * k)
    }

    private static func build(_ text: String, size: CGFloat) -> HandwritingLine {
        let font = Handwriting.font(size: size)
        let ascent = font.ascender, descent = -font.descender
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

        // Each glyph with its outline, in line coordinates (y down from the baseline).
        struct Raw { var minX: CGFloat; var maxX: CGFloat; var path: CGPath? }
        var raws: [Raw] = []
        let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            var advances = [CGSize](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: count), &advances)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let runFont: CTFont = attributes[kCTFontAttributeName].map { $0 as! CTFont } ?? (font as CTFont)
            for g in 0..<count {
                var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[g].x, ty: 0)
                let path = CTFontCreatePathForGlyph(runFont, glyphs[g], &flip)
                if let path, !path.boundingBoxOfPath.isEmpty {
                    let box = path.boundingBoxOfPath
                    raws.append(Raw(minX: box.minX, maxX: box.maxX, path: path))
                } else {
                    // A space: a pause for the pen, no ink.
                    raws.append(Raw(minX: positions[g].x, maxX: positions[g].x + advances[g].width, path: nil))
                }
            }
        }

        // Time for each letter follows how much there is to it; a space is a pen lift between words.
        var weights: [Double] = []
        for raw in raws {
            if let path = raw.path {
                let box = path.boundingBoxOfPath
                weights.append(0.5 + Double((box.width + box.height) / max(size, 1)))
            } else {
                weights.append(0.9)
            }
        }
        let lift = 0.18
        let total = weights.reduce(0, +) + lift * Double(max(0, raws.count - 1))
        var letters: [Letter] = []
        var clock = 0.0
        for (raw, weight) in zip(raws, weights) {
            defer { clock += weight + lift }
            guard let path = raw.path else { continue }
            letters.append(Letter(minX: raw.minX, maxX: raw.maxX, start: clock / total, end: (clock + weight) / total,
                                  track: track(through: path, ascent: ascent, descent: descent, size: size)))
        }
        return HandwritingLine(letters: letters, width: width, ascent: ascent, descent: descent,
                               lineHeight: font.lineHeight)
    }

    /// Down and up through the ink, a few columns across the letter.
    private static func track(through path: CGPath, ascent: CGFloat, descent: CGFloat, size: CGFloat) -> [CGPoint] {
        let box = path.boundingBoxOfPath
        let columns = max(2, min(6, Int((box.width / max(size * 0.14, 1)).rounded())))
        let rows = 24
        var out: [CGPoint] = []
        for c in 0..<columns {
            let x = box.minX + box.width * (CGFloat(c) + 0.5) / CGFloat(columns)
            var top: CGFloat?, bottom: CGFloat?
            for r in 0...rows {
                let y = box.minY + box.height * CGFloat(r) / CGFloat(rows)
                // Caveat leans, so look along the slant rather than straight down.
                let p = CGPoint(x: x + (box.midY - y) * slant * 0.5, y: y)
                if path.contains(p) {
                    if top == nil { top = y }
                    bottom = y
                }
            }
            guard let top, let bottom else { continue }
            let leanTop = CGPoint(x: x + (box.midY - top) * slant * 0.5, y: top)
            let leanBottom = CGPoint(x: x + (box.midY - bottom) * slant * 0.5, y: bottom)
            out.append(contentsOf: c % 2 == 0 ? [leanTop, leanBottom] : [leanBottom, leanTop])
        }
        if out.isEmpty { out = [CGPoint(x: box.minX, y: box.midY), CGPoint(x: box.maxX, y: box.midY)] }
        return out
    }
}

// MARK: - Page

/// A notebook page's background pattern (dots, grid or nothing), drawn in `regions`.
struct PageBackgroundView: View {
    let style: PageBackground
    let regions: [CGRect]
    /// Distance between dots or grid lines; smaller for thumbnails.
    var spacing: CGFloat = 24

    var body: some View {
        Canvas { context, _ in
            var marks = Path()
            let r = 1.1 * spacing / 24
            for region in regions {
                // Centred across the width, so the margins at the left and right edges match.
                let startX = region.minX + (region.width.truncatingRemainder(dividingBy: spacing) + spacing) / 2
                switch style {
                case .dots:
                    var y = region.minY + spacing / 2
                    while y < region.maxY {
                        var x = startX
                        while x < region.maxX {
                            marks.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                            x += spacing
                        }
                        y += spacing
                    }
                case .grid:
                    var x = startX
                    while x < region.maxX {
                        marks.move(to: CGPoint(x: x, y: region.minY)); marks.addLine(to: CGPoint(x: x, y: region.maxY))
                        x += spacing
                    }
                    var y = region.minY + spacing / 2
                    while y < region.maxY {
                        marks.move(to: CGPoint(x: region.minX, y: y)); marks.addLine(to: CGPoint(x: region.maxX, y: y))
                        y += spacing
                    }
                case .none:
                    break
                }
            }
            switch style {
            case .dots: context.fill(marks, with: .color(Color(white: 0.8)))
            case .grid: context.stroke(marks, with: .color(Color(white: 0.88)), lineWidth: max(0.5, spacing / 36))
            case .none: break
            }
        }
        .allowsHitTesting(false)
    }
}

enum SamplePDF {
    case letter

    /// Page size in points.
    var size: CGSize {
        switch self {
        case .letter: CGSize(width: 612, height: 792)
        }
    }
}

/// Page-fitting rules for the note canvas.
enum ZoomScrollView {
    /// Room taken by the canvas toolbar above and below the page.
    static let chromeTop: CGFloat = 56
    static let chromeBottom: CGFloat = 0

    /// The zoom at which `page` fits the screen between the chrome and side margins.
    static func fit(page: CGSize, in screen: CGSize, top: CGFloat, bottom: CGFloat, side: CGFloat) -> CGFloat {
        let width = max(1, screen.width - 2 * side) / page.width
        let height = max(1, screen.height - top - bottom) / page.height
        return max(0.01, min(width, height))
    }
}
