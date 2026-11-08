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
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: rect.width / size.width, y: -rect.height / size.height)
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
            .overlay {
                if let image { Image(uiImage: image).resizable().interpolation(.high) }
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

/// A page on screen, zoomable: pinch (1x to 4x) or double-tap with fingers; pan with one finger while zoomed. The
/// Pencil always draws.
///
/// A PDF page sits on the desk, shown whole between the top and bottom controls. A blank page fills the screen edge
/// to edge (a page written in the other orientation is taller, and scrolls up and down).
struct ZoomablePage: View {
    let model: CanvasModel
    let page: NotePage
    let size: CGSize
    let background: PageBackground
    let drawWithFinger: Bool

    private var onDesk: Bool { page.pdfPage != nil }

    /// Zoom after the last pinch, 1 = the whole page fits.
    @State private var zoom: CGFloat = 1
    /// The pinch in progress, shown as a scale effect until it ends (so the page lays out once per pinch).
    @State private var pinch: CGFloat = 1
    /// Where the pinch started, in the page's unscaled coordinates.
    @State private var anchor: CGPoint = .zero
    @State private var position = ScrollPosition()
    @State private var offset: CGPoint = .zero

    static let maxZoom: CGFloat = 4
    /// Room around the page: clear of the top controls (with the status bar), the bottom controls (with the home
    /// indicator), and the screen's sides.
    static let top: CGFloat = 96
    static let bottom: CGFloat = 92
    static let side: CGFloat = 32

    /// The page's width when it fits.
    private var fitWidth: CGFloat {
        guard onDesk else { return max(1, size.width) }
        let available = CGSize(width: size.width - 2 * Self.side, height: size.height - Self.top - Self.bottom)
        return max(1, min(available.width, available.height * NotePageMetrics.width / page.height))
    }

    var body: some View {
        let width = fitWidth * zoom
        let height = page.height * width / NotePageMetrics.width

        ScrollView([.horizontal, .vertical]) {
            PageView(model: model, page: page, width: width, background: background, drawWithFinger: drawWithFinger,
                     zoom: gestures)
                .scaleEffect(pinch, anchor: UnitPoint(x: anchor.x / max(width, 1), y: anchor.y / max(height, 1)))
                .shadow(color: .black.opacity(onDesk ? 0.06 : 0), radius: 12, y: 8)
                .shadow(color: .black.opacity(onDesk ? 0.12 : 0), radius: 1.5, y: 1)
                .padding(.horizontal, onDesk ? Self.side : 0)
                .padding(.top, onDesk ? Self.top : 0)
                .padding(.bottom, onDesk ? Self.bottom : 0)
                .frame(minWidth: size.width, minHeight: size.height, alignment: onDesk ? .center : .top)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGPoint.self) { $0.contentOffset } action: { _, new in offset = new }
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        // Overrides the pager's setting: this page pans only while zoomed (or taller than the screen), and not while
        // an image is being edited.
        .scrollDisabled((zoom <= 1 && height <= size.height + 0.5) || model.selectedImage != nil)
        .onChange(of: zoom) { _, new in model.pageZoomed = new > 1 }
        .onDisappear {
            if zoom > 1 { zoom = 1; model.pageZoomed = false }
        }
    }

    private var gestures: PageZoomGestures {
        PageZoomGestures(
            began: { point in anchor = point },
            changed: { scale in
                // Not below fit, nor past the maximum, with a little give at both ends.
                pinch = min(max(scale, 0.8 / zoom), Self.maxZoom * 1.15 / zoom)
            },
            ended: { scale in settle(to: zoom * scale) },
            doubleTapped: { point in
                anchor = point
                settle(to: zoom > 1.01 ? 1 : 2.5)
            })
    }

    /// Lays the page out at the new zoom and scrolls so the point under the fingers stays there.
    private func settle(to target: CGFloat) {
        let newZoom = min(max(target, 1), Self.maxZoom)
        let ratio = newZoom / zoom
        let point = CGPoint(x: max(0, offset.x + anchor.x * (ratio - 1)), y: max(0, offset.y + anchor.y * (ratio - 1)))
        withAnimation(.snappy(duration: 0.25)) {
            zoom = newZoom
            pinch = 1
        }
        Task { @MainActor in
            if newZoom <= 1 { position.scrollTo(point: .zero) } else { position.scrollTo(point: point) }
        }
    }
}
