import PencilKit
import SwiftUI

enum CanvasTool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso

    var id: Self { self }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }
}

enum EraserMode: String {
    case stroke, pixel
}

/// What the agent is doing, shown by the agent control.
enum AgentState: Equatable {
    case idle, listening, thinking
}

/// A banner just under the top row.
enum CanvasBanner: Equatable {
    /// Something went wrong; offers Settings and Try again.
    case error(String)
    /// The agent asks the person to pick one of a few chips.
    case choice(prompt: String, options: [String])
}

/// A photo being positioned before it's placed on the page.
struct ImagePlacement {
    var pageID: UUID
    var image: UIImage
    var data: Data
    /// In page points.
    var frame: CGRect
}

/// Play state for an animated card.
struct AnimationClock: Equatable {
    var elapsed: TimeInterval = 0
    var startedAt: Date? = .now

    var isPlaying: Bool { startedAt != nil }

    func time(at date: Date) -> TimeInterval {
        elapsed + (startedAt.map { date.timeIntervalSince($0) } ?? 0)
    }
}

/// The open note: its pages, the tools, the agent's state and the undo stack.
@MainActor @Observable
final class CanvasModel {
    private(set) var content: NoteContent
    let document: CanvasDocument
    @ObservationIgnored private let file: NoteFile
    @ObservationIgnored private let store: CanvasStore

    // MARK: Pages

    /// The page at the top of the screen (bound to the scroll position).
    var currentPageID: UUID?
    /// Bumped whenever page ink changes from outside a canvas (undo, duplicating, clearing), so canvases reload it.
    private(set) var reloadToken = 0

    var currentPageIndex: Int {
        content.pages.firstIndex { $0.id == currentPageID } ?? 0
    }

    func page(_ id: UUID) -> NotePage? { content.pages.first { $0.id == id } }

    // MARK: Tools

    var tool = CanvasTool.pen
    var eraserMode = EraserMode.stroke
    private(set) var swatches: [String]
    var selectedSwatch = 0

    var inkColor: UIColor {
        UIColor(hex: swatches.indices.contains(selectedSwatch) ? swatches[selectedSwatch] : "#1C1C1E")
    }

    var pencilKitTool: PKTool {
        switch tool {
        case .pen: PKInkingTool(.pen, color: inkColor, width: 3)
        case .highlighter: PKInkingTool(.marker, color: inkColor, width: 22)
        case .eraser: PKEraserTool(eraserMode == .stroke ? .vector : .bitmap)
        case .lasso: PKLassoTool()
        }
    }

    // MARK: Agent and banners

    var agent = AgentState.idle
    var banner: CanvasBanner?
    var placement: ImagePlacement?
    var showsKeyboard = false
    var enlargedCard: AgentCard?
    private(set) var clocks: [UUID: AnimationClock] = [:]

    // MARK: Undo

