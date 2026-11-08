import SwiftUI
import UIKit

/// "Scribe": the first screen on every cold launch. Tap Open (or swipe up) to open the library.
///
/// Everything on screen is a pure function of one clock, `t` (seconds since the view appeared): the intro, the
/// Open button, the two cards and the drawing cursors. Layout is done in *design points* (the 1194 × 834 landscape
/// reference) and scaled by `s` to the real screen, so portrait and other iPad sizes scale proportionally.
struct LandingView: View {
    /// Called as the page starts sliding away, so the content underneath can come in.
    var onLeave: () -> Void = {}
    /// Called once the page is fully off screen.
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()
    /// How far the page has been lifted (≤ 0). Follows the finger, then springs up and away, or back.
    @State private var lift: CGFloat = 0
    @State private var leaving = false
    @State private var height: CGFloat = 1000

    /// The part of the tagline the highlighter agent marks.
    static let taglineKey = "help you learn"
    /// Two deliberate lines, so the break falls in a natural place.
    static let tagline = "Write anything. Scribe’s AI agents see your page and join in,\nwriting, drawing and building 3D models to help you learn."
    static let message = "Scribe. \(tagline.replacingOccurrences(of: "\n", with: " "))"

    var body: some View {
        GeometryReader { geo in
            let layout = LandingLayout(screen: geo.size, safe: geo.safeAreaInsets)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { timeline in
                let clock = LandingClock(t: timeline.date.timeIntervalSince(start), still: reduceMotion)
                scene(layout: layout, clock: clock)
            }
        }
        .background { DotGrid().ignoresSafeArea() }
        .ignoresSafeArea()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        // The whole page, dots and all, moves as one sheet.
        .compositingGroup()
        .shadow(color: .black.opacity(lift < 0 ? 0.12 : 0), radius: 24, y: 8)
        .offset(y: lift)
        .contentShape(Rectangle())
        .gesture(swipe)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.message)
    }

    // MARK: Scene

    private func scene(layout: LandingLayout, clock: LandingClock) -> some View {
        let s = layout.s
        // Tagline and hint scale too, but never below 85 % so they stay readable in portrait.
        let textScale = max(s, 0.85)

        return ZStack(alignment: .topLeading) {
            // Cards
            LandingCard(title: "Atom", rect: layout.atomCard, s: s) {
                AtomArt(time: clock.cardTime, s: s)
            }
            .rise(clock.progress(0.3, 0.9), distance: 14 * s, rect: layout.atomCard, s: s)

            LandingCard(title: "Tangent line", readout: TangentArt.readout(time: clock.cardTime),
                        rect: layout.tangentCard, s: s) {
                TangentArt(time: clock.cardTime, s: s)
            }
            .rise(clock.progress(0.5, 1.1), distance: 14 * s, rect: layout.tangentCard, s: s)

            // Wordmark and tagline
            VStack(spacing: 30 * s) {
                // Written in by one pen moving at a steady pace through every letter.
                let pen = Ease.inOutSine(clock.progress(0.1, 1.9))
                HStack(alignment: .lastTextBaseline, spacing: 0) {
                    ForEach(WordmarkMetrics.letters) { letter in
                        Text(String(letter.character))
                            .mask(alignment: .topLeading) {
                                DrawnLetter(letter: letter, progress: letter.progress(pen: pen), s: s)
                            }
                    }
                }
                .foregroundStyle(Color.black)
                .font(.system(size: WordmarkMetrics.size * s, weight: .semibold, design: .rounded))
                .tracking(WordmarkMetrics.tracking * WordmarkMetrics.size * s)
                .fixedSize()
                .transformAnchorPreference(key: TextAnchorsKey.self, value: .bounds) { $0[.wordmark] = $1 }

                Text(Self.tagline)
                    .font(.system(size: 21 * textScale, weight: .regular, design: .rounded))
                    .foregroundStyle(Landing.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5 * textScale)
                    .frame(maxWidth: 760 * textScale)
                    .fixedSize(horizontal: false, vertical: true)
                    .transformAnchorPreference(key: TextAnchorsKey.self, value: .bounds) { $0[.tagline] = $1 }
                    .opacity(Ease.out(clock.progress(1.75, 2.3)))
            }
            // Centred across the screen, and a little above the middle vertically (the optical centre).
            .frame(width: layout.screen.width, height: layout.screen.height * 0.92)

            // Open
            VStack {
                Spacer()
                OpenButton(action: leave)
                    .opacity(Ease.out(clock.progress(2.2, 2.7)))
                    .padding(.bottom, max(0, 60 * s - 12))
            }
            .frame(width: layout.screen.width, height: layout.screen.height)
        }
        .frame(width: layout.screen.width, height: layout.screen.height, alignment: .topLeading)
        // Highlighter goes under the text, like a real one; pen ink and cursors go over everything.
        .backgroundPreferenceValue(TextAnchorsKey.self) { anchors in
            ink(anchors, layout: layout, clock: clock, layer: .highlights)
        }
        .overlayPreferenceValue(TextAnchorsKey.self) { anchors in
            ink(anchors, layout: layout, clock: clock, layer: .pen)
        }
    }

    private func ink(_ anchors: [TextSlot: Anchor<CGRect>], layout: LandingLayout, clock: LandingClock,
                     layer: InkLayer.Layer) -> some View {
        GeometryReader { proxy in
            if let wordmark = anchors[.wordmark], let tagline = anchors[.tagline] {
                let frames = TextFrames(wordmark: proxy[wordmark], tagline: proxy[tagline], s: layout.s)
                InkLayer(plan: InkPlan(layout: layout, text: frames), clock: clock, s: layout.s, layer: layer)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Swipe

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !leaving else { return }
                // Follows the finger upwards; a pull downwards gives only a little, like a rubber band.
                let dy = value.translation.height
                lift = dy < 0 ? dy : 8 * log1p(dy / 8)
            }
            .onEnded { value in
                guard !leaving else { return }
                // Works during the intro too: a swipe always continues immediately.
                if value.translation.height < -60 || value.predictedEndTranslation.height < -160 {
                    leave()
                } else {
                    withAnimation(.spring(duration: 0.35, bounce: 0.25)) { lift = 0 }
                }
            }
    }

    /// Slides the whole page up and off the screen, then hands over to the app.
    private func leave() {
        guard !leaving else { return }
        leaving = true
        onLeave()
        withAnimation(.spring(duration: 0.55, bounce: 0)) {
            lift = -height - 40
        } completion: {
            onContinue()
        }
    }
}

