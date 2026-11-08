import PDFKit
import SwiftUI
import UIKit

/// An imported PDF is a note like any other: each PDF page becomes a page in the note, with the PDF page as its paper
/// (instead of dots) and the person's ink, images, the agent's marks and cards on top. The PDF file itself is never
/// changed; `NotePage.pdfPage` says which of its pages a note page shows.
enum PDFPages {
    /// One note page per PDF page, each 1100 wide and as tall as that PDF page's shape needs.
    static func notePages(from url: URL) -> [NotePage] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let size = displaySize(of: page)
            guard size.width > 0, size.height > 0 else { return nil }
            return NotePage(height: (NotePageMetrics.width * size.height / size.width).rounded(), pdfPage: index)
        }
    }

    /// The page's size as it's shown, its rotation applied.
    static func displaySize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        return page.rotation % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// The PDF page `index` as an image `pixelWidth` pixels wide. Opens its own copy of the PDF, so it can run off the
    /// main thread.
    ///
    /// `PDFPage.thumbnail(of:)` draws one pixel per point of the size it's given, so it's asked for the size in pixels:
    /// asked for the size in points, a page is drawn at a half or a third of the screen's sharpness, and looks blurry.
    nonisolated static func image(url: URL, page index: Int, pixelWidth: CGFloat) -> UIImage? {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return nil }
        let size = displaySize(of: page)
        guard size.width > 0 else { return nil }
        let pixels = CGSize(width: pixelWidth.rounded(), height: (pixelWidth * size.height / size.width).rounded())
        return page.thumbnail(of: pixels, for: .cropBox)
    }

    /// Draws the PDF page, as vectors, into `rect` of a context whose y axis points down (PDF export).
    static func draw(url: URL, page index: Int, in rect: CGRect, context: CGContext) {
        guard let page = PDFDocument(url: url)?.page(at: index) else { return }
        let size = displaySize(of: page)
        guard size.width > 0, size.height > 0 else { return }
        // At its own shape, from the top (a page that was once made taller doesn't stretch it).
        let height = rect.width * size.height / size.width
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY + height)
        context.scaleBy(x: rect.width / size.width, y: -height / size.height)
        page.draw(with: .cropBox, to: context)
        context.restoreGState()
    }
}

/// Rendered PDF pages, kept while memory allows.
@MainActor
final class PDFPageImages {
    static let shared = PDFPageImages()
    private let cache = NSCache<NSString, UIImage>()

    private init() { cache.totalCostLimit = 160 * 1024 * 1024 }

    /// Widest a page is rendered, in pixels; past this a zoomed page is scaled up a little (memory).
    static let maxPixelWidth: CGFloat = 3200

    func cached(url: URL, page: Int, pixelWidth: CGFloat) -> UIImage? {
        cache.object(forKey: Self.key(url, page, min(pixelWidth, Self.maxPixelWidth)))
    }

    /// Renders off the main thread the first time.
    func image(url: URL, page: Int, pixelWidth: CGFloat) async -> UIImage? {
        let width = min(pixelWidth, Self.maxPixelWidth)
        let key = Self.key(url, page, width)
        if let hit = cache.object(forKey: key) { return hit }
        let image = await Task.detached(priority: .userInitiated) {
            PDFPages.image(url: url, page: page, pixelWidth: width)
        }.value
        if let image { cache.setObject(image, forKey: key, cost: Self.cost(image)) }
        return image
    }

    /// Renders now, on this thread (thumbnails, which are drawn in one go).
    func imageNow(url: URL, page: Int, pixelWidth: CGFloat) -> UIImage? {
        let key = Self.key(url, page, pixelWidth)
        if let hit = cache.object(forKey: key) { return hit }
        let image = PDFPages.image(url: url, page: page, pixelWidth: pixelWidth)
        if let image { cache.setObject(image, forKey: key, cost: Self.cost(image)) }
        return image
    }

    private static func cost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }

    private static func key(_ url: URL, _ page: Int, _ width: CGFloat) -> NSString {
        "\(url.lastPathComponent)#\(page)@\(Int(width.rounded()))" as NSString
    }
}