    @ObservationIgnored let undoManager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        return manager
    }()
    private(set) var canUndo = false
    private(set) var canRedo = false

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var images: [String: UIImage] = [:]

    init(store: CanvasStore, document: CanvasDocument) {
        self.store = store
        self.document = document
        let file = NoteFile(directory: store.noteDirectory(for: document.id))
        let content = file.load()
        self.file = file
        self.content = content
        currentPageID = content.pages.first?.id
        swatches = Self.loadSwatches()
        for page in content.pages {
            for card in page.cards where card.isAnimated { clocks[card.id] = AnimationClock() }
        }
    }

    // MARK: Editing

    /// Applies an undoable change. `reload` makes canvases pick up ink that changed outside them.
    private func edit(_ name: String, reload: Bool = true, _ change: (inout NoteContent) -> Void) {
        let before = content
        change(&content)
        guard content != before else { return }
        undoManager.beginUndoGrouping()
        registerUndo(name, restoring: before)
        undoManager.endUndoGrouping()
        if reload { reloadToken += 1 }
        changed()
    }

    private func registerUndo(_ name: String, restoring snapshot: NoteContent) {
        undoManager.registerUndo(withTarget: self) { model in
            let current = model.content
            var restored = snapshot
            restored.history = current.history // History isn't undone.
            model.content = restored
            model.reloadToken += 1
            model.registerUndo(name, restoring: current)
            model.fixCurrentPage()
            model.changed()
        }
        undoManager.setActionName(name)
    }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
        refreshUndo()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
        refreshUndo()
    }

    private func refreshUndo() {
        canUndo = undoManager.canUndo
        canRedo = undoManager.canRedo
    }

    private func changed() {
        refreshUndo()
        store.touch(document.id)
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.file.save(self.content)
        }
    }

    func saveNow() {
        saveTask?.cancel()
        file.save(content)
    }

    private func fixCurrentPage() {
        if page(currentPageID ?? UUID()) == nil { currentPageID = content.pages.first?.id }
    }

    private func log(_ text: String, by author: HistoryEntry.Author = .you) {
        content.history.append(HistoryEntry(author: author, text: text))
    }

    private func index(of pageID: UUID) -> Int? { content.pages.firstIndex { $0.id == pageID } }

    /// A stroke, erase or lasso move finished on a canvas.
    func canvasChanged(page pageID: UUID, drawing: PKDrawing) {
        guard let i = index(of: pageID), content.pages[i].drawing != drawing else { return }
        edit("Drawing", reload: false) { $0.pages[i].drawing = drawing }
    }

    // MARK: Pages

    @discardableResult
    func addPage(after pageID: UUID?) -> UUID {
        let page = NotePage()
        let at = pageID.flatMap(index(of:)).map { $0 + 1 } ?? content.pages.count
        edit("Add Page") {
            $0.pages.insert(page, at: at)
            $0.history.append(HistoryEntry(author: .you, text: "Added page \(at + 1)"))
        }
        return page.id
    }

    @discardableResult
    func duplicatePage(_ pageID: UUID) -> UUID? {
        guard let i = index(of: pageID) else { return nil }
        let copy = content.pages[i].duplicated()
        edit("Duplicate Page") {
            $0.pages.insert(copy, at: i + 1)
            $0.history.append(HistoryEntry(author: .you, text: "Duplicated page \(i + 1)"))
        }
        for card in copy.cards where card.isAnimated { clocks[card.id] = AnimationClock() }
        return copy.id
    }

    func deletePage(_ pageID: UUID) {
        guard content.pages.count > 1, let i = index(of: pageID) else { return }
        edit("Delete Page") {
            $0.pages.remove(at: i)
            $0.history.append(HistoryEntry(author: .you, text: "Deleted page \(i + 1)"))
        }
        fixCurrentPage()
    }

    func addSpace(to pageID: UUID) {
        guard let i = index(of: pageID) else { return }
        edit("Add Space") {
            $0.pages[i].height += NotePageMetrics.addedSpace
            $0.history.append(HistoryEntry(author: .you, text: "Added space to page \(i + 1)"))
        }
    }

    var background: PageBackground? { content.background }

    func setBackground(_ background: PageBackground) {
        edit("Page Background", reload: false) {
            $0.background = background
            $0.history.append(HistoryEntry(author: .you, text: "Changed the page background to \(background.title)"))
        }
    }

    /// Removes everything the agent drew, wrote and made.
    func clearAgentMarks() {
        edit("Clear Agent's Marks") {
            for i in $0.pages.indices {
                $0.pages[i].agentDrawing = PKDrawing()
                $0.pages[i].cards = []
            }
            $0.history.append(HistoryEntry(author: .you, text: "Cleared the agent's marks"))
        }
    }

    var hasAgentMarks: Bool {
        content.pages.contains { !$0.agentDrawing.strokes.isEmpty || !$0.cards.isEmpty }
    }

    // MARK: Cards

    func closeCard(_ id: UUID) {
        edit("Close Card", reload: false) {
            for i in $0.pages.indices { $0.pages[i].cards.removeAll { $0.id == id } }
        }
    }

    func resizeCard(_ id: UUID, to size: CGSize) {
        edit("Resize Card", reload: false) {
            for i in $0.pages.indices {
                guard let c = $0.pages[i].cards.firstIndex(where: { $0.id == id }) else { continue }
                let page = $0.pages[i].bounds
                var frame = $0.pages[i].cards[c].frame
                frame.size.width = min(max(size.width, AgentCard.minimumSize.width), page.maxX - frame.minX)
                frame.size.height = min(max(size.height, AgentCard.minimumSize.height), page.maxY - frame.minY)
                $0.pages[i].cards[c].frame = frame
            }
        }
    }

    func clock(for cardID: UUID) -> AnimationClock? { clocks[cardID] }

    func togglePlay(_ cardID: UUID) {
        var clock = clocks[cardID] ?? AnimationClock(startedAt: nil)
        if let started = clock.startedAt {
            clock.elapsed += Date.now.timeIntervalSince(started)
            clock.startedAt = nil
        } else {
            clock.startedAt = .now
        }
        clocks[cardID] = clock
    }

    func stopAnimation(_ cardID: UUID) {
        clocks[cardID] = AnimationClock(elapsed: 0, startedAt: nil)
    }

    /// Adds a card the agent made (for the agent, and previews).
    func addCard(_ card: AgentCard, to pageID: UUID) {
        guard let i = index(of: pageID) else { return }
        edit("Add Card", reload: false) {
            $0.pages[i].cards.append(card)
            $0.history.append(HistoryEntry(author: .agent, text: "Made “\(card.title)”"))
        }
        if card.isAnimated { clocks[card.id] = AnimationClock() }
    }

    // MARK: Images

    func image(named fileName: String) -> UIImage? {
        if let cached = images[fileName] { return cached }
        guard let url = file.imageURL(fileName), let image = UIImage(contentsOfFile: url.path) else { return nil }
        images[fileName] = image
        return image
    }

    /// Starts positioning a photo on the current page.
    func beginPlacement(_ data: Data) {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0,
              let pageID = currentPageID ?? content.pages.first?.id, let page = page(pageID) else {
            banner = .error("That image couldn't be opened.")
            return
        }
        let fit = min(520 / image.size.width, 420 / image.size.height, 1)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let frame = CGRect(x: (NotePageMetrics.width - size.width) / 2, y: (min(page.height, 850) - size.height) / 2,
                           width: size.width, height: size.height)
        placement = ImagePlacement(pageID: pageID, image: image, data: data, frame: frame)
    }

    func movePlacement(by offset: CGSize) {
        guard var p = placement, let page = page(p.pageID) else { return }
        p.frame.origin.x = min(max(p.frame.minX + offset.width, -p.frame.width / 2), page.bounds.maxX - p.frame.width / 2)
        p.frame.origin.y = min(max(p.frame.minY + offset.height, -p.frame.height / 2), page.bounds.maxY - p.frame.height / 2)
        placement = p
    }

    /// Scales the photo being placed about its centre.
    func scalePlacement(by factor: CGFloat) {
        guard var p = placement else { return }
        let width = min(max(p.frame.width * factor, 60), NotePageMetrics.width)
        let scale = width / p.frame.width
        let center = CGPoint(x: p.frame.midX, y: p.frame.midY)
        p.frame.size = CGSize(width: p.frame.width * scale, height: p.frame.height * scale)
        p.frame.origin = CGPoint(x: center.x - p.frame.width / 2, y: center.y - p.frame.height / 2)
        placement = p
    }

    func cancelPlacement() { placement = nil }

    func place() {
        guard let p = placement, let i = index(of: p.pageID) else { placement = nil; return }
        let data = p.image.jpegData(compressionQuality: 0.9) ?? p.data
        let name = file.saveImage(data)
        images[name] = p.image
        edit("Add Image", reload: false) {
            $0.pages[i].images.append(PlacedImage(fileName: name, frame: p.frame))
            $0.history.append(HistoryEntry(author: .you, text: "Added an image to page \(i + 1)"))
        }
        placement = nil
    }

    // MARK: Agent

    /// The agent control: starts talking, or stops whatever the agent is doing.
    func toggleAgent() {
        if agent != .idle {
            agent = .idle
            return
        }
        guard keysReady() else { return }
        banner = nil
        agent = .listening
    }

    /// Sends what was typed to the agent.
    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, keysReady(voice: false) else { return }
        log(text)
        changed()
    }

    func choose(_ option: String) {
        banner = nil
        log("Chose “\(option)”")
        changed()
    }

    func retry() {
        banner = nil
        toggleAgent()
    }

    /// Shows an error banner if a needed key is missing.
    private func keysReady(voice: Bool = true) -> Bool {
        if (Keychain.read(.ai) ?? "").isEmpty {
            banner = .error("Add your Anthropic API key in Settings to work with the agent.")
            return false
        }
        if voice, (Keychain.read(.voice) ?? "").isEmpty {
            banner = .error("Add your ElevenLabs API key in Settings to talk to the agent.")
            return false
        }
        return true
    }

    // MARK: Swatches

    private static let swatchesKey = "canvasSwatches"
    static let defaultSwatches = ["#1C1C1E", "#007AFF", "#FF3B30", "#34C759", "#FFCC00"]

    private static func loadSwatches() -> [String] {
        let saved = UserDefaults.standard.stringArray(forKey: swatchesKey) ?? []
        return saved.isEmpty ? defaultSwatches : saved
    }

    private func saveSwatches() {
        UserDefaults.standard.set(swatches, forKey: Self.swatchesKey)
    }

    func selectSwatch(_ index: Int) {
        selectedSwatch = index
        if tool == .eraser || tool == .lasso { tool = .pen }
    }

    /// Adds a colour and selects it; returns its index.
    func addSwatch(_ color: UIColor) -> Int {
        swatches.append(color.hex)
        saveSwatches()
        selectSwatch(swatches.count - 1)
        return swatches.count - 1
    }

    func setSwatch(_ index: Int, to color: UIColor) {
        guard swatches.indices.contains(index) else { return }
        swatches[index] = color.hex
        saveSwatches()
    }

    func removeSwatch(_ index: Int) {
        guard swatches.count > 1, swatches.indices.contains(index) else { return }
        swatches.remove(at: index)
        saveSwatches()
        if selectedSwatch >= index { selectedSwatch = max(0, selectedSwatch - 1) }
    }
}

extension UIColor {
    /// `"#RRGGBB"`.
    convenience init(hex: String) {
        let value = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    var hex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}