// MARK: - Constants, clock and layout

enum Landing {
    static let background = Color.white   // the note paper colour
    static let secondary = Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255)
    /// The note's blue pen.
    static let blue = Color(uiColor: UIColor(hex: InkSwatch.blueHex))
    /// Agent pen ink and cursors are blue: blue means "the agent wrote this". The one exception is the highlighter.
    static let agentInk = AgentColor(InkSwatch.blueHex)
    /// The highlighter agent's cursor: the note's yellow highlighter at full strength.
    static let highlighter = Color(uiColor: UIColor(hex: InkSwatch.yellowHighlighter.inkHex))
    /// What the highlighter agent leaves on the page: the note's yellow highlighter ink, so the two match.
    static let highlighterInk = Color(uiColor: InkSwatch.yellowHighlighter.inkColor)

    /// SF Pro Rounded as a UIFont, for measuring text laid out with `.system(design: .rounded)`.
    static func rounded(size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
    static let cyan = Color(red: 0x58 / 255, green: 0xC4 / 255, blue: 0xDD / 255)
    static let card = Color(red: 0x0E / 255, green: 0x0E / 255, blue: 0x10 / 255)
    /// The note's highlighter yellow, at full strength.
    static let yellow = highlighter
}

enum Ease {
    static func inOut(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
    static func out(_ x: Double) -> Double { 1 - pow(1 - min(1, max(0, x)), 3) }
    static func inOutSine(_ x: Double) -> Double { 0.5 - 0.5 * cos(.pi * min(1, max(0, x))) }
}

struct LandingClock {
    /// The cursor/ink sequence plays once, starting when the cursors appear; the ink then stays on the page.
    static let cursorsAt = 0.35
    /// Period of the cursors' slow idle drift.
    static let drift = 10.5

    /// Seconds since the landing appeared.
    let t: Double
    /// Reduce Motion: one still frame with everything finished.
    let still: Bool

    /// 0…1 between two times (1 when still).
    func progress(_ a: Double, _ b: Double) -> Double { still ? 1 : min(1, max(0, (t - a) / (b - a))) }

    /// Time since the cursors appeared, or nil before then. Reduce Motion: long enough for every mark to be done.
    var inkTime: Double? {
        if still { return 60 }
        guard t >= Self.cursorsAt else { return nil }
        return t - Self.cursorsAt
    }

    var cursorOpacity: Double { Ease.out(progress(Self.cursorsAt, Self.cursorsAt + 0.3)) }
    var cardTime: Double { still ? 1.2 : t }
}

/// Design space: the 1194 × 834 landscape reference, stretched along whichever axis the screen has extra room.
struct LandingLayout {
    let screen: CGSize
    let s: CGFloat
    let design: CGSize
    /// The window's safe area, for `pagePoints`.
    var safe = EdgeInsets()

    /// The cards' title bar: the real card's 48 pt, at the landing cards' scale.
    static let headerHeight: CGFloat = 38
    /// Both cards are the same size, in the proportions of a visualization card.
    static let cardSize = CGSize(width: 270, height: 230)

    init(screen: CGSize, safe: EdgeInsets = EdgeInsets()) {
        self.screen = screen
        self.safe = safe
        s = max(0.01, min(screen.width / 1194, screen.height / 834))
        design = CGSize(width: screen.width / s, height: screen.height / s)
    }

    /// Page points per design point: how long the same mark would be on a Letter page open in the canvas on this
    /// screen. Ink is timed in page points (`AgentPacing`), so it crosses the screen as fast as the agent's does there.
    var pagePoints: CGFloat {
        let fit = ZoomScrollView.fit(page: SamplePDF.letter.size, in: screen,
                                     top: safe.top + ZoomScrollView.chromeTop, bottom: safe.bottom + ZoomScrollView.chromeBottom,
                                     side: 32)
        return s / fit
    }

    var atomCard: CGRect { CGRect(origin: CGPoint(x: 48, y: 70), size: Self.cardSize) }
    var tangentCard: CGRect {
        CGRect(origin: CGPoint(x: design.width - 48 - Self.cardSize.width,
                               y: design.height - 104 - Self.cardSize.height), size: Self.cardSize)
    }
    var nucleus: CGPoint {
        CGPoint(x: atomCard.midX, y: atomCard.minY + Self.headerHeight + (atomCard.height - Self.headerHeight) / 2)
    }
}

/// Font metrics for the wordmark, used to find its baseline and cap height inside the measured text frame.
enum WordmarkMetrics {
    static let size: CGFloat = 120
    static let tracking: CGFloat = -0.035

    static let font = Landing.rounded(size: size, weight: .semibold)

    /// One letter of the wordmark and its share of the pen's journey through the word (0…1).
    struct Letter: Identifiable {
        let id: Int
        let character: Character
        let start: Double
        let end: Double

        /// How much of this letter is written when the pen is `pen` (0…1) of the way through the word.
        func progress(pen: Double) -> Double { min(1, max(0, (pen - start) / (end - start))) }

