import Observation
import OSLog
import SwiftUI

/// Debug state for the page map: the overlay switch (Settings › Developer), build timings, and the log of how each
/// tool call's targets were resolved and placed.
@MainActor @Observable
final class PageMapDebug {
    static let shared = PageMapDebug()
    nonisolated static let log = Logger(subsystem: "com.connormorrison.scribe", category: "page-map")
    static let overlayKey = "debug.pageMapOverlay"

    struct Build: Identifiable, Hashable {
        let id = UUID()
        var page: UUID
        var milliseconds: Double
        var objects: Int
        var tokens: Int
        var freeSpaces: Int
        var date = Date()
    }

    /// Boxes over everything in the page map, free spaces and traceable lines. With it on, every snapshot is also
    /// saved as a fixture in Documents/Fixtures (shared through the Files app).
    var showOverlay = UserDefaults.standard.bool(forKey: PageMapDebug.overlayKey) {
        didSet {
            UserDefaults.standard.set(showOverlay, forKey: Self.overlayKey)
            if !showOverlay { selected = nil }
        }
    }
    /// The object whose details the overlay shows (tap a box).
    var selected: (page: UUID, object: PageObject)?
    private(set) var builds: [Build] = []
    private(set) var placements: [String] = []

    func record(_ build: Build) {
        builds.append(build)
        if builds.count > 40 { builds.removeFirst(builds.count - 40) }
    }

    /// What a tool call did with its targets and where its marks went.
    func logPlacement(_ tool: String, _ notes: [String], result: String) {
        let line = "\(tool): " + (notes + [result]).joined(separator: " · ")
        placements.append(line)
        if placements.count > 100 { placements.removeFirst(placements.count - 100) }
        Self.log.info("\(line, privacy: .public)")
    }
}

// MARK: - Overlay

/// Thin boxes over everything in the page map, coloured by source and tagged with their IDs; free spaces in dashed
/// green; traceable lines in pink. Debug only.
struct PageMapOverlay: View {
    let snapshot: PageMapSnapshot
    /// Screen points per page point.
    let scale: CGFloat
    @State private var debug = PageMapDebug.shared

    var body: some View {
        Canvas { ctx, _ in
            ctx.scaleBy(x: scale, y: scale)
            let tagFont = Font.system(size: 9 / max(scale, 0.3), weight: .semibold, design: .monospaced)
            for o in snapshot.objects where o.kind != "word" {
                let color = Self.color(o)
                var path = Path(o.bounds)
                if let outline = o.outline, outline.count > 2 {
                    path = Path { p in p.addLines(outline); p.closeSubpath() }
                }
                let selected = debug.selected?.object.id == o.id && debug.selected?.page == snapshot.pageID
                ctx.stroke(path, with: .color(color.opacity(selected ? 1 : 0.7)), lineWidth: (selected ? 2.5 : 1) / scale)
                let tag = ctx.resolve(Text(o.id).font(tagFont).foregroundStyle(.white))
                let s = tag.measure(in: CGSize(width: 400, height: 40))
                let r = CGRect(x: o.bounds.minX, y: o.bounds.minY - s.height - 1, width: s.width + 4, height: s.height + 1)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color.opacity(0.85)))
                ctx.draw(tag, at: CGPoint(x: r.minX + 2, y: r.minY + 0.5), anchor: .topLeading)
            }
            for f in snapshot.freeSpaces {
                ctx.stroke(Path(f.bounds), with: .color(.green.opacity(0.85)), style: StrokeStyle(lineWidth: 1.5 / scale, dash: [6, 4]))
                let tag = ctx.resolve(Text(f.id).font(tagFont).foregroundStyle(.green))
                ctx.draw(tag, at: CGPoint(x: f.bounds.minX + 4, y: f.bounds.minY + 3), anchor: .topLeading)
            }
            for o in snapshot.objects {
                for p in o.paths ?? [] where p.count > 1 {
                    ctx.stroke(Path { $0.addLines(p) }, with: .color(.pink.opacity(0.75)), lineWidth: 1 / scale)
                }
            }
        }
        .overlay(alignment: .topLeading) {
            if let selected = debug.selected, selected.page == snapshot.pageID {
                Text(Self.json(selected.object))
                    .font(.system(size: 9, design: .monospaced))
                    .padding(6)
                    .background(.white.opacity(0.95), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Self.color(selected.object), lineWidth: 1))
                    .frame(maxWidth: 300, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(x: min(selected.object.bounds.minX * scale, snapshot.pageSize.width * scale - 310),
                            y: min(selected.object.bounds.maxY * scale + 6, snapshot.pageSize.height * scale - 200))
            }
        }
        .allowsHitTesting(false)
    }

    static func color(_ o: PageObject) -> Color {
        switch o.source {
        case .pdfText: .blue
        case .printed: .teal
        case .studentInk: .black
        case .agentInk: .purple
        case .card: .orange
        }
    }

    static func json(_ o: PageObject) -> String {
        var copy = o
        copy.bounds = CGRect(x: o.bounds.minX.rounded(), y: o.bounds.minY.rounded(), width: o.bounds.width.rounded(),
                             height: o.bounds.height.rounded())
        if let n = copy.outline?.count { copy.outline = nil; copy.text = (copy.text ?? "") + " · outline \(n) pts" }
        if let n = copy.strokeIDs?.count { copy.strokeIDs = nil; copy.text = (copy.text ?? "") + " · \(n) strokes" }
        if let n = copy.paths?.count { copy.paths = nil; copy.text = (copy.text ?? "") + " · \(n) traceable lines" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(copy)).flatMap { String(data: $0, encoding: .utf8) } ?? o.id
    }
}

// MARK: - Fixtures

/// `Fixtures/<name>/snapshot.json`, `image.jpg` and `pagemap.txt`: a saved snapshot, for checking the map against the
/// page and for tests.
enum PageFixture {
    /// The app's own fixtures folder (Documents/Fixtures), shared through the Files app.
    static var appDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Writes the fixture and returns its folder. `name` may contain "/".
    @discardableResult
    static func save(_ snapshot: PageMapSnapshot, name: String, in root: URL = appDirectory) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var json = snapshot
        json.image = Data()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(json).write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
        try snapshot.image.write(to: directory.appendingPathComponent("image.jpg"), options: .atomic)
        try Data(PageMapText.block(snapshot).utf8).write(to: directory.appendingPathComponent("pagemap.txt"), options: .atomic)
        return directory
    }

    static func load(_ name: String, in root: URL) throws -> PageMapSnapshot {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        var snapshot = try JSONDecoder().decode(PageMapSnapshot.self,
                                                from: Data(contentsOf: directory.appendingPathComponent("snapshot.json")))
        snapshot.image = (try? Data(contentsOf: directory.appendingPathComponent("image.jpg"))) ?? Data()
        return snapshot
    }
}
