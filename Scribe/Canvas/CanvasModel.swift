import PencilKit
import SwiftUI

/// What the agent is doing, shown by the agent control.
enum AgentState: Equatable {
    case idle, listening, thinking, speaking
}

/// The agent's answer. Spoken, it streams through the agent bar a word at a time, in time with the voice. Otherwise
/// it sits still in the reply bar under the agent control, to be read at the person's own pace.
struct AgentReply: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// When each word is said, in seconds from when the reply appears, if it's being spoken.
    var wordStarts: [TimeInterval]?

    var spoken: Bool { wordStarts != nil }
    var words: [String] { Self.words(in: text) }

    static func words(in text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// A banner just under the top row.
enum CanvasBanner: Equatable {
    /// Something went wrong with the agent; offers Settings and Try again.
    case error(String)
    /// Something else to know (an image that couldn't be opened, a save that failed); offers OK.
    case notice(String)
    /// The agent asks the person to pick one of a few chips.
    case choice(prompt: String, options: [String])
}

/// The image that's selected for moving, resizing and rotating.
struct ImageSelection: Equatable {
    var pageID: UUID
    var imageID: UUID
}

/// Where an image goes among the page's other images.
enum ImageArrangement {
    case front, forward, backward, back

    var title: String {
        switch self {
        case .front: "Bring to Front"
        case .forward: "Bring Forward"
        case .backward: "Send Backward"
        case .back: "Send to Back"
        }
    }

    var symbol: String {
        switch self {
        case .front: "square.3.layers.3d.top.filled"
        case .forward: "square.2.layers.3d.top.filled"
        case .backward: "square.2.layers.3d.bottom.filled"
        case .back: "square.3.layers.3d.bottom.filled"
        }
    }
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
    /// The imported PDF this note marks up, if it is one. Never changed.
    let pdfURL: URL?
    @ObservationIgnored private let store: CanvasStore

    // MARK: Pages

    /// The page at the top of the screen (bound to the scroll position).
    var currentPageID: UUID?
    /// Bumped whenever page ink changes from outside a canvas (undo, duplicating, clearing), so canvases reload it.
    private(set) var reloadToken = 0
    /// Everything on each page with a stable ID and exact bounds: what the agent sees and draws against.
    let pageMapper: PageMapper
    /// The mark the agent is drawing right now, revealed like a pen.
    private(set) var liveMark: LiveMark?
    /// The agent's cursor, while it's out of the pill drawing on a page.
    private(set) var agentCursor: AgentCursor?
    /// Where the pages, the agent pill and the floating controls are on screen.
    @ObservationIgnored let frames = CanvasFrames()

    var currentPageIndex: Int {
        content.pages.firstIndex { $0.id == currentPageID } ?? 0
    }

    func page(_ id: UUID) -> NotePage? { content.pages.first { $0.id == id } }

    // MARK: Tools

    let palette = ToolPalette()

    // MARK: Agent and banners

    var agent = AgentState.idle
    /// The agent's answer: streaming through the agent bar if it's spoken, otherwise in the reply bar under it.
    var reply: AgentReply?
    /// The agent's answer when it isn't spoken, for the reply bar. It stays until the person moves on.
    var textReply: AgentReply? { agent == .idle && reply?.spoken == false ? reply : nil }
    /// What's typed in the "Ask the agent…" field.
    var draft = ""
    /// What the person has said so far while the agent listens, as it's recognised.
    var heard = ""
    /// How loud the person (while listening) or the agent's voice (while speaking) is right now, 0 to 1. The dot
    /// follows it.
    var level: Double = 0

    /// A level meter's dBFS as 0 to 1: quiet rooms sit near 0, speech close to the microphone near 1.
    private static func loudness(_ power: Float) -> Double {
        min(1, max(0, (Double(power) + 50) / 40))
    }
    var banner: CanvasBanner?
    var selectedImage: ImageSelection?
    /// The page on screen is zoomed in, so drags pan it instead of turning the page.
    var pageZoomed = false
    /// The room a PDF page has on the desk, measured from the chrome (in screen points from the top): below the top
    /// controls, and above the bottom controls. Nil until the chrome has been laid out.
    var deskTop: CGFloat?
    var deskBottom: CGFloat?
    var showsKeyboard = false
    var enlargedCard: AgentCard?

    // MARK: Lasso

    /// The region lassoed on a page, while it's selected. What the person says or types to the agent meanwhile is
    /// about it.
    var lasso: LassoSelection?
    /// Where the lasso tapped, offering to paste copied ink.
    var pasteSpot: PasteSpot?
    /// The selected ink, off the page while it's dragged.
    private(set) var liftedInk: PKDrawing?
    @ObservationIgnored private var beforeLift: NoteContent?
    /// How much help the last Help gave, and where, so asking again on the same spot gives more.
    private var helpLadder = HelpLadder()

    // MARK: Visualizations (hovering over the page, top right)

    /// The cards are out, not tucked away. They only show while there's something to show. Saved with the note (not
    /// an undo step), so cards tucked away stay away the next time it opens.
    var showsVisualizations: Bool {
        get { !content.hidesVisualizations }
        set {
            guard newValue == content.hidesVisualizations else { return }
            content.hidesVisualizations = !newValue
            scheduleSave()
        }
    }
    /// The agent is writing a visualization: a placeholder card waits at the end of the stack.
    var draftingVisualization = false
    /// The error each page hit, and how many times it's been replayed. Not saved.
    var visualizationErrors: [UUID: String] = [:]
    var visualizationReloads: [UUID: Int] = [:]
    /// Cards the person paused, and cards the agent is remaking. Not saved.
    var pausedVisualizations: Set<UUID> = []
    var remakingVisualizations: Set<UUID> = []
    var enlargedVisualization: Visualization?
    /// The card just closed, while its Undo shows.
    var closedVisualization: ClosedVisualization?
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
        let pdfURL = document.kind == .pdf ? store.fileURL(for: document) : nil
        let loaded = file.read(pdf: pdfURL)
        let content = loaded.content
        if loaded.fromDisk {
            file.removeImages(notIn: Set(content.pages.flatMap { $0.images.map(\.fileName) }))
            file.removeVisualizationImages(notIn: Set(content.visualizations.map(\.id)))
        }
        self.pdfURL = pdfURL
        self.file = file
        self.content = content
        pageMapper = PageMapper(pdfURL: pdfURL)
        currentPageID = content.pages.first?.id
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
            restored.history = current.history // History and the conversation aren't undone.
            restored.conversation = current.conversation
            restored.hidesVisualizations = current.hidesVisualizations // Nor tucking the cards away.
            model.content = restored
            model.reloadToken += 1
            model.registerUndo(name, restoring: current)
            model.fixCurrentPage()
            if let selection = model.selectedImage, model.placedImage(selection) == nil { model.selectedImage = nil }
            model.lasso = nil // Its stroke indices no longer match the page.
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
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self else { return }
            self.write()
        }
    }

    /// Writes the note now; says so on the page if it can't be saved.
    private func write() {
        if file.save(content) {
            if case .notice(let text) = banner, text == Self.saveFailed { banner = nil }
        } else {
            banner = .notice(Self.saveFailed)
        }
        NoteThumbnails.shared.invalidate(document.id)
    }

    private static let saveFailed = "This note couldn't be saved. Free up some space on your iPad, then keep working: it saves again with every change."

    func saveNow() {
        saveTask?.cancel()
        write()
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
        pageMapper.inkChanged(content.pages[i]) { [weak self] in self?.refreshPageMap(pageID) }
    }

    /// Maps the page again (for the debug overlay) and, with the overlay on, saves it as a fixture.
    func refreshPageMap(_ pageID: UUID) {
        guard let page = page(pageID) else { return }
        Task {
            let snapshot = await pageMapper.snapshot(of: page, render: renderForPageMap)
            guard PageMapDebug.shared.showOverlay, let n = index(of: pageID) else { return }
            let name = "\(document.title.isEmpty ? "Untitled" : document.title)/page-\(n + 1)"
            do {
                try PageFixture.save(snapshot, name: name)
            } catch {
                PageMapDebug.log.error("Couldn't save the page map fixture: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The page as the agent sees it: paper (no dots or grid, which would read as ink), photos, both inks and cards.
    private func renderForPageMap(_ page: NotePage, scale: CGFloat) -> UIImage? {
        PageRenderer.image(of: page, background: .none, pixelWidth: (NotePageMetrics.width * scale).rounded(),
                           pdf: pdfURL) { [weak self] in self?.image(named: $0) }
    }

    // MARK: Pages

    /// Adds a blank page after `pageID`, or at the end.
    @discardableResult
    func addPage(after pageID: UUID?) -> UUID {
        addPage(at: pageID.flatMap(index(of:)).map { $0 + 1 } ?? content.pages.count)
    }

    @discardableResult
    func addPage(at index: Int) -> UUID {
        let page = NotePage(height: screenPageHeight)
        let at = min(max(index, 0), content.pages.count)
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

    /// Moves a page to `index` in the list (one undo step).
    func movePage(_ pageID: UUID, to index: Int) {
        guard let from = self.index(of: pageID) else { return }
        let to = min(max(index, 0), content.pages.count - 1)
        guard from != to else { return }
        edit("Move Page", reload: false) {
            let page = $0.pages.remove(at: from)
            $0.pages.insert(page, at: to)
            $0.history.append(HistoryEntry(author: .you, text: "Moved page \(from + 1) to \(to + 1)"))
        }
    }

    /// Whether deleting the page would lose anything.
    func pageHasContent(_ pageID: UUID) -> Bool {
        guard let page = page(pageID) else { return false }
        return !page.drawing.strokes.isEmpty || !page.images.isEmpty || page.hasAgentMarks
    }

    /// A page's height in page points when it exactly fills the screen. New pages are made this size.
    private(set) var screenPageHeight = NotePageMetrics.height

    /// Sizes pages to the screen (a PDF page keeps its own shape): a blank page fits it exactly, a page with something on it only ever grows (so
    /// nothing is cut off, and a page written in portrait scrolls in landscape). Not an undo step.
    func fitPages(toHeight height: CGFloat) {
        screenPageHeight = height
        var changed = false
        for i in content.pages.indices where content.pages[i].pdfPage == nil {
            let page = content.pages[i]
            let blank = !pageHasContent(page.id)
            guard blank ? abs(page.height - height) > 0.5 : page.height < height else { continue }
            content.pages[i].height = height
            changed = true
        }
        if changed { scheduleSave() }
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
                $0.pages[i].agentMarks = []
                $0.pages[i].cards = []
            }
            $0.visualizations = []
            $0.history.append(HistoryEntry(author: .you, text: "Cleared the agent's marks"))
        }
    }

    var hasAgentMarks: Bool {
        content.pages.contains(where: \.hasAgentMarks) || !content.visualizations.isEmpty
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

    // MARK: Visualizations

    /// There's a card (or one on the way) to show.
    var hasVisualizations: Bool { !content.visualizations.isEmpty || draftingVisualization }

    /// Adds a visualization at the end of the stack and brings the cards out. One undo step.
    func addVisualization(_ visualization: Visualization) {
        edit("Add Visualization", reload: false) {
            $0.visualizations.append(visualization)
            $0.history.append(HistoryEntry(author: .agent, text: "Made “\(visualization.title)”"))
        }
        showsVisualizations = true
    }

    /// Closes a card. It can come back: an Undo shows in its place for a while (and Undo in the toolbar works too).
    func closeVisualization(_ id: UUID) {
        guard let index = content.visualizations.firstIndex(where: { $0.id == id }) else { return }
        let visualization = content.visualizations[index]
        edit("Close Visualization", reload: false) { $0.visualizations.removeAll { $0.id == id } }
        visualizationErrors[id] = nil
        pausedVisualizations.remove(id)
        closedVisualization = ClosedVisualization(visualization: visualization, index: index)
        let closed = closedVisualization?.id
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            if let self, self.closedVisualization?.id == closed { self.closedVisualization = nil }
        }
    }

    /// Brings back the card just closed, where it was.
    func reopenClosedVisualization() {
        guard let closed = closedVisualization else { return }
        closedVisualization = nil
        guard !content.visualizations.contains(where: { $0.id == closed.visualization.id }) else { return }
        edit("Reopen Visualization", reload: false) {
            $0.visualizations.insert(closed.visualization, at: min(closed.index, $0.visualizations.count))
        }
        showsVisualizations = true
    }

    /// Replay: the page starts over.
    func replayVisualization(_ id: UUID) {
        visualizationReloads[id, default: 0] += 1
        visualizationErrors[id] = nil
        pausedVisualizations.remove(id)
    }

    /// Pause: the card stands still (it can still be dragged and its controls used); tap again to carry on.
    func togglePauseVisualization(_ id: UUID) {
        if pausedVisualizations.remove(id) == nil { pausedVisualizations.insert(id) }
    }

    /// Remake: the agent makes the card again from its old page, clearer and simpler. The new card takes the old
    /// one's place (Undo brings the old one back).
    func remakeVisualization(_ id: UUID) {
        guard let old = content.visualizations.first(where: { $0.id == id }), !remakingVisualizations.contains(id),
              keysReady(voice: false), let claude = ClaudeClient() else { return }
        let recent = content.conversation.suffix(6).map { ($0.speaker == .you ? "Person: " : "You: ") + $0.text }
        remakingVisualizations.insert(id)
        Task { [weak self] in
            do {
                let new = try await Self.remake(old, recent: recent, claude: claude)
                guard let self else { return }
                self.remakingVisualizations.remove(id)
                withAnimation(.snappy) {
                    self.edit("Remake Visualization", reload: false) { content in
                        guard let i = content.visualizations.firstIndex(where: { $0.id == id }) else { return }
                        content.visualizations[i] = new
                        content.history.append(HistoryEntry(author: .agent, text: "Remade “\(new.title)”"))
                    }
                }
                self.visualizationErrors[id] = nil
                self.pausedVisualizations.remove(id)
            } catch {
                guard let self else { return }
                self.remakingVisualizations.remove(id)
                if !(error is CancellationError) { self.banner = .error(error.localizedDescription) }
            }
        }
    }

    /// Asks Claude for a clearer, simpler version of a visualization, checking the new page off screen (one fix).
    private static func remake(_ old: Visualization, recent: [String], claude: ClaudeClient) async throws -> Visualization {
        var messages: [JSONValue] = [["role": "user", "content": .string(VisualizationTool.remakeRequest(old, recent: recent))]]
        var fixesLeft = 1
        for _ in 0..<3 {
            let turn = try await claude.sendWithTools(messages, system: VisualizationTool.remakeSystem,
                                                      tools: [VisualizationTool.definition])
            try Task.checkCancellation()
            if turn.stopReason == "refusal" { throw ClaudeClient.ReplyError.declined }
            guard let call = turn.toolUses.first(where: { $0.name == VisualizationTool.name }) else {
                throw turn.stopReason == "max_tokens" ? ClaudeClient.ReplyError.cutOff : ClaudeClient.ReplyError.empty
            }
            let problem: String
            if turn.brokenToolIDs.contains(call.id) {
                problem = "The call was cut off before the page was complete. Send a shorter page."
            } else {
                switch VisualizationTool.visualization(from: call.input) {
                case .failure(let error):
                    problem = "It wasn't shown: \(error.message)."
                case .success(let v):
                    guard let found = await WebCardProbe.check(v.html), fixesLeft > 0 else { return v }
                    fixesLeft -= 1
                    problem = "It wasn't shown: \(found). Fix it and call \(VisualizationTool.name) again."
                }
            }
            messages.append(["role": "assistant", "content": .array(turn.content.filter { $0 != .null })])
            messages.append(["role": "user", "content": [["type": "tool_result", "tool_use_id": .string(call.id),
                                                          "content": .string(problem), "is_error": true]]])
        }
        throw ClaudeClient.ReplyError.empty
    }

    /// What a visualization's page said.
    func visualizationMessage(_ message: CardMessage, from id: UUID) {
        switch message {
        case .ready:
            visualizationErrors[id] = nil
        case .error(let text, _):
            visualizationErrors[id] = text
        case .paused(let paused):
            if paused { pausedVisualizations.insert(id) } else { pausedVisualizations.remove(id) }
        case .resize(let height):
            guard let i = content.visualizations.firstIndex(where: { $0.id == id }) else { return }
            let h = min(max(height, Visualization.heights.lowerBound), Visualization.heights.upperBound)
            guard abs(content.visualizations[i].height - h) > 0.5 else { return }
            content.visualizations[i].height = h // The page's own layout, not an undo step.
            scheduleSave()
        case .focus:
            break
        }
    }

    /// A picture of a visualization's page just after it started, kept for the library's thumbnail of this note.
    func visualizationSnapshot(_ image: UIImage, for id: UUID) {
        guard content.visualizations.contains(where: { $0.id == id }) else { return }
        let file = file, documentID = document.id
        Task.detached(priority: .utility) {
            guard let data = image.pngData() else { return }
            file.saveVisualizationImage(data, for: id)
            await MainActor.run { NoteThumbnails.shared.invalidate(documentID) }
        }
    }

    // MARK: Images

    func image(named fileName: String) -> UIImage? {
        if let cached = images[fileName] { return cached }
        guard let url = file.imageURL(fileName), let image = UIImage(contentsOfFile: url.path) else { return nil }
        images[fileName] = image
        return image
    }

    /// Puts a picked image in the middle of the page on screen, selected, so it can be moved and sized straight
    /// away. One undo step.
    func addImage(_ data: Data) {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0,
              let pageID = currentPageID ?? content.pages.first?.id, let i = index(of: pageID) else {
            banner = .notice("That image couldn't be opened.")
            return
        }
        let page = content.pages[i]
        let fit = min(520 / image.size.width, 420 / image.size.height, 1)
        let size = CGSize(width: image.size.width * fit, height: image.size.height * fit)
        let visible = min(page.height, screenPageHeight)
        let frame = CGRect(x: (NotePageMetrics.width - size.width) / 2, y: (visible - size.height) / 2,
                           width: size.width, height: size.height)
        let normalized = image.normalizedUp()
        let name = file.saveImage(normalized.jpegData(compressionQuality: 0.9) ?? data)
        images[name] = normalized
        let placed = PlacedImage(fileName: name, frame: frame)
        edit("Add Image", reload: false) {
            $0.pages[i].images.append(placed)
            $0.history.append(HistoryEntry(author: .you, text: "Added an image to page \(i + 1)"))
        }
        selectedImage = ImageSelection(pageID: pageID, imageID: placed.id)
    }

    func placedImage(_ selection: ImageSelection) -> PlacedImage? {
        page(selection.pageID)?.images.first { $0.id == selection.imageID }
    }

    /// A finger tap on a page: selects the topmost image under it, or clears the selection. With the lasso, a tap
    /// away from the selection puts it down, and a tap on an empty spot offers to paste copied ink.
    func tapPage(_ pageID: UUID, at point: CGPoint) {
        moveOn()
        if palette.tool == .lasso {
            if let lasso, lasso.pageID == pageID, lasso.bounds.insetBy(dx: -12, dy: -12).contains(point) { return }
            let hadSelection = lasso != nil || pasteSpot != nil
            withAnimation(.snappy) {
                lasso = nil
                pasteSpot = !hadSelection && InkPasteboard.hasInk ? PasteSpot(pageID: pageID, point: point) : nil
            }
            return
        }
        guard let page = page(pageID), let hit = page.images.last(where: { $0.contains(point) }) else {
            selectedImage = nil
            return
        }
        selectedImage = ImageSelection(pageID: pageID, imageID: hit.id)
    }

    /// Moves, resizes or rotates an image (the end of one gesture: one undo step). A dragged image comes to the
    /// front, so it never ends up hidden behind another.
    func transformImage(_ selection: ImageSelection, frame: CGRect, rotation: Double, toFront: Bool = false) {
        guard let i = index(of: selection.pageID),
              let j = content.pages[i].images.firstIndex(where: { $0.id == selection.imageID }) else { return }
        edit("Move Image", reload: false) {
            $0.pages[i].images[j].frame = frame
            $0.pages[i].images[j].rotation = rotation
            if toFront { $0.pages[i].images.append($0.pages[i].images.remove(at: j)) }
        }
    }

    /// Where the selected image sits among the page's images, from back (0) to front.
    func canArrange(_ selection: ImageSelection, _ arrangement: ImageArrangement) -> Bool {
        guard let images = page(selection.pageID)?.images,
              let j = images.firstIndex(where: { $0.id == selection.imageID }) else { return false }
        switch arrangement {
        case .front, .forward: return j < images.count - 1
        case .backward, .back: return j > 0
        }
    }

    /// Moves an image in front of or behind the page's other images (still under the ink). One undo step.
    func arrangeImage(_ selection: ImageSelection, _ arrangement: ImageArrangement) {
        guard canArrange(selection, arrangement), let i = index(of: selection.pageID),
              let j = content.pages[i].images.firstIndex(where: { $0.id == selection.imageID }) else { return }
        let last = content.pages[i].images.count - 1
        let to: Int = switch arrangement {
        case .front: last
        case .forward: j + 1
        case .backward: j - 1
        case .back: 0
        }
        edit(arrangement.title, reload: false) {
            let image = $0.pages[i].images.remove(at: j)
            $0.pages[i].images.insert(image, at: to)
        }
    }

    func deleteImage(_ selection: ImageSelection) {
        guard let i = index(of: selection.pageID) else { return }
        edit("Delete Image", reload: false) {
            $0.pages[i].images.removeAll { $0.id == selection.imageID }
            $0.history.append(HistoryEntry(author: .you, text: "Deleted an image from page \(i + 1)"))
        }
        selectedImage = nil
    }

    // MARK: Lasso

    /// A loop finished on a page: selects the region and the ink in it.
    func finishLasso(on pageID: UUID, path: [CGPoint]) {
        pasteSpot = nil
        let bounds = LassoGeometry.bounds(of: path)
        guard path.count > 2, let page = page(pageID), max(bounds.width, bounds.height) > 8 else {
            withAnimation(.snappy) { lasso = nil }
            return
        }
        withAnimation(.snappy) {
            lasso = LassoSelection(pageID: pageID, path: path, strokes: LassoGeometry.strokes(in: path, of: page.drawing))
        }
    }

    /// Ends the selection (picking another tool, turning the page).
    func clearLasso() {
        if liftedInk != nil { dropSelection(by: .zero) }
        lasso = nil
        pasteSpot = nil
    }

    private var selectedInk: PKDrawing? {
        guard let lasso, lasso.hasInk, let strokes = page(lasso.pageID)?.drawing.strokes else { return nil }
        return PKDrawing(strokes: lasso.strokes.filter { $0 < strokes.count }.map { strokes[$0] })
    }

    /// The page's strokes without the selected ones.
    private func strokes(on pageIndex: Int, without picked: IndexSet) -> [PKStroke] {
        content.pages[pageIndex].drawing.strokes.enumerated().filter { !picked.contains($0.offset) }.map(\.element)
    }

    func copySelection() {
        guard let ink = selectedInk else { return }
        InkPasteboard.copy(ink)
    }

    func cutSelection() {
        copySelection()
        deleteSelection(named: "Cut")
    }

    func deleteSelection(named name: String = "Delete") {
        guard let lasso, lasso.hasInk, let i = index(of: lasso.pageID) else { return }
        let kept = strokes(on: i, without: lasso.strokes)
        edit(name) { $0.pages[i].drawing = PKDrawing(strokes: kept) }
        self.lasso = nil
        inkEdited(on: i)
    }

    /// Pastes copied ink centred on the spot, and selects it.
    func paste(at spot: PasteSpot) {
        pasteSpot = nil
        guard let ink = InkPasteboard.read(), !ink.strokes.isEmpty, let i = index(of: spot.pageID) else { return }
        let b = ink.bounds
        let placed = ink.transformed(using: CGAffineTransform(translationX: spot.point.x - b.midX, y: spot.point.y - b.midY))
        let existing = content.pages[i].drawing.strokes
        edit("Paste") { $0.pages[i].drawing = PKDrawing(strokes: existing + placed.strokes) }
        let pb = placed.bounds.insetBy(dx: -10, dy: -10)
        lasso = LassoSelection(pageID: spot.pageID,
                               path: [pb.origin, CGPoint(x: pb.maxX, y: pb.minY), CGPoint(x: pb.maxX, y: pb.maxY),
                                      CGPoint(x: pb.minX, y: pb.maxY)],
                               strokes: IndexSet(existing.count..<existing.count + placed.strokes.count))
        inkEdited(on: i)
    }

    /// Takes the selected ink off the page while it's dragged (the overlay draws it under the finger). Not an undo
    /// step: `dropSelection` makes the whole move one.
    func liftSelection() {
        guard liftedInk == nil, let lasso, let ink = selectedInk, let i = index(of: lasso.pageID) else { return }
        beforeLift = content
        liftedInk = ink
        content.pages[i].drawing = PKDrawing(strokes: strokes(on: i, without: lasso.strokes))
        reloadToken += 1
    }

    /// Puts the dragged ink down, moved by `offset` page points. One undo step.
    func dropSelection(by offset: CGSize) {
        guard let ink = liftedInk, let before = beforeLift, let lasso, let i = index(of: lasso.pageID) else {
            liftedInk = nil
            beforeLift = nil
            return
        }
        liftedInk = nil
        beforeLift = nil
        let rest = content.pages[i].drawing.strokes
        let moved = ink.transformed(using: CGAffineTransform(translationX: offset.width, y: offset.height)).strokes
        content = before
        edit("Move") { $0.pages[i].drawing = PKDrawing(strokes: rest + moved) }
        reloadToken += 1
        self.lasso = LassoSelection(pageID: lasso.pageID, path: lasso.translated(by: offset).path,
                                    strokes: IndexSet(rest.count..<rest.count + moved.count))
        inkEdited(on: i)
    }

    /// Ink changed outside the canvas: the agent's map of the page catches up.
    private func inkEdited(on pageIndex: Int) {
        let page = content.pages[pageIndex]
        pageMapper.inkChanged(page) { [weak self] in self?.refreshPageMap(page.id) }
    }

    /// Help for the selection: the next rung up if Help was last asked for on the same spot.
    func helpAction(for selection: LassoSelection) -> LassoAction {
        .help(level: helpLadder.level(for: selection.pageID, bounds: selection.bounds))
    }

    /// Sends the lassoed region to the agent: Help writes help beside it (fuller each time on the same spot),
    /// Visualize opens a card.
    func ask(_ action: LassoAction) {
        guard let lasso, keysReady(voice: false) else { return }
        if case .help(let level) = action {
            helpLadder.climbed(to: level, pageID: lasso.pageID, bounds: lasso.bounds)
        }
        let focus = LassoFocus(pageID: lasso.pageID, bounds: lasso.bounds, action: action)
        self.lasso = nil
        showsKeyboard = false
        reply = nil
        banner = nil
        say(action.request, spoken: false)
        run { model in try await model.reply(speak: false, focus: focus) }
    }

    /// The selection as the subject of what's said or typed next, and put down.
    private func takeLassoFocus() -> LassoFocus? {
        guard let lasso else { return nil }
        withAnimation(.snappy) { self.lasso = nil }
        return LassoFocus(pageID: lasso.pageID, bounds: lasso.bounds, action: .ask)
    }

    /// A close-up of the region, sharp enough to read handwriting: a JPEG at most about 1600 px on its long side.
    private func closeUp(of focus: LassoFocus) -> Data? {
        guard let page = page(focus.pageID) else { return nil }
        let region = focus.bounds.insetBy(dx: -24, dy: -24).intersection(page.bounds)
        guard !region.isNull, region.width > 1, region.height > 1 else { return nil }
        let scale = min(3, max(1, 1600 / max(region.width, region.height)))
        guard let image = renderForPageMap(page, scale: scale)?.cgImage else { return nil }
        let px = CGFloat(image.width) / NotePageMetrics.width
        let crop = CGRect(x: region.minX * px, y: region.minY * px, width: region.width * px, height: region.height * px)
            .integral
        guard let cropped = image.cropping(to: crop) else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.85)
    }

    // MARK: Agent

    /// One line for the agent bar while the agent listens or works.
    var agentLine: String {
        switch agent {
        case .idle: ""
        case .listening: "Listening…"
        case .thinking: liveMark == nil && agentCursor == nil ? "Thinking…" : "Writing on your page…"
        case .speaking: "Speaking…"
        }
    }

    @ObservationIgnored private let voice = VoiceIO()
    @ObservationIgnored private var agentTask: Task<Void, Never>?

    /// Stops listening, thinking or speaking. Anything already said stays in the conversation.
    func stopAgent() {
        agentTask?.cancel()
        agentTask = nil
        voice.stopPlayback()
        agent = .idle
        reply = nil
        level = 0
    }

    /// The agent control: starts listening; while listening, sends what was said straight away; otherwise stops.
    func toggleAgent() {
        switch agent {
        case .idle:
            guard keysReady() else { return }
            banner = nil
            reply = nil
            listen(focus: lasso.map { LassoFocus(pageID: $0.pageID, bounds: $0.bounds, action: .ask) })
        case .listening:
            voice.finish()
        case .thinking, .speaking:
            stopAgent()
        }
    }

    /// Sends what was typed to the agent. It answers in text, without speaking. The field comes back once it has
    /// answered, for a follow-up.
    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, keysReady(voice: false) else { return }
        reply = nil
        banner = nil
        let focus = takeLassoFocus()
        say(text, spoken: false)
        run { model in try await model.reply(speak: false, focus: focus) }
    }

    func choose(_ option: String) {
        banner = nil
        log("Chose “\(option)”")
        changed()
    }

    /// After an error: answers what was last said if it never got a reply, or starts listening again.
    func retry() {
        banner = nil
        if let last = content.conversation.last, last.speaker == .you {
            guard keysReady(voice: last.spoken) else { return }
            run { model in try await model.reply(speak: last.spoken) }
        } else {
            toggleAgent()
        }
    }

    /// Speaks one of the agent's replies again.
    func replay(_ turn: ConversationTurn) {
        guard turn.speaker == .agent, keysReady() else { return }
        run { model in try await model.speak(turn.text) }
    }

    /// Voice to text as it's spoken (ElevenLabs realtime), then the agent's reply (Claude), then text to voice
    /// (ElevenLabs).
    /// `focus`: the lassoed region, when there's one; it stays selected while they talk.
    private func listen(focus: LassoFocus? = nil) {
        run { model in
            guard await VoiceIO.microphoneAllowed() else {
                model.banner = .error("Scribe can't hear you. Allow the microphone in Settings › Privacy & Security › Microphone.")
                return
            }
            guard let voiceKey = ElevenLabsClient() else { return }
            model.heard = ""
            model.agent = .listening
            let live = LiveTranscription(apiKey: voiceKey.apiKey) { words in
                withAnimation(.smooth(duration: 0.28)) { model.heard = words }
            } failed: {
                model.voice.finish()
            }
            defer {
                live.close()
                model.heard = ""
            }
            let spoke = try await model.voice.listen({ live.send($0) },
                                                     level: { model.level = Self.loudness($0) })
            model.level = 0
            guard spoke else { return }
            model.agent = .thinking
            let said = try await live.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            try Task.checkCancellation()
            guard !said.isEmpty else {
                model.banner = .notice("The agent didn't catch that. Tap the dot and try again.")
                return
            }
            if focus != nil { withAnimation(.snappy) { model.lasso = nil } }
            model.say(said, spoken: true)
            try await model.reply(speak: true, focus: focus)
        }
    }

    /// Runs one piece of agent work, replacing any before it. Errors become a banner; the agent ends idle.
    private func run(_ work: @escaping @MainActor (CanvasModel) async throws -> Void) {
        agentTask?.cancel()
        voice.stopPlayback()
        agentTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                if !Task.isCancelled, !(error is CancellationError) {
                    self.banner = .error(error.localizedDescription)
                }
            }
            guard !Task.isCancelled else { return }
            self.agent = .idle
            self.level = 0
            self.voice.deactivate()
        }
    }

    /// Asks Claude to answer the conversation so far, adds the answer, and speaks it if asked. On the way, Claude may
    /// open visualizations: each page is checked off screen first, and a page that fails goes back to Claude once to
    /// be fixed.
    /// With `focus`, the request is about a lassoed region: the agent works on its page and gets a close-up of it.
    private func reply(speak: Bool, focus: LassoFocus? = nil) async throws {
        guard let claude = ClaudeClient() else { return }
        agent = .thinking
        defer { draftingVisualization = false }
        var messages = Self.messages(for: content.conversation).map(\.json)

        // The page on screen, mapped: the agent sees its picture and everything on it, and can draw on it.
        let pageID = focus?.pageID ?? currentPageID ?? content.pages.first?.id
        var drawing: DrawingTurn?
        if let pageID, let i = index(of: pageID) {
            let page = content.pages[i]
            let snapshot = await pageMapper.snapshot(of: page, render: renderForPageMap)
            try Task.checkCancellation()
            Self.attach(snapshot, page: i + 1, of: content.pages.count, to: &messages)
            if let focus {
                Self.attach(focus.instructions(objects: focus.objects(in: snapshot)), closeUp: closeUp(of: focus),
                            to: &messages)
            }
            var context = ActionValidator.ToolContext(snapshot: snapshot, marks: page.agentMarks)
            context.chrome = chromeOnPage(pageID, height: page.height)
            context.canGrow = page.pdfPage == nil
            drawing = DrawingTurn(pageID: pageID, context: context, before: (page.agentMarks, page.height))
        }
        defer {
            liveMark = nil
            returnCursor()
            if let drawing { finish(drawing) }
        }

        var said: [String] = []
        var shown = 0
        var fixesLeft = 1
        for _ in 0..<6 {
            let turn = try await claude.sendWithTools(
                messages, system: Self.agentPrompt(title: document.title, visualizations: content.visualizations.map(\.title),
                                                   canDraw: drawing != nil && focus?.drawsOnPage != false),
                tools: [VisualizationTool.definition]
                    + (drawing == nil || focus?.drawsOnPage == false ? [] : AgentTools.definitions)) { [weak self] tool in
                    guard tool == VisualizationTool.name, let self else { return }
                    withAnimation(.snappy) {
                        self.draftingVisualization = true
                        self.showsVisualizations = true
                    }
                }
            try Task.checkCancellation()
            if turn.stopReason == "refusal" { throw ClaudeClient.ReplyError.declined }
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { said.append(text) }
            let calls = turn.toolUses
            guard turn.stopReason == "tool_use", !calls.isEmpty else {
                if said.isEmpty && shown == 0 && (drawing?.drawn ?? 0) == 0 {
                    throw turn.stopReason == "max_tokens" ? ClaudeClient.ReplyError.cutOff : ClaudeClient.ReplyError.empty
                }
                break
            }
            messages.append(["role": "assistant", "content": .array(turn.content.filter { $0 != .null })])
            var results: [JSONValue] = []
            for call in calls {
                let outcome: (result: String, isError: Bool)
                if call.name == VisualizationTool.name {
                    let shownNow = await showVisualization(call.name, input: call.input,
                                                           broken: turn.brokenToolIDs.contains(call.id), fixesLeft: &fixesLeft)
                    if shownNow.shown { shown += 1 }
                    outcome = (shownNow.result, shownNow.isError)
                } else if turn.brokenToolIDs.contains(call.id) {
                    outcome = ("The call was cut off before it was complete. Send it again, shorter.", true)
                } else if drawing != nil {
                    outcome = try await draw(call.name, input: call.input, turn: &drawing!)
                } else {
                    outcome = ("There's no tool called \(call.name).", true)
                }
                results.append(["type": "tool_result", "tool_use_id": .string(call.id),
                                "content": .string(outcome.result), "is_error": .bool(outcome.isError)])
            }
            withAnimation(.snappy) { draftingVisualization = false }
            try Task.checkCancellation()
            messages.append(["role": "user", "content": .array(results)])
        }
        // Done drawing: the cursor goes back into the pill before the answer.
        returnCursor()
        // Only the last thing said is the answer: text written before or between tool calls tends to be restated
        // in full once the marks are on the page, and joining them reads the same answer out twice.
        let answer = said.last ?? (shown > 0 ? "Here it is, in the top right." : "There, on your page.")
        content.conversation.append(ConversationTurn(speaker: .agent, text: answer, spoken: speak))
        changed()
        if speak {
            try await self.speak(answer)
        } else {
            self.reply = AgentReply(text: answer)
        }
    }

    /// Runs one `show_visualization` call: checks the page off screen, then adds it to the panel. The result is
    /// what goes back to Claude.
    private func showVisualization(_ tool: String, input: JSONValue, broken: Bool,
                                   fixesLeft: inout Int) async -> (result: String, isError: Bool, shown: Bool) {
        guard tool == VisualizationTool.name else { return ("There's no tool called \(tool).", true, false) }
        guard !broken else {
            return ("The call was cut off before the page was complete. Send a shorter page.", true, false)
        }
        let visualization: Visualization
        switch VisualizationTool.visualization(from: input) {
        case .success(let v): visualization = v
        case .failure(let error): return ("It wasn't shown: \(error.message).", true, false)
        }
        if let problem = await WebCardProbe.check(visualization.html) {
            if fixesLeft > 0 {
                fixesLeft -= 1
                return ("It wasn't shown: \(problem). Fix it and call \(VisualizationTool.name) again.", true, false)
            }
            withAnimation(.snappy) { addVisualization(visualization) }
            return ("It's shown, but it still has a problem: \(problem). Don't try again; say briefly that it may not work fully.",
                    false, true)
        }
        withAnimation(.snappy) { addVisualization(visualization) }
        return ("Shown as a card in the top right, below any earlier ones. Now say one short line about what to try.",
                false, true)
    }

    // MARK: Drawing on the page

    /// One turn's drawing on one page: what the validator knows so far, and the page as it was, for undo.
    private struct DrawingTurn {
        let pageID: UUID
        var context: ActionValidator.ToolContext
        let before: (marks: [AgentMark], height: CGFloat)
        var drawn = 0
        var changed = false
        /// The blank page after a document page, for what didn't fit on it.
        var scratch: ScratchPage?
    }

    /// A blank page the agent writes on when there's no room left on a document page (which never grows, so the
    /// document still prints and exports at its own size), like grabbing a sheet of scrap paper.
    private struct ScratchPage {
        var pageID: UUID
        var context: ActionValidator.ToolContext
        let before: (marks: [AgentMark], height: CGFloat)
        /// A new page, not in the note until something is drawn on it.
        var pending: NotePage?
        /// Where it goes (or went) in the note, when it's new.
        var index: Int
        /// It was added this turn.
        var added = false
        var changed = false
    }

    /// Runs one drawing tool call: checks it, then draws its marks one after another, each revealed like a pen.
    private func draw(_ tool: String, input: JSONValue, turn: inout DrawingTurn) async throws -> (result: String, isError: Bool) {
        var decision = ActionValidator.validate(tool, input: input, context: &turn.context)
        PageMapDebug.shared.logPlacement(tool, decision.notes, result: decision.result)
        var pageID = turn.pageID
        var onScratch = false
        if decision.overflow {
            // No room on their document page: onto the blank page after it.
            var scratch = turn.scratch ?? scratchPage(after: turn.pageID)
            decision = ActionValidator.validate(tool, input: input, context: &scratch.context)
            PageMapDebug.shared.logPlacement(tool, decision.notes, result: decision.result)
            guard !decision.isError else { turn.scratch = scratch; return (decision.result, true) }
            if let page = scratch.pending {
                content.pages.insert(page, at: min(scratch.index, content.pages.count))
                scratch.pending = nil
                scratch.added = true
            }
            turn.scratch = scratch
            pageID = scratch.pageID
            onScratch = true
            decision.result += ". There was no room on their page, so it's on the blank page after it "
                + "(page \((index(of: pageID) ?? 0) + 1)); keep anything else that doesn't fit there too"
            // Turn to it, so they see it being written.
            if currentPageID != pageID {
                returnCursor()
                withAnimation(.snappy) { currentPageID = pageID }
                try await Task.sleep(for: .seconds(0.6))
            }
        }
        guard !decision.isError else { return (decision.result, true) }
        guard let i = index(of: pageID) else { return ("The page isn't there any more.", true) }
        func touched() { if onScratch { turn.scratch?.changed = true } else { turn.changed = true } }
        if decision.growPage > 0 {
            withAnimation(.smooth) { content.pages[i].height += decision.growPage }
            touched()
        }
        if !decision.erase.isEmpty {
            withAnimation(.easeOut(duration: 0.25)) { content.pages[i].agentMarks.removeAll { decision.erase.contains($0.id) } }
            touched()
        }
        for mark in decision.marks {
            // The cursor flies to where the mark starts (out of the pill, the first time), then draws it.
            if let start = mark.startPoint { try await flyCursor(to: .page(start), on: pageID) }
            guard let i = index(of: pageID) else { break }
            content.pages[i].agentMarks.append(mark)
            touched()
            turn.drawn += 1
            liveMark = LiveMark(pageID: pageID, markID: mark.id, start: .now, duration: mark.duration)
            try await Task.sleep(for: .seconds(mark.duration + 0.12))
            if let end = mark.endPoint, let trip = agentCursor?.trip {
                agentCursor = .resting(at: .page(end), on: pageID, trip: trip)
            }
            liveMark = nil
        }
        changed()
        return (decision.result, false)
    }

    /// The page after `pageID` if it's blank paper with nothing of theirs on it, or a new blank page there.
    private func scratchPage(after pageID: UUID) -> ScratchPage {
        let at = (index(of: pageID) ?? content.pages.count - 1) + 1
        let existing = content.pages.indices.contains(at) ? content.pages[at] : nil
        let reuse = existing.flatMap { $0.pdfPage == nil && $0.drawing.strokes.isEmpty && $0.images.isEmpty && $0.cards.isEmpty ? $0 : nil }
        let page = reuse ?? NotePage(height: screenPageHeight)
        var context = ActionValidator.ToolContext(snapshot: PageMapSnapshot(pageID: page.id, pageSize: page.bounds.size),
                                                  marks: page.agentMarks)
        context.placed = page.agentMarks.map(\.bounds)
        context.scratch = true
        context.chrome = chromeOnBlankPage(height: page.height)
        return ScratchPage(pageID: page.id, context: context, before: (page.agentMarks, page.height),
                           pending: reuse == nil ? page : nil, index: at)
    }

    /// Where the controls will cover a blank page when it's on screen (it fills the screen from the top).
    private func chromeOnBlankPage(height: CGFloat) -> [CGRect] {
        guard frames.screen.width > 0 else { return [] }
        let k = frames.screen.width / NotePageMetrics.width
        var out: [CGRect] = []
        if let top = deskTop { out.append(CGRect(x: 0, y: 0, width: NotePageMetrics.width, height: top / k)) }
        if let bottom = deskBottom {
            out.append(CGRect(x: 0, y: bottom / k, width: NotePageMetrics.width, height: max(0, height - bottom / k)))
        }
        return out.filter { !$0.isEmpty }
    }

    /// Moves the agent's cursor to `spot`, out of the pill if it isn't out yet, and waits for it to get there.
    private func flyCursor(to spot: AgentCursor.Spot, on pageID: UUID) async throws {
        let from: AgentCursor.Spot = agentCursor.flatMap { $0.pageID == pageID && $0.to != .pill ? $0.to : nil } ?? .pill
        let duration = AgentCursor.flight(from: from, to: spot)
        agentCursor = AgentCursor(trip: agentCursor?.trip ?? UUID(), pageID: pageID, from: from, to: spot, start: .now,
                                  duration: duration)
        try await Task.sleep(for: .seconds(duration))
    }

    /// Sends the cursor back into the pill, where it disappears.
    private func returnCursor() {
        guard let cursor = agentCursor, cursor.to != .pill else { return }
        let duration = AgentCursor.flight(from: cursor.to, to: .pill)
        agentCursor = AgentCursor(trip: cursor.trip, pageID: cursor.pageID, from: cursor.to, to: .pill, start: .now,
                                  duration: duration)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            guard let self, self.agentCursor?.trip == cursor.trip, self.agentCursor?.to == .pill else { return }
            self.agentCursor = nil
        }
    }

    /// Where the floating controls (and the agent's cards) cover the page right now, in page points.
    private func chromeOnPage(_ pageID: UUID, height: CGFloat) -> [CGRect] {
        var screen = Array(frames.floating.values)
        // The top and bottom controls, edge to edge: nothing goes between the buttons either.
        if let top = deskTop { screen.append(CGRect(x: -10_000, y: top - 160, width: 20_000, height: 160)) }
        if let bottom = deskBottom { screen.append(CGRect(x: -10_000, y: bottom, width: 20_000, height: 160)) }
        let page = CGRect(x: 0, y: 0, width: NotePageMetrics.width, height: height)
        return screen.compactMap { frames.toPage($0, on: pageID)?.intersection(page) }.filter { !$0.isNull && !$0.isEmpty }
    }

    /// Ends a turn that drew: one undo step for everything it drew, and what the person draws next counts as new.
    private func finish(_ turn: DrawingTurn) {
        pageMapper.markTurn(pageID: turn.pageID)
        let scratch = turn.scratch.flatMap { $0.changed ? $0 : nil }
        guard turn.changed || scratch != nil else { return }
        undoManager.beginUndoGrouping()
        if turn.changed, let page = page(turn.pageID) {
            registerMarksUndo(pageID: turn.pageID, restoring: turn.before, current: (page.agentMarks, page.height))
            log("Drew on page \((index(of: turn.pageID) ?? 0) + 1)", by: .agent)
        }
        if let scratch, let i = index(of: scratch.pageID) {
            pageMapper.markTurn(pageID: scratch.pageID)
            let page = content.pages[i]
            if scratch.added {
                // A page it added: undo takes the whole page away again.
                registerPageAddedUndo(page, at: i)
            } else {
                registerMarksUndo(pageID: scratch.pageID, restoring: scratch.before, current: (page.agentMarks, page.height))
            }
            log("Drew on page \(i + 1)", by: .agent)
        }
        undoManager.endUndoGrouping()
        changed()
    }

    /// Undo removes `page` (added at `index`); redo puts it back as it was.
    private func registerPageAddedUndo(_ page: NotePage, at index: Int) {
        undoManager.registerUndo(withTarget: self) { model in
            guard let i = model.index(of: page.id) else { return }
            let current = model.content.pages[i]
            model.content.pages.remove(at: i)
            model.fixCurrentPage()
            model.registerPageRemovedUndo(current, at: i)
            model.changed()
        }
        undoManager.setActionName("Agent's Marks")
    }

    private func registerPageRemovedUndo(_ page: NotePage, at index: Int) {
        undoManager.registerUndo(withTarget: self) { model in
            model.content.pages.insert(page, at: min(index, model.content.pages.count))
            model.registerPageAddedUndo(page, at: index)
            model.changed()
        }
        undoManager.setActionName("Agent's Marks")
    }

    // MARK: Erasing the agent's marks

    /// The page being erased, and its marks before, for one undo step per stroke of the eraser.
    @ObservationIgnored private var erasing: (pageID: UUID, before: (marks: [AgentMark], height: CGFloat))?

    func beginErasingAgentMarks(on pageID: UUID) {
        guard let page = page(pageID) else { return }
        erasing = (pageID, (page.agentMarks, page.height))
    }

    /// Erases what the eraser touches between `a` and `b` (page points).
    func eraseAgentMarks(on pageID: UUID, from a: CGPoint, to b: CGPoint, radius: CGFloat, pixel: Bool) {
        guard let i = index(of: pageID), !content.pages[i].agentMarks.isEmpty else { return }
        let sweep = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .insetBy(dx: -radius - 4, dy: -radius - 4)
        var marks = content.pages[i].agentMarks
        var erased = false
        for m in marks.indices.reversed() where marks[m].bounds.intersects(sweep) {
            let items = marks[m].items.flatMap { AgentEraser.erase($0, from: a, to: b, radius: radius, pixel: pixel) }
            guard items != marks[m].items else { continue }
            erased = true
            if items.isEmpty {
                if liveMark?.markID == marks[m].id { liveMark = nil }
                marks.remove(at: m)
            } else {
                marks[m].items = items
            }
        }
        if erased { content.pages[i].agentMarks = marks }
    }

    func endErasingAgentMarks() {
        guard let erasing else { return }
        self.erasing = nil
        guard let page = page(erasing.pageID), page.agentMarks != erasing.before.marks else { return }
        undoManager.beginUndoGrouping()
        registerMarksUndo(pageID: erasing.pageID, restoring: erasing.before, current: (page.agentMarks, page.height))
        undoManager.setActionName("Erase")
        undoManager.endUndoGrouping()
        changed()
    }

    /// Undo puts the page's marks (and its height, if the agent added room) back as they were; redo, the other way.
    private func registerMarksUndo(pageID: UUID, restoring old: (marks: [AgentMark], height: CGFloat),
                                   current: (marks: [AgentMark], height: CGFloat)) {
        undoManager.registerUndo(withTarget: self) { model in
            guard let i = model.index(of: pageID) else { return }
            let now = (model.content.pages[i].agentMarks, model.content.pages[i].height)
            model.content.pages[i].agentMarks = old.marks
            model.content.pages[i].height = old.height
            model.registerMarksUndo(pageID: pageID, restoring: now, current: old)
            model.changed()
        }
        undoManager.setActionName("Agent's Marks")
    }

    /// Adds the page's picture and map to the last thing the person said.
    private static func attach(_ snapshot: PageMapSnapshot, page: Int, of count: Int, to messages: inout [JSONValue]) {
        guard let last = messages.indices.last, messages[last]["role"] == "user", let said = messages[last]["content"]?.string
        else { return }
        var blocks: [JSONValue] = []
        if !snapshot.image.isEmpty {
            blocks.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                       "data": .string(snapshot.image.base64EncodedString())]])
        }
        blocks.append(["type": "text", "text": .string("The page on screen (page \(page) of \(count)) and its map:\n"
                                                        + PageMapText.block(snapshot))])
        blocks.append(["type": "text", "text": .string(said)])
        messages[last]["content"] = .array(blocks)
    }

    /// Adds what was lassoed (what to do with it, and a close-up) just before the person's words.
    private static func attach(_ instructions: String, closeUp: Data?, to messages: inout [JSONValue]) {
        guard let last = messages.indices.last, messages[last]["role"] == "user" else { return }
        var blocks: [JSONValue]
        switch messages[last]["content"] {
        case .array(let existing)?: blocks = existing
        case .string(let said)?: blocks = [["type": "text", "text": .string(said)]]
        default: return
        }
        var added: [JSONValue] = [["type": "text", "text": .string(instructions)]]
        if let closeUp {
            added.append(["type": "image", "source": ["type": "base64", "media_type": "image/jpeg",
                                                      "data": .string(closeUp.base64EncodedString())]])
        }
        blocks.insert(contentsOf: added, at: max(0, blocks.count - 1))
        messages[last]["content"] = .array(blocks)
    }

    /// Puts the reply in the agent bar away. It stays in History.
    func dismissReply() {
        reply = nil
    }

    /// Reads the reply in the reply bar aloud. It moves into the agent bar, streaming in time with the voice.
    func readReplyAloud() {
        guard let text = textReply?.text, keysReady() else { return }
        reply = nil
        run { model in try await model.speak(text) }
    }

    /// The person went back to the page (tapped it, or started writing or erasing): the exchange with the agent
    /// closes. The text answer goes, and the field folds away with it. A follow-up already being typed is kept: the
    /// field stays with it, and only the keyboard goes down.
    func moveOn() {
        guard agent == .idle else { return }
        if textReply != nil { reply = nil }
        guard showsKeyboard else { return }
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showsKeyboard = false
        } else {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }

    /// The keyboard button: opens the field, or closes it along with the answer under it.
    func toggleKeyboard() {
        if showsKeyboard {
            showsKeyboard = false
            if textReply != nil { reply = nil }
        } else {
            showsKeyboard = true
        }
    }

    private func speak(_ text: String) async throws {
        guard let voiceKey = ElevenLabsClient() else { return }
        agent = .thinking
        let speech = try await voiceKey.speak(text)
        try Task.checkCancellation()
        agent = .speaking
        // The words stream through the bar as they're said, from the moment the audio starts.
        try await voice.play(speech.audio, started: {
            reply = AgentReply(text: text, wordStarts: speech.wordStarts)
        }, level: { [weak self] in self?.level = Self.loudness($0) })
        level = 0
    }

    /// Adds what the person said or typed to the conversation.
    private func say(_ text: String, spoken: Bool) {
        content.conversation.append(ConversationTurn(speaker: .you, text: text, spoken: spoken))
        changed()
    }

    /// The recent conversation as Messages API turns, with neighbouring turns by the same speaker joined, starting
    /// with the person.
    private static func messages(for conversation: [ConversationTurn]) -> [ClaudeClient.Message] {
        var messages: [ClaudeClient.Message] = []
        for turn in conversation.suffix(40) {
            let role: ClaudeClient.Message.Role = turn.speaker == .you ? .user : .assistant
            if let last = messages.last, last.role == role {
                messages[messages.count - 1] = .init(role: role, content: last.content + "\n\n" + turn.text)
            } else if !(messages.isEmpty && role == .assistant) {
                messages.append(.init(role: role, content: turn.text))
            }
        }
        return messages
    }

    private static func agentPrompt(title: String, visualizations: [String], canDraw: Bool) -> String {
        let note = title.isEmpty ? "a note" : "the note “\(title)”"
        let open = visualizations.isEmpty ? ""
            : "\n\nVisualizations already open, oldest first: " + visualizations.map { "“\($0)”" }.joined(separator: ", ") + "."
        let page = canDraw ? "\n\n" + AgentTools.guidance : ""
        return """
        You are the agent inside Scribe, an iPad notebook. The person is working in \(note) and talking to you, \
        usually out loud: their words reach you through speech recognition, so read past small transcription \
        mistakes. Your replies may be read aloud by a text-to-speech voice, so write plain conversational \
        sentences: no markdown, lists, headings, code, emoji or links. Be brief, usually one to three sentences, \
        unless they ask for more. Write nothing before or between tool calls: do all your tool calls first, then \
        write your reply once, at the very end. Only that last message is shown and read aloud. Say each thing \
        once.\(page)

        You can also show things off the page. When they ask to see, visualize, show, model or simulate something, or a picture \
        or 3D model would explain it far better than words, call \(VisualizationTool.name): it opens as a card in the top \
        right, over their page. Make it something to play with, with controls for what matters, not just a picture. \
        Make it, then tell them in one short sentence what to try. Never \
        describe the code or read the page out.\(open)
        """
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
}

extension UIImage {
    /// The same picture with its orientation applied, so drawing it never depends on EXIF.
    func normalizedUp() -> UIImage {
        guard imageOrientation != .up else { return self }
        return UIGraphicsImageRenderer(size: size, format: imageRendererFormat).image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
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

/// A card that was just closed, and where it was in the stack.
struct ClosedVisualization: Identifiable {
    let id = UUID()
    let visualization: Visualization
    let index: Int
}