        /// The glyph's ink box at `size`, in the letter's own text coordinates (y down from the line's top).
        var ink: CGRect {
            let ct = font as CTFont
            var chars = Array(String(character).utf16), glyph = CGGlyph(0), box = CGRect.zero
            CTFontGetGlyphsForCharacters(ct, &chars, &glyph, 1)
            CTFontGetBoundingRectsForGlyphs(ct, .default, &glyph, &box, 1)
            return CGRect(x: box.minX, y: font.ascender - box.maxY, width: box.width, height: box.height)
        }
    }

    /// "Scribe", letter by letter. Each letter's share is roughly the length of its pen path, so the pen moves at an
    /// even speed through the whole word instead of stopping and starting at every letter.
    static let letters: [Letter] = {
        let weights: [(Character, Double)] = [("S", 1.0), ("c", 0.6), ("r", 0.5), ("i", 0.35), ("b", 0.85), ("e", 0.75)]
        let total = weights.reduce(0) { $0 + $1.1 }
        var at = 0.0
        return weights.enumerated().map { i, entry in
            defer { at += entry.1 }
            return Letter(id: i, character: entry.0, start: at / total, end: (at + entry.1) / total)
        }
    }()
}

// MARK: - Drawn letters

/// A pen stroke along a letter's spine, trimmed to `progress`. As a mask it writes the letter in; at 24 pt wide (at
/// the 120 pt wordmark size) it covers every pixel of each glyph by the end.
private struct DrawnLetter: View {
    let letter: WordmarkMetrics.Letter
    let progress: Double
    let s: CGFloat

    var body: some View {
        if progress >= 1 {
            Rectangle()
        } else {
            ZStack {
                // A soft edge, so the letter seems to flow in as ink rather than being cut out.
                LetterSpine(letter: letter, s: s)
                    .trim(from: 0, to: progress)
                    .stroke(style: StrokeStyle(lineWidth: 24 * s, lineCap: .round, lineJoin: .round))
                    .blur(radius: 2.5 * s)
                // Settles to the exact glyph over the last moment.
                Rectangle().opacity(max(0, (progress - 0.85) / 0.15))
            }
        }
    }
}

/// The path a pen takes to write each wordmark letter, in the order a hand would write it.
private struct LetterSpine: Shape {
    let letter: WordmarkMetrics.Letter
    let s: CGFloat

