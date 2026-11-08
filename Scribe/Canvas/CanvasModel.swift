import PencilKit
import SwiftUI

/// What the agent is doing, shown by the agent control.
enum AgentState: Equatable {
    case idle, listening, thinking, speaking
}

/// The agent's answer, streaming through the agent bar a word at a time. Each one is new, so the bar starts over.
struct AgentReply: Identifiable, Equatable {
    let id = UUID()
    let text: String
    /// When each word is said, in seconds from when the reply appears, if it's being spoken. Otherwise the words
    /// come at reading pace.
    var wordStarts: [TimeInterval]?

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

    var currentPageIndex: Int {
        content.pages.firstIndex { $0.id == currentPageID } ?? 0
    }

    func page(_ id: UUID) -> NotePage? { content.pages.first { $0.id == id } }

    // MARK: Tools

    let palette = ToolPalette()

    // MARK: Agent and banners

    var agent = AgentState.idle
    /// The agent's answer, streaming through the agent bar.
    var reply: AgentReply?
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
        }
        self.pdfURL = pdfURL
        self.file = file
        self.content = content
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
            model.content = restored
            model.reloadToken += 1
            model.registerUndo(name, restoring: current)
            model.fixCurrentPage()
            if let selection = model.selectedImage, model.placedImage(selection) == nil { model.selectedImage = nil }
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
        return !page.drawing.strokes.isEmpty || !page.agentDrawing.strokes.isEmpty || !page.images.isEmpty
            || !page.cards.isEmpty
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

    /// A finger tap on a page: selects the topmost image under it, or clears the selection.
    func tapPage(_ pageID: UUID, at point: CGPoint) {
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

    // MARK: Agent

    /// One line for the agent bar while the agent listens or works.
    var agentLine: String {
        switch agent {
        case .idle: ""
        case .listening: "Listening…"
        case .thinking: "Thinking…"
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
            listen()
        case .listening:
            voice.finish()
        case .thinking, .speaking:
            stopAgent()
        }
    }

    /// Sends what was typed to the agent. It answers in text, without speaking.
    func send(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, keysReady(voice: false) else { return }
        showsKeyboard = false
        reply = nil
        banner = nil
        say(text, spoken: false)
        run { model in try await model.reply(speak: false) }
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
    private func listen() {
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
            model.say(said, spoken: true)
            try await model.reply(speak: true)
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

    /// Asks Claude to answer the conversation so far, adds the answer, and speaks it if asked.
    private func reply(speak: Bool) async throws {
        guard let claude = ClaudeClient() else { return }
        agent = .thinking
        // Thinking counts toward max_tokens, so leave room for it on top of a short spoken answer.
        let reply = try await claude.send(Self.messages(for: content.conversation),
                                          system: Self.agentPrompt(title: document.title),
                                          maxTokens: 4096, effort: .low)
        try Task.checkCancellation()
        let answer = try reply.answer()
        content.conversation.append(ConversationTurn(speaker: .agent, text: answer, spoken: speak))
        changed()
        if speak {
            try await self.speak(answer)
        } else {
            self.reply = AgentReply(text: answer)
        }
    }

    /// Puts the reply in the agent bar away. It stays in History.
    func dismissReply() {
        reply = nil
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

    private static func agentPrompt(title: String) -> String {
        let note = title.isEmpty ? "a note" : "the note “\(title)”"
        return """
        You are the agent inside Scribe, an iPad notebook. The person is working in \(note) and talking to you, \
        usually out loud: their words reach you through speech recognition, so read past small transcription \
        mistakes. Your replies may be read aloud by a text-to-speech voice, so write plain conversational \
        sentences: no markdown, lists, headings, code, emoji or links. Be brief, usually one to three sentences, \
        unless they ask for more. You can't see or change their pages yet, so don't claim to.
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
