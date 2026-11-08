import SwiftUI

// The agent's cursor on the canvas, as on the landing page (without the "Agent" tag): it comes out of the agent pill,
// flies to where it's about to draw, rides the pen tip while each mark is drawn, and goes back into the pill when the
// agent is done.

/// Where the cursor is going, and since when.
struct AgentCursor: Equatable {
    enum Spot: Equatable {
        /// Inside the agent pill at the top of the screen.
        case pill
        /// A point on the page, in page points.
        case page(CGPoint)
    }

    /// One trip out of the pill and back.
    var trip = UUID()
    var pageID: UUID
    var from: Spot
    var to: Spot
    var start: Date
    var duration: Double

    /// Resting at `spot`.
    static func resting(at spot: Spot, on pageID: UUID, trip: UUID) -> AgentCursor {
        AgentCursor(trip: trip, pageID: pageID, from: spot, to: spot, start: .now, duration: 0)
    }

    /// How long a flight between two spots takes: a little longer out of and back into the pill.
    static func flight(from a: Spot, to b: Spot) -> Double {
        switch (a, b) {
        case let (.page(p), .page(q)):
            min(0.5, max(0.22, 0.15 + Double(hypot(q.x - p.x, q.y - p.y)) / 1400))
        default:
            0.6
        }
    }
}

/// Screen frames the agent's cursor and placement need: each page, the agent pill, and whatever floats over the page.
/// Not observed: they change every frame of a scroll, and only the cursor (redrawn every frame anyway) and the start
/// of a drawing turn read them.
final class CanvasFrames {
    /// Each page's frame on screen (global points), as laid out right now.
    var pages: [UUID: CGRect] = [:]
    /// The agent pill (global points).
    var pill: CGRect?
    /// Floating controls and cards over the page (global points), by name.
    var floating: [String: CGRect] = [:]
    /// The screen the pages fill.
    var screen: CGSize = .zero

    /// Page points for a global point on `pageID`.
    func toPage(_ r: CGRect, on pageID: UUID) -> CGRect? {
        guard let frame = pages[pageID], frame.width > 0 else { return nil }
        let k = frame.width / NotePageMetrics.width
        return CGRect(x: (r.minX - frame.minX) / k, y: (r.minY - frame.minY) / k, width: r.width / k, height: r.height / k)
    }

    /// Global points for a page point on `pageID`.
    func toScreen(_ p: CGPoint, on pageID: UUID) -> CGPoint? {
        guard let frame = pages[pageID], frame.width > 0 else { return nil }
        let k = frame.width / NotePageMetrics.width
        return CGPoint(x: frame.minX + p.x * k, y: frame.minY + p.y * k)
    }

    /// Where the cursor comes out of the pill: the agent's dot at its leading end.
    var pillPoint: CGPoint? {
        pill.map { CGPoint(x: $0.minX + CanvasChromeMetrics.button / 2, y: $0.midY) }
    }
}

extension View {
    /// Reports this view's screen frame as something floating over the page, which the agent keeps its ink out from
    /// under.
    func floatingOverPage(_ name: String, in model: CanvasModel) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.frames.floating[name] = $0 }
            .onDisappear { model.frames.floating[name] = nil }
    }
}

/// The agent's cursor, over the pages and under the floating controls, so it comes out from under the pill.
struct AgentCursorLayer: View {
    let model: CanvasModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 24

    var body: some View {
        if let cursor = model.agentCursor {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                TimelineView(.animation) { timeline in
                    if let pose = pose(of: cursor, at: timeline.date) {
                        glyph(at: CGPoint(x: pose.tip.x - origin.x, y: pose.tip.y - origin.y), appear: pose.appear)
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func glyph(at tip: CGPoint, appear: Double) -> some View {
        // The pointer's tip sits at (4.04, 4.04) in its 24 pt box; the glyph has a 3 pt margin.
        let inset = 3 + Self.size * 4.04 / 24
        let box = Self.size + 6
        return CursorGlyph(color: Landing.blue, size: Self.size)
            .scaleEffect(0.35 + 0.65 * appear, anchor: UnitPoint(x: inset / box, y: inset / box))
            .opacity(appear)
            .offset(x: tip.x - inset, y: tip.y - inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The tip in global points, and how far out of the pill it is (0 inside, 1 fully out).
    private func pose(of cursor: AgentCursor, at date: Date) -> (tip: CGPoint, appear: Double)? {
        let frames = model.frames
        func screen(_ spot: AgentCursor.Spot) -> CGPoint? {
            switch spot {
            case .pill: frames.pillPoint
            case .page(let p): frames.toScreen(p, on: cursor.pageID)
            }
        }

        // Drawing: on the pen tip.
        if let live = model.liveMark, live.pageID == cursor.pageID,
           let mark = model.page(live.pageID)?.agentMarks.first(where: { $0.id == live.markID }),
           let tip = mark.tip(at: live.progress(at: date)), let point = frames.toScreen(tip, on: cursor.pageID) {
            return (point, 1)
        }

        guard let a = screen(cursor.from), let b = screen(cursor.to) else { return nil }
        let elapsed = date.timeIntervalSince(cursor.start)
        let t = cursor.duration > 0 ? min(1, max(0, elapsed / cursor.duration)) : 1
        let k = CGFloat(Ease.inOut(t))
        // A gentle arc, like a hand moving across the page.
        let dx = b.x - a.x, dy = b.y - a.y
        let bow = min(40, hypot(dx, dy) * 0.12) * sin(.pi * k)
        var tip = CGPoint(x: a.x + dx * k - dy / max(hypot(dx, dy), 1) * bow,
                          y: a.y + dy * k + dx / max(hypot(dx, dy), 1) * bow)

        var appear = 1.0
        if cursor.from == .pill { appear = min(appear, Ease.out(t / 0.35)) }
        if cursor.to == .pill { appear = min(appear, 1 - Ease.inOut((t - 0.6) / 0.4)) }

        // Waiting on the page: a slow, slight drift, as on the landing page.
        if t >= 1, cursor.to != .pill, !reduceMotion {
            let idle = elapsed - cursor.duration
            let ramp = Ease.inOut(idle / 0.5)
            let w = 2 * Double.pi / LandingClock.drift
            tip.x += 2.5 * ramp * sin(w * idle + 0.6)
            tip.y += 2 * ramp * sin(2 * w * idle + 1.0)
        }
        return (tip, appear)
    }
}