    func path(in rect: CGRect) -> Path {
        let ink = letter.ink
        let w = ink.width, h = ink.height
        // Half the stem weight, in points at the 120 pt wordmark size.
        let half: CGFloat = 8
        var path = Path()

        func u(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }
        /// An elliptical arc from `a0` to `a1` degrees (y down, so increasing angles turn clockwise).
        func arc(_ c: CGPoint, _ rx: CGFloat, _ ry: CGFloat, _ a0: CGFloat, _ a1: CGFloat, move: Bool) {
            let n = 60
            for i in 0...n {
                let a = (a0 + (a1 - a0) * CGFloat(i) / CGFloat(n)) * .pi / 180
                let p = CGPoint(x: c.x + rx * cos(a), y: c.y + ry * sin(a))
                if i == 0 && move { path.move(to: p) } else { path.addLine(to: p) }
            }
        }

        switch letter.character {
        case "S":
            path.move(to: u(0.87, 0.21))
            path.addCurve(to: u(0.48, 0.06), control1: u(0.80, 0.09), control2: u(0.64, 0.06))
            path.addCurve(to: u(0.13, 0.29), control1: u(0.27, 0.06), control2: u(0.13, 0.15))
            path.addCurve(to: u(0.50, 0.52), control1: u(0.13, 0.44), control2: u(0.33, 0.47))
            path.addCurve(to: u(0.87, 0.74), control1: u(0.70, 0.57), control2: u(0.87, 0.61))
            path.addCurve(to: u(0.49, 0.94), control1: u(0.87, 0.88), control2: u(0.70, 0.94))
            path.addCurve(to: u(0.11, 0.76), control1: u(0.28, 0.94), control2: u(0.13, 0.87))
        case "c":
            arc(CGPoint(x: w / 2, y: h / 2), w / 2 - half, h / 2 - half, -38, -322, move: true)
        case "r":
            // Stem down, then back up for the arm.
            path.move(to: CGPoint(x: half, y: half)); path.addLine(to: CGPoint(x: half, y: h - half))
            path.move(to: CGPoint(x: half, y: h * 0.42))
            path.addCurve(to: CGPoint(x: w - half * 0.7, y: half),
                          control1: CGPoint(x: half + w * 0.12, y: half * 1.2), control2: CGPoint(x: w * 0.6, y: half))
        case "i":
            // Stem, then the dot.
            path.move(to: CGPoint(x: w / 2, y: h * 0.30 + half)); path.addLine(to: CGPoint(x: w / 2, y: h - half))
            path.move(to: CGPoint(x: w / 2, y: w / 2 - 0.5)); path.addLine(to: CGPoint(x: w / 2, y: w / 2 + 0.5))
        case "b":
            // Stem down, then the bowl from its left side, over the top and round.
            path.move(to: CGPoint(x: half, y: half)); path.addLine(to: CGPoint(x: half, y: h - half))
            let top = h * 0.30
            arc(CGPoint(x: w / 2 + half / 2, y: (top + h) / 2), (w - half) / 2 - half / 2 - 1, (h - top) / 2 - half,
                180, 540, move: true)
        case "e":
            // The crossbar, then round over the top and down to the tail.
            path.move(to: CGPoint(x: half, y: h / 2)); path.addLine(to: CGPoint(x: w - half, y: h / 2))
            arc(CGPoint(x: w / 2, y: h / 2), w / 2 - half, h / 2 - half, 0, -318, move: false)
        default:
            path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
        }

        let place = CGAffineTransform(translationX: rect.minX, y: rect.minY)
            .scaledBy(x: s, y: s)
            .translatedBy(x: ink.minX, y: ink.minY)
        return path.applying(place)
    }
}

// MARK: - Measured text frames

private enum TextSlot: Hashable { case wordmark, tagline }

private struct TextAnchorsKey: PreferenceKey {
    static var defaultValue: [TextSlot: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [TextSlot: Anchor<CGRect>], nextValue: () -> [TextSlot: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The measured text frames, converted to design points.
struct TextFrames {
    let wordmark: CGRect
    let tagline: CGRect

    init(wordmark: CGRect, tagline: CGRect, s: CGFloat) {
        func design(_ r: CGRect) -> CGRect { CGRect(x: r.minX / s, y: r.minY / s, width: r.width / s, height: r.height / s) }
        self.wordmark = design(wordmark)
        self.tagline = design(tagline)
    }

    var baseline: CGFloat { wordmark.minY + WordmarkMetrics.font.ascender }
    var capHeight: CGFloat { WordmarkMetrics.font.capHeight }
}

// MARK: - Ink

/// One hand-drawn stroke: a dense polyline (with a little wobble) and its timing in the ink sequence.
///
/// Timing follows the canvas agent (`AgentPacing`): a stroke never starts before `earliest`, nor before the cursor
/// has finished the previous one and flown over; and it takes as long as the same mark would in the app.
struct InkStroke {
    /// Which agent action this stroke stands for, for its duration.
    enum Pace { case stroke, circle, arrow, check, label }

    /// For a stroke, the ink itself. For a label, the line the cursor rides along while it writes.
    let points: [CGPoint]
    let lengths: [CGFloat]
    let earliest: Double
    let pace: Pace
    let width: CGFloat
    /// Handwriting: the canvas agent's own `writeLabel`, drawn by `AgentRenderer` exactly as on a page.
    let label: AgentAction?
    /// A highlighter swipe: translucent, flat-ended and multiplied over the text beneath it.
    let highlight: Bool
    /// Set when the cursor's strokes are scheduled.
    fileprivate(set) var start: Double = 0
    /// Page points per design point (`LandingLayout.pagePoints`), set when scheduled.
    fileprivate(set) var pageScale: CGFloat = 1

    var end: Double { start + duration }
    var total: CGFloat { lengths.last ?? 0 }

    var duration: Double {
        switch pace {
        case .stroke: AgentPacing.strokeDuration(length: total * pageScale)
        case .circle: AgentPacing.circle
        case .arrow: AgentPacing.arrow
        case .check: AgentPacing.check
        case .label: label?.duration ?? 0
        }
    }

    /// Writes `text` centred on `at`, in the agent's handwriting, at the agent's writing speed.
    init(write text: String, at: CGPoint, size: CGFloat, color: AgentColor, after earliest: Double) {
        let action = AgentAction.writeLabel(text: text, at: at, color: color, size: size)
        let from = AgentGeometry.cursorPoint(for: action, progress: 0) ?? at
        let to = AgentGeometry.cursorPoint(for: action, progress: 1) ?? at
        points = [from, to]
        lengths = [0, hypot(to.x - from.x, to.y - from.y)]
        self.earliest = earliest
        pace = .label
        width = 0
        label = action
        highlight = false
    }

    init(_ raw: [CGPoint], _ pace: Pace = .stroke, after earliest: Double, width: CGFloat, seed: Double, wobble: CGFloat = 1,
         highlight: Bool = false) {
        self.highlight = highlight
        let base = Self.cumulative(raw)
        var wobbly = raw
        for i in raw.indices {
            let a = raw[max(0, i - 1)], b = raw[min(raw.count - 1, i + 1)]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = max(0.0001, hypot(dx, dy))
            let along = Double(base[i])
            let offset = wobble * CGFloat(0.9 * sin(along / 21 + seed) + 0.45 * sin(along / 8.5 + 2.3 * seed))
            wobbly[i] = CGPoint(x: raw[i].x - dy / len * offset, y: raw[i].y + dx / len * offset)
        }
        points = wobbly
        lengths = Self.cumulative(wobbly)
        self.pace = pace
        self.earliest = earliest
        self.width = width
        label = nil
    }

    /// The point a fraction `f` of the way along the stroke, and the index of the first point after it.
    func location(at f: Double) -> (index: Int, point: CGPoint) {
        let target = CGFloat(min(1, max(0, f))) * total
        var lo = 0, hi = lengths.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if lengths[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return (0, points[0]) }
        let l0 = lengths[lo - 1], l1 = lengths[lo]
        let k = l1 > l0 ? (target - l0) / (l1 - l0) : 1
        return (lo, lerp(points[lo - 1], points[lo], k))
    }

    /// The stroke up to `f`, smoothed: quadratic curves through the midpoints, so no corners show.
    func path(to f: Double) -> Path {
        var path = Path()
        guard f > 0, points.count > 1 else { return path }
        let (index, tip) = location(at: f)
        let pts = Array(points[0..<max(1, index)]) + [tip]
        path.move(to: pts[0])
        guard pts.count > 2 else { path.addLine(to: tip); return path }
        for j in 1..<(pts.count - 1) {
            path.addQuadCurve(to: lerp(pts[j], pts[j + 1], 0.5), control: pts[j])
        }
        path.addLine(to: tip)
        return path
    }

    private static func cumulative(_ pts: [CGPoint]) -> [CGFloat] {
        var out: [CGFloat] = [0]
        out.reserveCapacity(pts.count)
        for i in pts.indices.dropFirst() {
            out.append(out[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
        }
        return out
    }

    /// A polyline through `vertices`, resampled every few points.
    static func dense(_ vertices: [CGPoint], step: CGFloat = 3) -> [CGPoint] {
        var out = [vertices[0]]
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            let n = max(1, Int(ceil(hypot(b.x - a.x, b.y - a.y) / step)))
            for k in 1...n { out.append(lerp(a, b, CGFloat(k) / CGFloat(n))) }
        }
        return out
    }

    /// `n + 1` samples of a parametric curve on 0…1.
    static func curve(_ n: Int, _ f: (Double) -> CGPoint) -> [CGPoint] {
        (0...n).map { f(Double($0) / Double(n)) }
    }

    static func cubic(_ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p1: CGPoint, n: Int = 70) -> [CGPoint] {
        curve(n) { u in
            let v = 1 - u
            let a = v * v * v, b = 3 * v * v * u, c = 3 * v * u * u, d = u * u * u
            return CGPoint(x: a * p0.x + b * c1.x + c * c2.x + d * p1.x,
                           y: a * p0.y + b * c1.y + c * c2.y + d * p1.y)
        }
    }
}

func lerp(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
}

/// One agent cursor and the strokes its tip draws.
struct CursorTrack {
    let color: Color
    let size: CGFloat
    let tag: String?
    let strokes: [InkStroke]
    let seed: Double
    /// Where the cursor waits before its first mark (default: that mark's start).
    let home: CGPoint?
    /// The tag's text colour, for contrast on the cursor colour.
    let tagText: Color

    init(color: Color, size: CGFloat, tag: String?, tagText: Color = .white, pageScale: CGFloat, strokes: [InkStroke],
         seed: Double, home: CGPoint? = nil) {
        self.home = home
        self.tagText = tagText
        self.color = color
        self.size = size
        self.tag = tag
        self.seed = seed
        var scheduled = strokes
        var free = -Double.infinity
        // Like `AgentScriptPlayer`: fly to the mark's start, draw it, go straight on to the next.
        for i in scheduled.indices {
            scheduled[i].pageScale = pageScale
            scheduled[i].start = max(scheduled[i].earliest, free + AgentPacing.travel)
            free = scheduled[i].end
        }
        self.strokes = scheduled
    }

    /// Where the tip is at ink time `L`: waiting at the first stroke's start, on a stroke while drawing, flying
    /// (≤ 0.35 s) to the next stroke's start, or, once done, drifting a little around the last stroke's end.
    func tip(at L: Double, still: Bool) -> CGPoint {
        if let stroke = strokes.first(where: { L >= $0.start && L <= $0.end }) {
            let p = Easing.inOut((L - stroke.start) / stroke.duration)
            if let label = stroke.label, let tip = AgentGeometry.cursorPoint(for: label, progress: p) { return tip }
            return stroke.location(at: p).point
        }
        let prev = strokes.last(where: { $0.end < L })
        let prevEnd = prev?.end ?? 0
        let rest = prev?.points.last ?? home ?? strokes[0].points[0]

        func idle(_ time: Double) -> CGPoint {
            guard !still else { return rest }
            let ramp = Ease.inOut((time - prevEnd) / 0.5)
            // A slow, slight drift while the agent waits.
            let w = 2 * Double.pi / LandingClock.drift
            return CGPoint(x: rest.x + 2.5 * ramp * sin(w * time + seed),
                           y: rest.y + 2 * ramp * sin(2 * w * time + 1.7 * seed))
        }

        // After the last mark, the cursor just waits.
        guard let next = strokes.first(where: { $0.start > L }) else { return idle(L) }
        let nextStart = next.start, target = next.points[0]

        // Like `AgentScriptPlayer.travel`: a fixed-time, smoothstep flight to the next mark's start.
        let fly = min(AgentPacing.travel, nextStart - prevEnd)
        let depart = nextStart - fly
        if L < depart || still { return idle(L) }
        return lerp(idle(depart), target, Easing.inOut((L - depart) / fly))
    }
}

/// All three cursors' strokes, placed from the layout and the measured text frames (design points).
struct InkPlan {
    let tracks: [CursorTrack]

    init(layout: LandingLayout, text: TextFrames) {
        let k = layout.pagePoints
        typealias S = InkStroke
        let wm = text.wordmark, baseline = text.baseline, cap = text.capHeight

        // Centre: a loose ellipse around "Scribe".
        let center = CGPoint(x: wm.midX, y: baseline - cap / 2)
        let rx = wm.width / 2 + 34, ry = cap / 2 + 30, tilt = -0.06
        // Starts top right and goes clockwise for 1.1 turns, finishing on the right side so the resting cursor and
        // its tag sit beside the word, not on it.
        let ellipse = S.curve(480) { u in
            let a = 5.31 + u * 1.1 * 2 * .pi
            let grow = 1 + 0.07 * u
            let x = rx * grow * cos(a), y = ry * grow * sin(a)
            return CGPoint(x: center.x + x * cos(tilt) - y * sin(tilt), y: center.y + x * sin(tilt) + y * cos(tilt))
        }

        let wordmark = CursorTrack(color: Landing.blue, size: 28, tag: "Agent", pageScale: k, strokes: [
            S(ellipse, .circle, after: 2.1, width: 3.5, seed: 1.9, wobble: 0.45),
        ], seed: 0.6, home: CGPoint(x: center.x + rx + 40, y: center.y - ry - 10))

        // Top right: works out a derivative, sketches it, then points at the Tangent line card,
        // which plots the same f(x) = x³/3 − x with its slope live.
        let o = CGPoint(x: layout.design.width - 48 - 300, y: 50)
        func op(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x, y: o.y + y) }
        func f(_ x: Double) -> Double { x * x * x / 3 - x }
        func sketch(_ x: Double) -> CGPoint { op(150 + 55 * x, 140 - 30 * f(x)) }
        let cubic = S.curve(80) { u in sketch(-2.25 + 4.5 * u) }
        let x0 = 1.5, m = -30 * (x0 * x0 - 1) / 55   // the slope in sketch space
        let touch = sketch(x0)
        let tangent = S.dense([CGPoint(x: touch.x - 48, y: touch.y - 48 * m),
                               CGPoint(x: touch.x + 48, y: touch.y + 48 * m)])
        let card = layout.tangentCard
        let from = op(230, 200), to = CGPoint(x: card.minX + 90, y: card.minY - 14) // Its tag clear of the card's buttons.
        let drop = to.y - from.y
        let c1 = CGPoint(x: from.x + 60, y: from.y + drop * 0.35)
        let c2 = CGPoint(x: to.x + 60, y: to.y - drop * 0.3)
        var arrow = S.cubic(from, c1, c2, to, n: max(60, Int(drop / 4)))
        let heading = atan2(to.y - c2.y, to.x - c2.x)
        func wing(_ side: Double) -> CGPoint {
            CGPoint(x: to.x - 15 * cos(heading + side * 0.5), y: to.y - 15 * sin(heading + side * 0.5))
        }
        arrow += S.dense([to, wing(1), to, wing(-1)], step: 2).dropFirst()

        let topRight = CursorTrack(color: Landing.blue, size: 24, tag: "Agent", pageScale: k, strokes: [
            S(write: "f(x) = x³/3 - x", at: op(110, 22), size: 26, color: Landing.agentInk, after: 0.7),
            S(write: "f'(x) = x² - 1", at: op(110, 58), size: 26, color: Landing.agentInk, after: 1.15),
            S(cubic, after: 1.75, width: 3, seed: 2.2),
            S(tangent, after: 2.25, width: 2.5, seed: 4.0, wobble: 0.6),
            S(arrow, after: 2.25, width: 3, seed: 5.3, wobble: 0.6),
        ], seed: 2.4)

        // Bottom left: circles the nucleus, then explains the light it gives off: E = hc / wavelength,
        // a wave, and one wavelength marked on it.
        let n = layout.nucleus
        let ring = S.curve(90) { u in
            let a = -2.1 + u * 1.06 * 2 * .pi
            let r = 31 + 4 * u
            return CGPoint(x: n.x + r * cos(a), y: n.y + r * 0.92 * sin(a))
        }
        let g = CGPoint(x: 72, y: layout.design.height - 104 - 220)
        func gp(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: g.x + x, y: g.y + y) }
        let wavelength: CGFloat = 96
        let wave = S.curve(120) { u in
            let x = 20 + 240 * u
            return gp(x, 95 - 20 * sin(2 * .pi * (x - 20) / wavelength))
        }
        // Crest to crest: the first two crests are at x = 44 and 140.
        let bracket = S.dense([gp(44, 128), gp(44, 140), gp(44 + wavelength, 140), gp(44 + wavelength, 128)])

        let bottomLeft = CursorTrack(color: Landing.blue, size: 24, tag: "Agent", pageScale: k, strokes: [
            S(ring, .circle, after: 0.9, width: 3, seed: 3.8),
            S(write: "E = hc / wavelength", at: gp(130, 22), size: 26, color: Landing.agentInk, after: 1.5),
            S(wave, after: 2.0, width: 3, seed: 1.3, wobble: 0.6),
            S(bracket, after: 2.5, width: 2.5, seed: 2.7, wobble: 0.4),
            S(write: "one wavelength", at: gp(92, 164), size: 22, color: Landing.agentInk, after: 3.0),
        ], seed: 4.1)

        // Yellow highlighter: marks the heart of the tagline, "help you learn", at the end of its second line.
        let tagSize = 21 * max(layout.s, 0.85) / layout.s
        let tagFont = Landing.rounded(size: tagSize, weight: .regular)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: tagFont]).width }
        let line = String(LandingView.tagline.split(separator: "\n").last ?? "")
        let key = LandingView.taglineKey
        let keyStart = line.range(of: key).map { String(line[..<$0.lowerBound]) } ?? ""
        let tg = text.tagline
        let hx = tg.midX - width(line) / 2 + width(keyStart), hw = width(key)
        let hy = tg.maxY - tagFont.lineHeight * 0.5
        let swipe = S.dense([CGPoint(x: hx - 5, y: hy + 1.5), CGPoint(x: hx + hw + 5, y: hy - 1.5)], step: 3)
        let highlighter = CursorTrack(color: Landing.highlighter, size: 24, tag: "Agent", tagText: .black, pageScale: k,
                                      strokes: [
            S(swipe, after: 2.9, width: tagFont.lineHeight * 0.8, seed: 0.9, wobble: 0.35, highlight: true),
        ], seed: 5.2, home: CGPoint(x: hx + hw + 36, y: hy + 44))

