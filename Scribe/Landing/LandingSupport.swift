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

    /// Handwriting speed for a label of `characters` characters.
    static func write(characters: Int) -> Double { 0.25 + 0.05 * Double(characters) }
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
            let width = Handwriting.width(of: text, size: size)
            let p = min(1, max(0, progress))
            // Rides along the baseline, hopping a little with each letter.
            let hop = size * 0.12 * sin(p * Double(max(1, text.count)) * .pi)
            return CGPoint(x: at.x - width / 2 + width * p, y: at.y + size * 0.2 - hop)
        }
    }
}

enum AgentRenderer {
    /// Draws `action` as far as `progress` (0…1), revealing handwriting left to right.
    static func draw(_ action: AgentAction, progress: Double, seed: Double, in context: inout GraphicsContext) {
        switch action {
        case let .writeLabel(text, at, color, size):
            guard progress > 0 else { return }
            let width = Handwriting.width(of: text, size: size)
            let height = Handwriting.font(size: size).lineHeight
            let ink = Handwriting.text(text, size: size).foregroundColor(color.color)
            // Finished writing is never clipped: Caveat's slanted strokes reach past the width it reports.
            guard progress < 1 else {
                context.draw(ink, at: at, anchor: .center)
                return
            }
            // While writing, reveal left to right, with room for strokes that lean past each letter's edge.
            let overhang = size * 0.4
            var reveal = context
            reveal.clip(to: Path(CGRect(x: at.x - width / 2 - overhang, y: at.y - height,
                                        width: width * progress + overhang, height: 2 * height)))
            reveal.draw(ink, at: at, anchor: .center)
        }
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
                switch style {
                case .dots:
                    var y = region.minY + spacing / 2
                    while y < region.maxY {
                        var x = region.minX + spacing / 2
                        while x < region.maxX {
                            marks.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
                            x += spacing
                        }
                        y += spacing
                    }
                case .grid:
                    var x = region.minX + spacing / 2
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
