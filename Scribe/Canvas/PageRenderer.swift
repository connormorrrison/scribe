import PencilKit
import SwiftUI

// MARK: - Drawing a page as a picture

/// Everything on a page, drawn at full page size (1 pt per page point): paper and background, photos, the agent's
/// ink, the person's ink, then the agent's cards, in the same order as `PageView`. Drawn full size so cards, whose
/// header and text have fixed sizes, look as they do on the page; `PageRenderer` scales the result down.
struct PageSnapshot: View {
    let page: NotePage
    let background: PageBackground
    let image: (String) -> UIImage?
    /// A PDF page's paper, for a page of an imported PDF.
    var pdfImage: (Int) -> UIImage? = { _ in nil }
    /// Pixels per page point, for the ink images.
    let inkScale: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            if let index = page.pdfPage {
                if let paper = pdfImage(index) {
                    // At its own shape, from the top: a page that was once made taller never stretches the PDF.
                    Image(uiImage: paper).resizable().aspectRatio(contentMode: .fit).frame(width: page.bounds.width)
                }
            } else {
                PageBackgroundView(style: background, regions: [page.bounds],
                                   spacing: NotePageMetrics.backgroundSpacing)
            }

            ForEach(page.images) { placed in
                if let picture = image(placed.fileName) {
                    PlacedImageView(image: picture, placed: placed, scale: 1)
                }
            }

            Image(uiImage: lightImage(page.agentDrawing, bounds: page.bounds, scale: inkScale)).resizable()
            AgentMarksLayer(marks: page.agentMarks)
            Image(uiImage: lightImage(page.drawing, bounds: page.bounds, scale: inkScale)).resizable()

            ForEach(page.cards) { card in
                CardFace(card: card, clock: nil, artScale: card.frame.width / card.designWidth)
                    .frame(width: card.frame.width, height: card.frame.height)
                    .offset(x: card.frame.minX, y: card.frame.minY)
            }
        }
        .frame(width: page.bounds.width, height: page.bounds.height, alignment: .topLeading)
        .clipped()
        .environment(\.colorScheme, .light)
    }
}

@MainActor
enum PageRenderer {
    /// The page as an image `pixelWidth` pixels wide.
    static func image(of page: NotePage, background: PageBackground, pixelWidth: CGFloat, pdf: URL? = nil,
                      image: @escaping (String) -> UIImage?) -> UIImage? {
        let scale = pixelWidth / NotePageMetrics.width
        let paper: UIImage? = page.pdfPage.flatMap { index in
            pdf.flatMap { PDFPageImages.shared.imageNow(url: $0, page: index, pixelWidth: pixelWidth) }
        }
        let renderer = ImageRenderer(content: PageSnapshot(page: page, background: background, image: image,
                                                           pdfImage: { _ in paper }, inkScale: scale))
        renderer.scale = scale
        renderer.isOpaque = true
        return renderer.uiImage
    }
}

// MARK: - Library thumbnails

/// The first page of each note, as the library shows it. Drawn from what's saved, and drawn again whenever the note
/// saves (`CanvasModel` calls `invalidate`) or the default page background changes.
@MainActor @Observable
final class NoteThumbnails {
    static let shared = NoteThumbnails()

    /// Bumped each time a note saves, so its tiles draw again.
    private(set) var versions: [UUID: Int] = [:]
    @ObservationIgnored private var cache: [UUID: (key: String, thumbnail: Thumbnail)] = [:]

    struct Thumbnail {
        var image: UIImage
        /// Something sits below what a landscape tile shows of the page's top, so the whole page is shown instead.
        var showsWholePage: Bool
        /// Each visualization card that's out (not tucked away), oldest first.
        var cards: [ThumbnailVisualizations.Card] = []
    }

    private static let pixelWidth: CGFloat = 640

    func invalidate(_ documentID: UUID) {
        cache[documentID] = nil
        versions[documentID, default: 0] += 1
    }

    func thumbnail(for documentID: UUID, directory: URL?, pdf: URL? = nil,
                   defaultBackground: PageBackground) -> Thumbnail? {
        let file = NoteFile(directory: directory)
        let saved = file.contentURL.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        let key = "\(saved?.timeIntervalSince1970 ?? 0)-\(defaultBackground.rawValue)"
        if let hit = cache[documentID], hit.key == key { return hit.thumbnail }

        let content = file.load(pdf: pdf)
        guard let page = content.pages.first else { return nil }
        var images: [String: UIImage] = [:]
        for placed in page.images {
            if let url = file.imageURL(placed.fileName), let picture = UIImage(contentsOfFile: url.path) {
                images[placed.fileName] = picture
            }
        }
        let rendered = PageRenderer.image(of: page, background: content.background ?? defaultBackground,
                                          pixelWidth: Self.pixelWidth, pdf: pdf) { images[$0] }
        guard let rendered else { return nil }
        let cards = content.hidesVisualizations ? [] : content.visualizations.map {
            ThumbnailVisualizations.Card(aspect: (VisualizationCardShape.header + $0.height) / Visualization.pageWidth,
                                         image: file.visualizationImage($0.id))
        }
        let thumbnail = Thumbnail(image: rendered, showsWholePage: Self.contentBottom(page) > Self.topCropHeight,
                                  cards: cards)
        cache[documentID] = (key, thumbnail)
        return thumbnail
    }