        tracks = [wordmark, topRight, bottomLeft, highlighter]
    }
}

/// The agents' marks. Drawn twice: highlights under the page's text, then pen ink and cursors over everything.
private struct InkLayer: View {
    enum Layer { case highlights, pen }

    let plan: InkPlan
    let clock: LandingClock
    let s: CGFloat
    let layer: Layer

    var body: some View {
        Canvas { context, _ in
            guard let L = clock.inkTime else { return }

            var ink = context
            ink.scaleBy(x: s, y: s)
            for track in plan.tracks {
                for stroke in track.strokes where L >= stroke.start && stroke.highlight == (layer == .highlights) {
                    let f = Easing.inOut(min(1, (L - stroke.start) / stroke.duration))
                    if let label = stroke.label {
                        AgentRenderer.draw(label, progress: f, seed: 0, in: &ink)
                    } else if stroke.highlight {
                        ink.stroke(stroke.path(to: f), with: .color(Landing.highlighterInk),
                                   style: StrokeStyle(lineWidth: stroke.width, lineCap: .butt, lineJoin: .round))
                    } else {
                        ink.stroke(stroke.path(to: f), with: .color(track.color),
                                   style: StrokeStyle(lineWidth: stroke.width, lineCap: .round, lineJoin: .round))
                    }
                }
            }

            guard layer == .pen else { return }
            let opacity = clock.cursorOpacity
            guard opacity > 0 else { return }
            for (index, track) in plan.tracks.enumerated() {
                let p = track.tip(at: L, still: clock.still)
                drawCursor(track, symbol: context.resolveSymbol(id: index),
                           at: CGPoint(x: p.x * s, y: p.y * s), in: &context, opacity: opacity)
            }
        } symbols: {
            ForEach(Array(plan.tracks.enumerated()), id: \.offset) { index, track in
                CursorGlyph(color: track.color, size: track.size).tag(index)
            }
        }
    }

