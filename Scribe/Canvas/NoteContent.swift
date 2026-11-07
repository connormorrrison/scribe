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
    var images: [PlacedImage] = []
    var cards: [AgentCard] = []

    var bounds: CGRect { CGRect(x: 0, y: 0, width: NotePageMetrics.width, height: height) }

    /// A copy with new IDs (images keep pointing at the same files).
    func duplicated() -> NotePage {
        var copy = self
        copy.id = UUID()
        copy.images = images.map { var image = $0; image.id = UUID(); return image }
        copy.cards = cards.map { var card = $0; card.id = UUID(); return card }
        return copy
    }
}

/// One line in the note's History.
struct HistoryEntry: Identifiable, Codable, Equatable {
    enum Author: String, Codable { case you, agent }

    var id = UUID()
    var date = Date()
    var author: Author
    var text: String
}

/// Everything saved for a note.
struct NoteContent: Codable, Equatable {
    var pages: [NotePage] = [NotePage()]
    /// nil follows the Pages setting.
    var background: PageBackground?
    var history: [HistoryEntry] = []
}

extension PageBackground: Codable {}

/// Reads and writes a note's directory: `note.json` plus its images.
struct NoteFile {
    let directory: URL?

    var contentURL: URL? { directory?.appendingPathComponent("note.json") }

    func load() -> NoteContent {
        guard let url = contentURL, let data = try? Data(contentsOf: url),
              let content = try? JSONDecoder().decode(NoteContent.self, from: data),
              !content.pages.isEmpty else { return NoteContent() }
        return content
    }

    func save(_ content: NoteContent) {
        guard let directory, let url = contentURL, let data = try? JSONEncoder().encode(content) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func imageURL(_ fileName: String) -> URL? { directory?.appendingPathComponent(fileName) }

    /// Saves image data and returns its file name.
    func saveImage(_ data: Data) -> String {
        let name = "\(UUID().uuidString).jpg"
        if let directory, let url = imageURL(name) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return name
    }
}