    /// How much of the page's top a landscape tile shows, in page points.
    private static let topCropHeight = NotePageMetrics.width * LibraryMetrics.thumbnailHeight / LibraryMetrics.tileWidth

    /// The lowest point of anything on the page.
    private static func contentBottom(_ page: NotePage) -> CGFloat {
        var bottom: CGFloat = 0
        for bounds in [page.drawing.bounds, page.agentDrawing.bounds] where !bounds.isNull && !bounds.isEmpty {
            bottom = max(bottom, bounds.maxY)
        }
        for frame in page.images.map(\.bounds) + page.cards.map(\.frame) + page.agentMarks.map(\.bounds)
            where !frame.isNull { bottom = max(bottom, frame.maxY) }
        return bottom
    }
}

/// A note's first page in a library tile: the top of the page filling the frame, or the whole page on gray bars (a
/// PDF, or a note with something lower than the top would show).
struct NoteThumbnail: View {
    let document: CanvasDocument
    @Environment(CanvasStore.self) private var store: CanvasStore?
    @AppStorage(AppSettings.pageBackground) private var background = PageBackground.dots
    @State private var thumbnail: NoteThumbnails.Thumbnail?

    var body: some View {
        let version = NoteThumbnails.shared.versions[document.id] ?? 0
        // A PDF always shows its whole first page, like the page on the desk when it opens; so does a note with
        // something low on the page. The bars at the sides are the desk.
        let wholePage = document.kind == .pdf || thumbnail?.showsWholePage == true
        (wholePage ? Color(.systemGray5) : Color.white)
            .overlay(alignment: .top) {
                if let thumbnail {
                    Image(uiImage: thumbnail.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: wholePage ? .fit : .fill)
                        .frame(maxHeight: wholePage ? .infinity : nil)
                        .shadow(color: .black.opacity(wholePage ? 0.12 : 0), radius: 1, y: 0.5)
                } else if document.kind != .pdf {
                    NotePaper()
                }
            }
            .overlay {
                if let cards = thumbnail?.cards, !cards.isEmpty { ThumbnailVisualizations(cards: cards) }
            }
            .clipped()
            .task(id: "\(document.id)-\(version)-\(background.rawValue)") {
                thumbnail = NoteThumbnails.shared.thumbnail(for: document.id,
                                                            directory: store?.noteDirectory(for: document.id),
                                                            pdf: document.kind == .pdf
                                                                ? store?.fileURL(for: document) : nil,
                                                            defaultBackground: background)
            }
    }
}

/// The proportions of a visualization card on the page, for drawing it small.
enum VisualizationCardShape {
    /// The title bar above the page, and the room under it (`VisualizationCard`).
    static let header: CGFloat = 48 + 6
}

/// The visualizations that are out, drawn small in the tile's top right as they hover over the note: dark cards with a
/// title bar and a picture of the page as it started (a curve for one not pictured yet), at the size they have on a
/// landscape screen. Cards tucked away aren't drawn.
struct ThumbnailVisualizations: View {
    struct Card {
        /// Height over width, title bar included.
        var aspect: CGFloat
        /// The page soon after it started (`WebCardView.onSnapshot`), once it's been on screen.
        var image: UIImage?
    }

    /// Oldest first.
    let cards: [Card]

    /// The landscape screen the tile stands for, in points.
    private static let screenWidth: CGFloat = LibraryMetrics.screenSize.width
    private static let top: CGFloat = 76
    private static let margin: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let scale = geo.size.width / Self.screenWidth
            let width = VisualizationStack.cardWidth(for: Self.screenWidth) * scale
            VStack(spacing: 16 * scale) {
                ForEach(cards.indices, id: \.self) { index in
                    card(cards[index], width: width, height: width * cards[index].aspect, scale: scale)
                }
            }
            .padding(.top, Self.top * scale)
            .padding(.trailing, Self.margin * scale)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topTrailing)
        }
        .accessibilityHidden(true)
    }

    private func card(_ card: Card, width: CGFloat, height: CGFloat, scale: CGFloat) -> some View {
        let header = 48 * scale
        let shape = RoundedRectangle(cornerRadius: 18 * scale, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            // The title, as a line.
            Capsule()
                .fill(.white.opacity(0.85))
                .frame(width: width * 0.4, height: max(1.5, 10 * scale))
                .padding(.leading, 16 * scale)
                .frame(height: header)
            if let image = card.image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: max(0, height - header - 6 * scale), alignment: .top)
                    .clipped()
            } else {
                Wave()
                    .stroke(Landing.cyan,
                            style: StrokeStyle(lineWidth: max(1, 3 * scale), lineCap: .round))
                    .padding(.horizontal, width * 0.12)
                    .padding(.vertical, (height - header) * 0.22)
            }
        }
        .frame(width: width, height: height, alignment: .top)
        .clipShape(shape)
        .background(shape.fill(Landing.card).shadow(color: .black.opacity(0.22), radius: 12 * scale, y: 6 * scale))
    }

    /// One period of a sine wave across the rect.
    private struct Wave: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                let steps = 48
                for step in 0...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let point = CGPoint(x: rect.minX + t * rect.width,
                                        y: rect.midY - sin(t * 2 * .pi) * rect.height / 2)
                    if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
        }
    }
}