    private func drawCursor(_ track: CursorTrack, symbol: GraphicsContext.ResolvedSymbol?, at tip: CGPoint,
                            in context: inout GraphicsContext, opacity: Double) {
        guard let symbol else { return }
        context.drawLayer { layer in
            layer.opacity = opacity
            // The Lucide pointer's tip sits at (4.04, 4.04) in its 24 pt box; the glyph has a 3 pt margin.
            let inset = 3 + track.size * 4.04 / 24
            layer.draw(symbol, at: CGPoint(x: tip.x - inset, y: tip.y - inset), anchor: .topLeading)

            if let tag = track.tag {
                let text = layer.resolve(Text(tag)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(track.tagText))
                let size = text.measure(in: CGSize(width: 200, height: 40))
                let pill = CGRect(x: tip.x + 20, y: tip.y + 24, width: size.width + 16, height: size.height + 6)
                layer.fill(Path(roundedRect: pill, cornerRadius: 9), with: .color(track.color))
                layer.draw(text, at: CGPoint(x: pill.midX, y: pill.midY), anchor: .center)
            }
        }
    }
}

/// The filled Lucide pointer in its colour, with a 1.5 pt white outline and a soft shadow.
struct CursorGlyph: View {
    let color: Color
    let size: CGFloat

    var body: some View {
        let glyph = Image("Cursor").renderingMode(.template).resizable().frame(width: size, height: size)
        ZStack {
            ForEach(0..<12, id: \.self) { k in
                let angle = Double(k) / 12 * 2 * .pi
                glyph.foregroundStyle(.white).offset(x: 1.5 * cos(angle), y: 1.5 * sin(angle))
            }
            glyph.foregroundStyle(color)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: 3, x: 0, y: 1.5)
        .padding(3)
    }
}