/// A PDF page as a note page's paper. White until it's rendered.
struct PDFPageView: View {
    let url: URL
    let page: Int
    let width: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        // One image pixel per screen pixel.
        let pixelWidth = (width * displayScale).rounded()
        Color.white
            .overlay(alignment: .top) {
                // At its own shape, from the top: a page that was once made taller never stretches the PDF away from
                // the ink on it.
                if let image { Image(uiImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            }
            .task(id: "\(page)-\(Int(pixelWidth))") {
                if let cached = PDFPageImages.shared.cached(url: url, page: page, pixelWidth: pixelWidth) {
                    image = cached
                    return
                }
                image = await PDFPageImages.shared.image(url: url, page: page, pixelWidth: pixelWidth)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A page on screen, zoomable: pinch (1x to 4x) or double-tap with fingers (not while drawing with a finger); pan with one finger while zoomed. The
/// Pencil always draws.
///
/// A PDF page sits on the desk, shown whole between the top and bottom controls. A blank page fills the screen edge
/// to edge (a page written in the other orientation is taller, and scrolls up and down).
///
/// How a zoom stays smooth and keeps the ink in place:
/// - While fingers are down, and while a zoom animates, the page is only *transformed* (`PageZoomTransform`): paper,
///   PDF, photos, ink and cards are scaled and moved together as one picture, so nothing can slide against anything
///   else. The transform follows the fingers: the point that was under them stays under them as they pinch and move.
/// - Once the zoom comes to rest, the page is laid out again at the new size (so ink and PDF are sharp) and scrolled,
///   in the same update, so the result looks exactly like the transform it replaces.
/// - Layout itself is never animated: a `PKCanvasView` doesn't animate along with SwiftUI, so animating the page's
///   size let the paper glide while the ink jumped straight to its new size. That was the ink moving on zoom.
struct ZoomablePage: View {
    let model: CanvasModel
    let page: NotePage
    let size: CGSize
    let background: PageBackground
    let drawWithFinger: Bool

    private var onDesk: Bool { page.pdfPage != nil }

    /// Zoom the page is laid out at, 1 = the whole page fits.
    @State private var zoom: CGFloat = 1
    /// The pinch (or zoom animation) in progress, on top of `zoom`. Observed only by `PageZoomEffect`, so a pinch
    /// redraws a transform, not the page.
    @State private var transform = PageZoomTransform()
    @State private var tracking = PinchTracking()
    @State private var position = ScrollPosition()
    /// The scroll view's latest geometry (offset, insets, size). Read only by the gestures, so it never re-lays out
    /// the page.
    @State private var scroll: ScrollGeometry?

    static let maxZoom: CGFloat = 4
    /// The same gap between the page and the controls above it as below it.
    static let gap: CGFloat = 16
    static let side: CGFloat = 32

    /// Room above the page: clear of the top controls (and the status bar). The controls are measured, so the page
    /// stays evenly placed whatever they hold.
    private var top: CGFloat { (model.deskTop ?? 80) + Self.gap }
    /// Room below the page: clear of the toolbar, the page dots when there are any, and the home indicator.
    private var bottom: CGFloat { size.height - (model.deskBottom ?? size.height - 76) + Self.gap }

    /// The page's width when it fits.
    private var fitWidth: CGFloat {
        guard onDesk else { return max(1, size.width) }
        let available = CGSize(width: size.width - 2 * Self.side, height: size.height - top - bottom)
        return max(1, min(available.width, available.height * NotePageMetrics.width / page.height))
    }

    var body: some View {
        let width = fitWidth * zoom
        let height = page.height * width / NotePageMetrics.width

        ScrollView([.horizontal, .vertical]) {
            PageZoomEffect(transform: transform,
                           content: PageView(model: model, page: page, width: width, background: background,
                                             drawWithFinger: drawWithFinger, zoom: gestures))
                .shadow(color: .black.opacity(onDesk ? 0.06 : 0), radius: 12, y: 8)
                .shadow(color: .black.opacity(onDesk ? 0.12 : 0), radius: 1.5, y: 1)
                .padding(.horizontal, onDesk ? Self.side : 0)
                .padding(.top, onDesk ? top : 0)
                .padding(.bottom, onDesk ? bottom : 0)
                .frame(minWidth: size.width, minHeight: size.height, alignment: onDesk ? .center : .top)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self) { $0 } action: { _, new in scroll = new }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // Overrides the pager's setting: this page pans only while zoomed (or taller than the screen), and not while
        // an image is being edited.
        .scrollDisabled((zoom <= 1 && height <= size.height + 0.5) || model.selectedImage != nil)
        .onChange(of: zoom) { _, new in model.pageZoomed = new > 1 }
        .onDisappear {
            tracking.generation += 1
            transform.scale = 1
            transform.shift = .zero
            if zoom > 1 { zoom = 1; model.pageZoomed = false }
        }
    }

    // MARK: Gestures

    private var gestures: PageZoomGestures {
        PageZoomGestures(
            began: { anchor, fingers in
                // A new pinch takes over from any zoom still animating; that zoom's layout never happens.
                tracking.generation += 1
                // Mid-pinch (a finger lifted or landed): the point now under the fingers, from the one that was.
                tracking.anchor = anchor ?? CGPoint(
                    x: tracking.anchor.x + (fingers.x - tracking.last.x) / transform.scale,
                    y: tracking.anchor.y + (fingers.y - tracking.last.y) / transform.scale)
                tracking.fingers = fingers
                tracking.last = fingers
                tracking.scale = transform.scale
                tracking.shift = transform.shift
            },
            changed: { scale, fingers in
                let newScale = Self.rubberBand(zoom * tracking.scale * scale) / zoom
                // The anchor (a point on the page) stays under the fingers, wherever they move.
                let a = tracking.anchor
                tracking.last = fingers
                transform.scale = newScale
                transform.shift = CGSize(
                    width: tracking.shift.width + fingers.x - tracking.fingers.x + a.x * (tracking.scale - newScale),
                    height: tracking.shift.height + fingers.y - tracking.fingers.y + a.y * (tracking.scale - newScale))
            },
            ended: { settle(to: zoom * transform.scale, anchor: tracking.anchor) },
            doubleTapped: { anchor in
                tracking.generation += 1
                settle(to: zoom * transform.scale > 1.01 ? 1 : 2.5, anchor: anchor)
            })
    }

    /// Past the limits a pinch still gives a little, less the further it goes, so the page never stops dead.
    private static func rubberBand(_ zoom: CGFloat) -> CGFloat {
        if zoom > maxZoom { return maxZoom * pow(zoom / maxZoom, 0.3) }
        if zoom < 1 { return pow(max(zoom, 0.01), 0.3) }
        return zoom
    }

    // MARK: Settling

    /// Brings the zoom to `target` (within limits), keeping `anchor` (a point on the page, in its laid-out points)
    /// where it is on screen as far as the edges allow. Animates the transform only, then lays the page out.
    private func settle(to target: CGFloat, anchor: CGPoint) {
        let newZoom = min(max(target, 1), Self.maxZoom)
        let ratio = newZoom / zoom
        let offset = scroll?.contentOffset ?? .zero
        let old = pageOrigin(at: zoom)
        let new = pageOrigin(at: newZoom)
        // Where the anchor is now (content), and the offset that puts it at the same place on screen after.
        let here = CGPoint(x: old.x + anchor.x * transform.scale + transform.shift.width,
                           y: old.y + anchor.y * transform.scale + transform.shift.height)
        let wanted = clampedOffset(CGPoint(x: new.x + anchor.x * ratio - (here.x - offset.x),
                                           y: new.y + anchor.y * ratio - (here.y - offset.y)), at: newZoom)
        // The same end state, as a transform on the current layout.
        let shift = CGSize(width: new.x - old.x - (wanted.x - offset.x), height: new.y - old.y - (wanted.y - offset.y))

        tracking.generation += 1
        let generation = tracking.generation
        let still = abs(transform.scale - ratio) < 0.001
            && abs(transform.shift.width - shift.width) < 0.5 && abs(transform.shift.height - shift.height) < 0.5
        if still {
            // A pinch that ended within limits: what's on screen is already the end state.
            transform.scale = ratio
            transform.shift = shift
            commit()
            return
        }
        withAnimation(.snappy(duration: 0.28)) {
            transform.scale = ratio
            transform.shift = shift
        } completion: {
            // Skipped if a new pinch or double-tap took over meanwhile.
            if tracking.generation == generation { commit() }
        }
    }

    /// Replaces the transform with layout: lays the page out at the zoom it shows, and scrolls so it lands exactly
    /// where the transform had it. Both happen in one update, without animation, so nothing on screen moves.
    private func commit() {
        let newZoom = min(max(zoom * transform.scale, 1), Self.maxZoom)
        let offset = scroll?.contentOffset ?? .zero
        let old = pageOrigin(at: zoom)
        let new = pageOrigin(at: newZoom)
        let target = clampedOffset(CGPoint(x: new.x - old.x - transform.shift.width + offset.x,
                                           y: new.y - old.y - transform.shift.height + offset.y), at: newZoom)
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            zoom = newZoom
            transform.scale = 1
            transform.shift = .zero
            if abs(target.x - offset.x) > 0.01 || abs(target.y - offset.y) > 0.01 {
                position.scrollTo(point: target)
            }
        }
    }

    // MARK: Layout, as the scroll view sees it

    /// The page's top-left corner in the scroll view's content, laid out at `zoom` (mirrors the padding and frame in
    /// `body`).
    private func pageOrigin(at zoom: CGFloat) -> CGPoint {
        let width = fitWidth * zoom
        let height = page.height * width / NotePageMetrics.width
        let side = onDesk ? Self.side : 0
        let x = max(0, size.width - (width + 2 * side)) / 2 + side
        guard onDesk else { return CGPoint(x: x, y: 0) }
        return CGPoint(x: x, y: max(0, size.height - (height + top + bottom)) / 2 + top)
    }

    /// The scroll view's content size with the page laid out at `zoom`.
    private func contentSize(at zoom: CGFloat) -> CGSize {
        let width = fitWidth * zoom
        let height = page.height * width / NotePageMetrics.width
        guard onDesk else { return CGSize(width: max(size.width, width), height: max(size.height, height)) }
        return CGSize(width: max(size.width, width + 2 * Self.side), height: max(size.height, height + top + bottom))
    }

    /// `offset` kept within what the scroll view can show at `zoom`.
    private func clampedOffset(_ offset: CGPoint, at zoom: CGFloat) -> CGPoint {
        let content = contentSize(at: zoom)
        let container = scroll?.containerSize ?? size
        let insets = scroll?.contentInsets ?? EdgeInsets()
        let minX = -insets.leading, minY = -insets.top
        let maxX = max(minX, content.width + insets.trailing - container.width)
        let maxY = max(minY, content.height + insets.bottom - container.height)
        return CGPoint(x: min(max(offset.x, minX), maxX), y: min(max(offset.y, minY), maxY))
    }
}

/// A zoom in progress, as a transform on the laid-out page: a point `p` on the page (in its laid-out points) is drawn
/// at `p * scale + shift` from the page's corner.
@Observable @MainActor
final class PageZoomTransform {
    var scale: CGFloat = 1
    var shift: CGSize = .zero
}

/// Where the current pinch started, in the terms it's followed in. Not observed: it never redraws anything.
@MainActor
private final class PinchTracking {
    /// The point on the page under the fingers, in the page's laid-out points.
    var anchor: CGPoint = .zero
    /// The fingers when the pinch started, and at its last change, in window points.
    var fingers: CGPoint = .zero
    var last: CGPoint = .zero
    /// The transform when the pinch started.
    var scale: CGFloat = 1
    var shift: CGSize = .zero
    /// Bumped by every pinch and zoom, so an animation that finishes after a newer one started doesn't lay out.
    var generation = 0
}

/// Applies the zoom transform to the page. Only this view reads the transform, so during a pinch SwiftUI redraws a
/// scale and an offset; the page inside (PencilKit, the PDF, photos) is left alone.
private struct PageZoomEffect<Content: View>: View {
    let transform: PageZoomTransform
    let content: Content

    var body: some View {
        content
            .scaleEffect(transform.scale, anchor: .topLeading)
            .offset(transform.shift)
    }
}
