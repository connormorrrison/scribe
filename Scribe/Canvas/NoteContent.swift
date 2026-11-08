import OSLog
import PencilKit
import SwiftUI

/// Page sizes, in page points. Every page is 1100 wide; its height is set to fill the screen (`CanvasModel.fitPages`),
/// starting from landscape Letter.
enum NotePageMetrics {
    static let width: CGFloat = 1100
    static let height: CGFloat = 850
    /// Distance between the background's dots or grid lines.
    static let backgroundSpacing: CGFloat = 32
}

/// A photo placed on a page, under the ink.
struct PlacedImage: Identifiable, Codable, Equatable {
    var id = UUID()
    /// The file inside the note's directory.
    var fileName: String
    /// In page points, before rotation.
    var frame: CGRect
    /// Radians, clockwise, about the frame's centre.
    var rotation: Double = 0

    init(fileName: String, frame: CGRect, rotation: Double = 0) {
        self.fileName = fileName
        self.frame = frame
        self.rotation = rotation
    }

    /// Notes saved before images could rotate have no rotation.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        fileName = try c.decode(String.self, forKey: .fileName)
        frame = try c.decode(CGRect.self, forKey: .frame)
        rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
    }

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }

    /// Whether a page point falls on the image, rotation included.
    func contains(_ point: CGPoint) -> Bool {
        let d = CGPoint(x: point.x - frame.midX, y: point.y - frame.midY)
        let c = cos(-rotation), s = sin(-rotation)
        let local = CGPoint(x: d.x * c - d.y * s, y: d.x * s + d.y * c)
        return abs(local.x) <= frame.width / 2 && abs(local.y) <= frame.height / 2
    }

    /// The rotated image's bounding box.
    var bounds: CGRect {
        frame.applying(CGAffineTransform(translationX: -frame.midX, y: -frame.midY)
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(CGAffineTransform(translationX: frame.midX, y: frame.midY)))
    }
}

/// A visualization the agent made on the page.
struct AgentCard: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case atom, tangent }

    var id = UUID()
    var kind: Kind
    var title: String
    /// In page points.
    var frame: CGRect
    /// Animated cards get Play/Pause and Stop.
    var isAnimated = true

    /// The width the card's art was designed at, for scaling it.
    var designWidth: CGFloat {
        switch kind {
        case .atom: 240
        case .tangent: 300
        }
    }

    static let headerHeight: CGFloat = 36
    static let minimumSize = CGSize(width: 200, height: 160)
}

struct NotePage: Identifiable, Codable, Equatable {
    var id = UUID()
    var height: CGFloat = NotePageMetrics.height
    /// The person's ink.
    var drawing = PKDrawing()
    /// The agent's ink, kept apart so it can be cleared on its own.
    var agentDrawing = PKDrawing()
    /// What the agent drew and wrote on the page, oldest first.
    var agentMarks: [AgentMark] = []
    var images: [PlacedImage] = []
    var cards: [AgentCard] = []
    /// For a page of an imported PDF: which PDF page is its paper (`PDFPages`). nil for a blank page.
    var pdfPage: Int?

    init(height: CGFloat = NotePageMetrics.height, pdfPage: Int? = nil) {
        self.height = height
        self.pdfPage = pdfPage
    }

    /// Pages saved before the agent could draw have no marks.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        height = try c.decode(CGFloat.self, forKey: .height)
        drawing = try c.decode(PKDrawing.self, forKey: .drawing)
        agentDrawing = try c.decode(PKDrawing.self, forKey: .agentDrawing)
        agentMarks = try c.decodeIfPresent([AgentMark].self, forKey: .agentMarks) ?? []
        images = try c.decode([PlacedImage].self, forKey: .images)
        cards = try c.decode([AgentCard].self, forKey: .cards)
        pdfPage = try c.decodeIfPresent(Int.self, forKey: .pdfPage)
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: NotePageMetrics.width, height: height) }

    /// Anything the agent drew or made on the page.
    var hasAgentMarks: Bool { !agentDrawing.strokes.isEmpty || !agentMarks.isEmpty || !cards.isEmpty }

    /// A copy with new IDs (images keep pointing at the same files).
    func duplicated() -> NotePage {
        var copy = self
        copy.id = UUID()
        copy.images = images.map { var image = $0; image.id = UUID(); return image }
        copy.cards = cards.map { var card = $0; card.id = UUID(); return card }
        copy.agentMarks = agentMarks.map { var mark = $0; mark.id = UUID(); return mark }
        return copy
    }
}

/// One line in the note's History. The agent's are steps it took (wrote on a page, made a visualization), shown in
/// History between what was said, in the order they happened.
struct HistoryEntry: Identifiable, Codable, Equatable {
    enum Author: String, Codable { case you, agent }

    var id = UUID()
    var date = Date()
    var author: Author
    var text: String
    /// An SF Symbol for the step.
    var symbol: String?
    /// The page it happened on: tapping the step in History turns to it.
    var pageID: UUID?
    /// The visualization it made: tapping the step brings the cards out.
    var visualizationID: UUID?
    /// The marks it drew, for the small picture of them in History. Missing from steps saved before History showed
    /// them (and from erasing).
    var markIDs: [UUID]?
}

/// One message in the conversation with the agent: something the person said (or typed), or the agent's reply.
struct ConversationTurn: Identifiable, Codable, Equatable {
    enum Speaker: String, Codable { case you, agent }