// MARK: - Background and hint

/// The same dots as a notebook page inside a note (`PageBackgroundView`), on white paper.
private struct DotGrid: View {
    var body: some View {
        GeometryReader { geo in
            PageBackgroundView(style: .dots, regions: [CGRect(origin: .zero, size: geo.size)])
        }
        .background(Landing.background)
    }
}

/// Opens the library. The one main action on the page, so it's the filled button.
private struct OpenButton: View {
    let action: () -> Void

    var body: some View {
        // The same size as the app's other filled buttons (New Note, Try Again).
        Button("Open", action: action)
            .primaryActionButton()
    }
}

// MARK: - Cards

/// A sample visualization card, made like the real ones (`VisualizationCard`) at a smaller scale: the title and the
/// Pause, More and Close buttons on top, the picture, and a grey readout under it when something changes.
private struct LandingCard<Art: View>: View {
    let title: String
    var readout: String? = nil
    let rect: CGRect
    let s: CGFloat
    @ViewBuilder let art: Art

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(title)
                    .font(.system(size: 13 * s, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 8 * s)
                HStack(spacing: 6 * s) {
                    ForEach(["pause.fill", "ellipsis", "xmark"], id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 10 * s, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24 * s, height: 24 * s)
                            .background(.white.opacity(0.12), in: Circle())
                    }
                }
            }
            .padding(.leading, 14 * s)
            .padding(.trailing, 8 * s)
            .frame(height: LandingLayout.headerHeight * s)

            art.frame(maxWidth: .infinity, maxHeight: .infinity)

            if let readout {
                Text(readout)
                    .font(.system(size: 11 * s, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14 * s)
                    .padding(.top, 4 * s)
                    .padding(.bottom, 10 * s)
            }
        }
        .padding(.bottom, readout == nil ? 6 * s : 0)
        .frame(width: rect.width * s, height: rect.height * s)
        .background(Landing.card, in: RoundedRectangle(cornerRadius: 18 * s, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 16 * s, x: 0, y: 10 * s)
        .accessibilityHidden(true)
    }
}

private extension View {
    /// Places a card at its design rect, fading in while rising `distance` points.
    func rise(_ progress: Double, distance: CGFloat, rect: CGRect, s: CGFloat) -> some View {
        let eased = Ease.out(progress)
        return opacity(eased).offset(x: rect.minX * s, y: rect.minY * s + (1 - eased) * distance)
    }
}

/// A 3D atom, projected to 2D: 12 shaded nucleons and three tilted orbits, spinning around the vertical axis.
struct AtomArt: View {
    let time: Double
    let s: CGFloat

    private typealias V3 = SIMD3<Double>

    /// The nucleus: an icosahedron's 12 vertices, alternating protons and neutrons.
    private static let nucleons: [(V3, Bool)] = {
        let phi = (1 + sqrt(5.0)) / 2
        var vertices: [V3] = []
        for a in [-1.0, 1] {
            for b in [-phi, phi] {
                vertices += [V3(0, a, b), V3(a, b, 0), V3(b, 0, a)]
            }
        }
        return vertices.enumerated().map { i, v in
            (v / (v * v).sum().squareRoot() * 9.5, i % 2 == 0)
        }
    }()

    /// A point on orbit `k`: a circle of radius 72 tilted 70° about x, then turned k·60° about the view axis.
    private static func orbit(_ k: Int, _ theta: Double) -> V3 {
        let r = 72.0, tilt = 70 * Double.pi / 180, turn = Double(k) * .pi / 3
        let x = r * cos(theta), y0 = r * sin(theta)
        let y = y0 * cos(tilt), z = y0 * sin(tilt)
        return V3(x * cos(turn) - y * sin(turn), x * sin(turn) + y * cos(turn), z)
    }

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: s, y: s)
            let c = CGPoint(x: size.width / s / 2, y: size.height / s / 2)
            let spin = 0.9 * time
            let camera = 420.0

            func project(_ p: V3) -> (point: CGPoint, z: Double, f: Double) {
                let x = p.x * cos(spin) + p.z * sin(spin)
                let z = -p.x * sin(spin) + p.z * cos(spin)
                let f = camera / (camera - z)
                return (CGPoint(x: c.x + x * f, y: c.y - p.y * f), z, f)
            }

            // Orbits, split into the halves behind and in front of the nucleus.
            var back = Path(), front = Path()
            let segments = 96
            for k in 0..<3 {
                var previous = project(Self.orbit(k, 0))
                for i in 1...segments {
                    let current = project(Self.orbit(k, Double(i) / Double(segments) * 2 * .pi))
                    if previous.z + current.z < 0 {
                        back.move(to: previous.point); back.addLine(to: current.point)
                    } else {
                        front.move(to: previous.point); front.addLine(to: current.point)
                    }
                    previous = current
                }
            }

            let electrons = (0..<3).map { k in project(Self.orbit(k, 2.6 * time + Double(k) * 2 * .pi / 3)) }

            context.stroke(back, with: .color(Landing.cyan.opacity(0.18)), lineWidth: 1.2)
            for e in electrons where e.z < 0 { drawElectron(e.point, f: e.f, front: false, in: context) }

            for nucleon in Self.nucleons.map({ (project($0.0), $0.1) }).sorted(by: { $0.0.z < $1.0.z }) {
                drawSphere(at: nucleon.0.point, radius: 6.2 * nucleon.0.f, proton: nucleon.1, in: context)
            }

            context.stroke(front, with: .color(Landing.cyan.opacity(0.55)), lineWidth: 1.2)
            for e in electrons where e.z >= 0 { drawElectron(e.point, f: e.f, front: true, in: context) }
        }
        .accessibilityHidden(true)
    }

    private func drawSphere(at p: CGPoint, radius r: Double, proton: Bool, in context: GraphicsContext) {
        let colors: [Color] = proton
            ? [Color(red: 1, green: 0.62, blue: 0.6), Color(red: 0.88, green: 0.22, blue: 0.22), Color(red: 0.42, green: 0.05, blue: 0.07)]
            : [Color(white: 0.95), Color(white: 0.62), Color(white: 0.28)]
        let rect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        context.fill(Path(ellipseIn: rect), with: .radialGradient(
            Gradient(colors: colors), center: CGPoint(x: p.x - 0.35 * r, y: p.y - 0.4 * r),
            startRadius: 0, endRadius: 1.6 * r))
    }

    private func drawElectron(_ p: CGPoint, f: Double, front: Bool, in context: GraphicsContext) {
        if front {
            let glow = 12 * f
            context.fill(Path(ellipseIn: CGRect(x: p.x - glow, y: p.y - glow, width: 2 * glow, height: 2 * glow)),
                         with: .radialGradient(Gradient(colors: [Landing.cyan.opacity(0.65), Landing.cyan.opacity(0)]),
                                               center: p, startRadius: 0, endRadius: glow))
        }
        let r = (front ? 3.8 : 3.0) * f
        context.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(front ? Landing.cyan : Landing.cyan.opacity(0.4)))
    }
}

/// f(x) = x³/3 − x with a dashed tangent line riding along it.
struct TangentArt: View {
    let time: Double
    let s: CGFloat

    static func f(_ x: Double) -> Double { x * x * x / 3 - x }
    static func x0(time: Double) -> Double { 2.1 * sin(0.9 * time) }

    /// The live readout, written the way the agent's are: "Slope 0.25 at x = 1.12".
    static func readout(time: Double) -> String {
        let x = x0(time: time)
        return String(format: "Slope %.2f at x = %.2f", x * x - 1, x).replacingOccurrences(of: "-", with: "−")
    }

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: s, y: s)
            let w = size.width / s, h = size.height / s
            let pad = 18.0
            let sx = (w - 2 * pad) / 5.2, sy = (h - 20) / 6.8
            func map(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: pad + (x + 2.6) * sx, y: h / 2 - y * sy) }

            var axes = Path()
            axes.move(to: CGPoint(x: 10, y: h / 2)); axes.addLine(to: CGPoint(x: w - 10, y: h / 2))
            axes.move(to: map(0, 3.4)); axes.addLine(to: map(0, -3.4))
            context.stroke(axes, with: .color(.white.opacity(0.14)), lineWidth: 1)

            var curve = Path()
            for i in 0...120 {
                let x = -2.6 + 5.2 * Double(i) / 120
                i == 0 ? curve.move(to: map(x, Self.f(x))) : curve.addLine(to: map(x, Self.f(x)))
            }
            context.stroke(curve, with: .color(Landing.cyan), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            let x0 = Self.x0(time: time), y0 = Self.f(x0), m = x0 * x0 - 1
            var line = Path()
            line.move(to: map(x0 - 1.4, y0 - 1.4 * m)); line.addLine(to: map(x0 + 1.4, y0 + 1.4 * m))
            var clipped = context
            clipped.clip(to: Path(CGRect(x: 0, y: 0, width: w, height: h)))
            clipped.stroke(line, with: .color(Landing.yellow),
                           style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [8, 6]))

            let p = map(x0, y0)
            context.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)), with: .color(.white))
        }
        .clipShape(Rectangle())
        .accessibilityHidden(true)
    }
}

#Preview("Landscape", traits: .landscapeLeft) {
    LandingView {}
}

#Preview("Portrait", traits: .portrait) {
    LandingView {}
}