    var id = UUID()
    var date = Date()
    var speaker: Speaker
    var text: String
    /// Said out loud (the person's speech, or a reply the agent spoke), rather than typed.
    var spoken: Bool
}

/// Everything saved for a note.
struct NoteContent: Codable, Equatable {
    var pages: [NotePage] = [NotePage()]
    /// nil follows the Pages setting.
    var background: PageBackground?
    var history: [HistoryEntry] = []
    var conversation: [ConversationTurn] = []
    /// The agent's visualizations, hovering over the pages in the top right, oldest first.
    var visualizations: [Visualization] = []
    /// The person tucked the visualizations away; they stay tucked away the next time the note opens.
    var hidesVisualizations = false
}

extension NoteContent {
    /// Fields added after the first release are optional, so older notes still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pages = try c.decode([NotePage].self, forKey: .pages)
        background = try c.decodeIfPresent(PageBackground.self, forKey: .background)
        history = try c.decodeIfPresent([HistoryEntry].self, forKey: .history) ?? []
        conversation = try c.decodeIfPresent([ConversationTurn].self, forKey: .conversation) ?? []
        visualizations = try c.decodeIfPresent([Visualization].self, forKey: .visualizations) ?? []
        hidesVisualizations = try c.decodeIfPresent(Bool.self, forKey: .hidesVisualizations) ?? false
    }
}

extension PageBackground: Codable {}

/// Reads and writes a note's directory: `note.json` plus its images.
struct NoteFile {
    let directory: URL?

    var contentURL: URL? { directory?.appendingPathComponent("note.json") }

    /// What was read, and whether it came from a saved file.
    struct Loaded {
        var content: NoteContent
        /// False for a new note (or a PDF never opened), or when the saved file couldn't be read.
        var fromDisk: Bool
    }

    /// What's saved; for an imported PDF that's never been opened, one page per PDF page.
    func load(pdf: URL? = nil) -> NoteContent { read(pdf: pdf).content }

    /// Like `load`, and says where the content came from. A saved file that can't be read is set aside (kept for
    /// recovery, see `StoredFile.setAside`) rather than left to be overwritten by the next save.
    func read(pdf: URL? = nil) -> Loaded {
        if let url = contentURL, FileManager.default.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url),
               let content = try? JSONDecoder().decode(NoteContent.self, from: data), !content.pages.isEmpty {
                return Loaded(content: content, fromDisk: true)
            }
            StoredFile.setAside(url)
        }
        if let pdf {
            let pages = PDFPages.notePages(from: pdf)
            if !pages.isEmpty { return Loaded(content: NoteContent(pages: pages), fromDisk: false) }
        }
        return Loaded(content: NoteContent(), fromDisk: false)
    }

    /// Writes `note.json` atomically. False (and logged) if it couldn't be written.
    @discardableResult
    func save(_ content: NoteContent) -> Bool {
        guard let directory, let url = contentURL else { return true } // In memory (previews): nothing to write.
        do {
            let data = try JSONEncoder().encode(content)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            StoredFile.log.error("Couldn't save \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func imageURL(_ fileName: String) -> URL? { directory?.appendingPathComponent(fileName) }

    /// Saves image data and returns its file name.
    func saveImage(_ data: Data) -> String {
        let name = "\(UUID().uuidString).jpg"
        if let directory, let url = imageURL(name) {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                StoredFile.log.error("Couldn't save image \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return name
    }

    /// Deletes image files no page uses any more (left by deleted images). Only safe when nothing can bring them
    /// back, so it runs when a note opens, before there's anything to undo.
    func removeImages(notIn used: Set<String>) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".jpg") && !used.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Visualization pictures

    private static let visualizationPrefix = "visualization-"

    /// A picture of a visualization's page soon after it starts, for the library's thumbnails.
    func visualizationImageURL(_ id: UUID) -> URL? {
        directory?.appendingPathComponent("\(Self.visualizationPrefix)\(id.uuidString).png")
    }

    func visualizationImage(_ id: UUID) -> UIImage? {
        visualizationImageURL(id).flatMap { UIImage(contentsOfFile: $0.path) }
    }

    func saveVisualizationImage(_ data: Data, for id: UUID) {
        guard let directory, let url = visualizationImageURL(id) else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            StoredFile.log.error("Couldn't save visualization picture: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes pictures of visualizations the note no longer has. Runs when a note opens, like `removeImages`.
    func removeVisualizationImages(notIn used: Set<UUID>) {
        guard let directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let keep = Set(used.compactMap { visualizationImageURL($0)?.lastPathComponent })
        for name in names where name.hasPrefix(Self.visualizationPrefix) && name.hasSuffix(".png") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// Shared handling for the files Scribe saves.
enum StoredFile {
    static let log = Logger(subsystem: "com.connormorrison.scribe", category: "storage")

    /// Moves a saved file that can't be read to `<name>.unreadable-<date>.json` next to it. Nothing reads or deletes
    /// it, so it can be recovered; and the next save writes a new file instead of overwriting it.
    static func setAside(_ url: URL) {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            log.error("Set aside unreadable \(url.lastPathComponent, privacy: .public) as \(backup.lastPathComponent, privacy: .public)")
        } catch {
            log.error("Couldn't set aside \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
