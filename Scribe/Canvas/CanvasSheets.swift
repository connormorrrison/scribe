import PencilKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pages panel

/// Every page: tap to go there, drag to reorder, touch and hold to add, duplicate or delete. The header holds the
/// page background. Each change is one
/// undo step.
struct PagesPanel: View {
    let model: CanvasModel
    let background: PageBackground
    let setBackground: (PageBackground) -> Void
    /// Closes the panel, going to the page if there is one.
    let jump: (UUID?) -> Void

    /// Pages in the order shown; changes live while a page is dragged and is saved when it's dropped.
    @State private var order: [UUID] = []
    @State private var dragging: UUID?
    @State private var confirmDelete: UUID?

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 16)]
    private static let tileHeight: CGFloat = 170

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Pages")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("\(model.content.pages.count)")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Page Background", selection: Binding(get: { background }, set: setBackground)) {
                    ForEach(PageBackground.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                ChromeButton(title: "Add a Page After This One", symbol: "plus") {
                    jump(model.addPage(after: model.currentPageID))
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(order.enumerated()), id: \.element) { position, id in
                        if let page = model.page(id) { tile(page, position: position) }
                    }
                    addTile
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.snappy(duration: 0.25), value: order)
            }
            .onDrop(of: [.text], delegate: PageDropCommit(commit: commitDrag))

            Text("Drag a page to move it. Touch and hold for more.")
                .font(.system(size: 13, weight: .regular, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.vertical, 10)
        }
        .padding(.top, 4)
        .frame(width: 460, height: 520)
        .onAppear(perform: reset)
        .onChange(of: model.content.pages.map(\.id)) { _, _ in reset() }
        .onDisappear(perform: commitDrag)
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { confirmDelete != nil },
                                                               set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete Page", role: .destructive) {
                if let id = confirmDelete { model.deletePage(id) }
                confirmDelete = nil
            }
        } message: {
            Text("You can undo this.")
        }
    }

    private var confirmTitle: String {
        guard let id = confirmDelete, let i = model.content.pages.firstIndex(where: { $0.id == id }) else { return "" }
        return "Delete page \(i + 1)?"
    }

    private func tile(_ page: NotePage, position: Int) -> some View {
        let current = page.id == model.currentPageID
        let index = model.content.pages.firstIndex { $0.id == page.id } ?? position
        return Button { jump(page.id) } label: {
            VStack(spacing: 6) {
                PageThumbnail(model: model, page: page, background: background)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(current ? Color.accentColor : .primary.opacity(0.15),
                                          lineWidth: current ? 2.5 : 0.5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: Self.tileHeight)
                    .frame(height: Self.tileHeight)
                Text("\(position + 1)")
                    .font(.system(size: 13, weight: current ? .semibold : .regular, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(current ? Color.accentColor : .secondary)
            }
            .contentShape(Rectangle())
            .opacity(dragging == page.id ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .onDrag {
            commitDrag()
            dragging = page.id
            return NSItemProvider(object: page.id.uuidString as NSString)
        }
        .onDrop(of: [.text], delegate: PageDropTarget(target: page.id, order: $order, dragging: $dragging,
                                                      commit: commitDrag))
        .contextMenu {
            Button("Add Page Before", systemImage: "plus.rectangle.portrait") {
                jump(model.addPage(at: index))
            }
            Button("Add Page After", systemImage: "plus.rectangle.portrait") { jump(model.addPage(after: page.id)) }
            Button("Duplicate", systemImage: "plus.rectangle.on.rectangle") { jump(model.duplicatePage(page.id)) }
            Divider()
            Button("Delete Page", systemImage: "trash", role: .destructive) { delete(page.id) }
                .disabled(model.content.pages.count <= 1)
        }
        .accessibilityLabel(current ? "Page \(position + 1), current page" : "Page \(position + 1)")
        .accessibilityAction(named: "Move Earlier") { if index > 0 { model.movePage(page.id, to: index - 1) } }
        .accessibilityAction(named: "Move Later") { model.movePage(page.id, to: index + 1) }
        .accessibilityAction(named: "Duplicate") { model.duplicatePage(page.id) }
        .accessibilityAction(named: "Delete") { delete(page.id) }
    }

    private var addTile: some View {
        Button {
            jump(model.addPage(after: model.content.pages.last?.id))
        } label: {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .aspectRatio(NotePageMetrics.width / model.screenPageHeight, contentMode: .fit)
                    .overlay(Image(systemName: "plus").font(.title2).foregroundStyle(.secondary))
                    .frame(height: Self.tileHeight)
                Text("New")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a Page at the End")
    }

    private func delete(_ id: UUID) {
        guard model.content.pages.count > 1 else { return }
        if model.pageHasContent(id) { confirmDelete = id } else { model.deletePage(id) }
    }

    private func reset() {
        order = model.content.pages.map(\.id)
    }

    /// The dragged page ends where it's shown: one move, one undo step.
    private func commitDrag() {
        guard let id = dragging else { return }
        dragging = nil
        guard let to = order.firstIndex(of: id) else { return }
        model.movePage(id, to: to)
    }
}

/// Live reordering: entering another page's tile moves the dragged page there.
private struct PageDropTarget: DropDelegate {
    let target: UUID
    @Binding var order: [UUID]
    @Binding var dragging: UUID?
    let commit: () -> Void

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = order.firstIndex(of: d), let to = order.firstIndex(of: target) else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }
}

/// A drop between tiles still saves the new order.
private struct PageDropCommit: DropDelegate {
    let commit: () -> Void

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        commit()
        return true
    }
}

/// A small picture of a page, with everything on it (`PageSnapshot`).
struct PageThumbnail: View {
    let model: CanvasModel
    let page: NotePage
    let background: PageBackground
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        Color.white
            .overlay {
                if let image { Image(uiImage: image).resizable().interpolation(.high) }
            }
            .aspectRatio(NotePageMetrics.width / page.height, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            .task(id: Snapshot(page: page, background: background)) {
                image = PageRenderer.image(of: page, background: background, pixelWidth: 200 * displayScale,
                                           pdf: model.pdfURL) {
                    model.image(named: $0)
                }
            }
    }

    private struct Snapshot: Equatable {
        let page: NotePage
        let background: PageBackground
    }
}

// MARK: - Conversation

/// History, in a popover from the History button: the conversation, with each step the agent took (writing on the
/// page, making a visualization) between the question and the answer. Oldest at the top, newest at the bottom.
struct HistoryPopover: View {
    let model: CanvasModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("History")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)
            ConversationPanel(model: model, close: close)
        }
        .frame(width: 380, height: 540)
    }
}

/// One thing in History: a message, or a step the agent took.
enum HistoryItem: Identifiable {
    case turn(ConversationTurn)
    case step(HistoryEntry)

    var id: UUID {
        switch self {
        case .turn(let turn): turn.id
        case .step(let step): step.id
        }
    }

    var date: Date {
        switch self {
        case .turn(let turn): turn.date
        case .step(let step): step.date
        }
    }

    /// The conversation and the agent's steps, in the order they happened. The person's own edits (pages added,
    /// backgrounds changed) are left out: History is the exchange with the agent.
    static func timeline(_ content: NoteContent) -> [HistoryItem] {
        let items = content.conversation.map(HistoryItem.turn)
            + content.history.filter { $0.author == .agent }.map(HistoryItem.step)
        // Stable: things logged in the same instant keep the order they were added in.
        return items.enumerated().sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }.map(\.element)
    }
}

/// The conversation with the agent: what you said on the right, the agent's replies on the left with its steps
/// above them, newest at the bottom.
struct ConversationPanel: View {
    let model: CanvasModel
    let close: () -> Void
    @AppStorage(AppSettings.pageBackground) private var defaultBackground = PageBackground.dots

    private var items: [HistoryItem] { HistoryItem.timeline(model.content) }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty && model.agent == .idle {
                ContentUnavailableView("No Conversation Yet", systemImage: "waveform",
                                       description: Text("Tap the blue dot and talk, or write ? beside anything you're stuck on. What you ask, what the agent does on your page, and what it says back show up here."))
                    .frame(maxHeight: .infinity)
            } else {
                messages
            }
        }
        .padding(.top, 8)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        switch item {
                        case .turn(let turn):
                            ConversationBubble(turn: turn, replay: { model.replay(turn) })
                                .id(turn.id)
                        case .step(let step):
                            AgentStepRow(step: step, opens: opens(step), preview: preview(of: step)) {
                                model.show(step)
                                close()
                            }
                            .id(step.id)
                        }
                    }
                    if model.agent != .idle {
                        AgentStatusBubble(state: model.agent)
                            .id(Self.statusID)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
                .animation(.snappy, value: items.count)
                .animation(.easeInOut(duration: 0.2), value: model.agent)
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.bottom)
            .onChange(of: items.count) { _, _ in scrollToEnd(proxy) }
            .onChange(of: model.agent) { _, _ in scrollToEnd(proxy) }
        }
    }

    /// A small picture of what the step made: the marks it drew on the page, or the visualization.
    private func preview(of step: HistoryEntry) -> AgentStepPreview? {
        if let id = step.visualizationID {
            return model.visualizationPreview(id).map(AgentStepPreview.card)
        }
        return model.stepPreview(step, background: defaultBackground).map(AgentStepPreview.page)
    }

    /// The step has somewhere to go: its page, or its visualization, still in the note.
    private func opens(_ step: HistoryEntry) -> Bool {
        if let id = step.pageID, model.page(id) != nil { return true }
        if let id = step.visualizationID { return model.content.visualizations.contains { $0.id == id } }
        return false
    }

    private static let statusID = "status"

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        withAnimation(.snappy) {
            if model.agent != .idle {
                proxy.scrollTo(Self.statusID, anchor: .bottom)
            } else if let last = items.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

/// A step the agent took, on the agent's side: a small symbol and a line of secondary text, with a small picture of
/// what it drew or made under it. Tap it to see it on the page (or the visualization it made).
private struct AgentStepRow: View {
    let step: HistoryEntry
    let opens: Bool
    let preview: AgentStepPreview?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: step.symbol ?? "pencil.and.scribble")
                        .foregroundStyle(Landing.blue)
                        .frame(width: 20)
                    Text(step.text)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                    if opens {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let preview {
                    AgentStepPreviewView(preview: preview)
                        .padding(.leading, 28)
                        .padding(.bottom, 4)
                }
            }
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .allowsHitTesting(opens)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Agent \(step.text.prefix(1).lowercased() + step.text.dropFirst())")
        .accessibilityHint(opens ? (step.visualizationID != nil ? "Double-tap to show it" : "Double-tap to go to the page") : "")
    }
}

/// What a step's picture shows.
enum AgentStepPreview {
    /// The part of the page around the marks it drew.
    case page(UIImage)
    /// The visualization, as it looked just after it started.
    case card(UIImage)
}

/// A step's picture in History: a piece of the page on paper, or a small dark card like the visualization's own.
private struct AgentStepPreviewView: View {
    let preview: AgentStepPreview

    private static let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

    var body: some View {
        switch preview {
        case .page(let image):
            picture(image, fitting: CanvasModel.previewSize)
                .overlay(Self.shape.strokeBorder(Color(.separator), lineWidth: 0.5))
        case .card(let image):
            picture(image, fitting: CGSize(width: CanvasModel.previewSize.width, height: 180))
                .background(Landing.card, in: Self.shape)
        }
    }

    /// The image at its own shape, as large as fits in `box`, with rounded corners.
    private func picture(_ image: UIImage, fitting box: CGSize) -> some View {
        let size = image.size
        let k = size.width > 0 && size.height > 0 ? min(box.width / size.width, box.height / size.height) : 0
        return Image(uiImage: image)
            .resizable()
            .frame(width: size.width * k, height: size.height * k)
            .clipShape(Self.shape)
            .accessibilityHidden(true)
    }
}

/// One message. Yours is blue on the right; the agent's is gray on the left.
private struct ConversationBubble: View {
    let turn: ConversationTurn
    let replay: () -> Void

    private var mine: Bool { turn.speaker == .you }

    var body: some View {
        VStack(alignment: mine ? .trailing : .leading, spacing: 4) {
            Text(turn.text)
                .font(.system(size: 16, weight: .regular, design: .rounded))
                .foregroundStyle(mine ? Color.white : Color.primary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(mine ? Landing.blue : Color(.secondarySystemFill),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.text }
                    if !mine { Button("Play Again", systemImage: "speaker.wave.2", action: replay) }
                }

            HStack(spacing: 4) {
                if turn.spoken { Image(systemName: mine ? "mic.fill" : "speaker.wave.2.fill") }
                Text(turn.date, format: .dateTime.hour().minute())
            }
            .font(.system(size: 12, weight: .regular, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: 300, alignment: mine ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(mine ? "You" : "Agent"): \(turn.text)")
    }
}

/// What the agent is doing right now, at the end of the conversation.
private struct AgentStatusBubble: View {
    let state: AgentState

    var body: some View {
        let mine = state == .listening
        HStack(spacing: 8) {
            Image(systemName: mine ? "mic.fill" : (state == .speaking ? "speaker.wave.2.fill" : "ellipsis"))
                .symbolEffect(.variableColor.iterative, isActive: true)
            Text(state == .listening ? "Listening…" : state == .speaking ? "Speaking…" : "Thinking…")
        }
        .font(.system(size: 15, weight: .regular, design: .rounded))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

// MARK: - Colour picker

/// The system colour picker; every pick is applied straight away.
struct ColourPickerSheet: UIViewControllerRepresentable {
    let initial: UIColor
    let picked: (UIColor) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.selectedColor = initial
        picker.supportsAlpha = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: ColourPickerSheet
        init(parent: ColourPickerSheet) { self.parent = parent }

        func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor,
                                       continuously: Bool) {
            guard !continuously else { return }
            parent.picked(color)
        }

        func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Share

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Enlarged card

struct EnlargedCard: View {
    let model: CanvasModel
    let card: AgentCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 64, (geo.size.height - 64) * card.frame.width / card.frame.height)
            let size = CGSize(width: side, height: side * card.frame.height / card.frame.width)
            CardFace(card: card, clock: model.clock(for: card.id), artScale: size.width / card.designWidth) {
                Button("Close", systemImage: "arrow.down.right.and.arrow.up.left") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.14), in: Circle())
                    .buttonStyle(.plain)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                if card.isAnimated {
                    let playing = model.clock(for: card.id)?.isPlaying ?? false
                    HStack(spacing: 8) {
                        Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                            model.togglePlay(card.id)
                        }
                        Button("Stop", systemImage: "stop.fill") { model.stopAnimation(card.id) }
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black.opacity(0.85).ignoresSafeArea())
    }
}

// MARK: - PDF

struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Renders a note as a PDF, one PDF page per note page.
@MainActor
enum NotePDF {
    static func data(for model: CanvasModel, background: PageBackground) -> Data {
        let first = model.content.pages.first?.bounds ?? CGRect(x: 0, y: 0, width: NotePageMetrics.width,
                                                                height: NotePageMetrics.height)
        let renderer = UIGraphicsPDFRenderer(bounds: first)
        return renderer.pdfData { context in
            for page in model.content.pages {
                let rect = page.bounds
                context.beginPage(withBounds: rect, pageInfo: [:])
                UIColor.white.setFill()
                UIRectFill(rect)

                if let index = page.pdfPage, let url = model.pdfURL {
                    // The PDF page itself, as vectors, so text stays sharp.
                    PDFPages.draw(url: url, page: index, in: rect, context: context.cgContext)
                } else {
                    let paper = ImageRenderer(content:
                        PageBackgroundView(style: background, regions: [rect],
                                           spacing: NotePageMetrics.backgroundSpacing)
                            .frame(width: rect.width, height: rect.height))
                    paper.scale = 2
                    paper.uiImage?.draw(in: rect)
                }

                for placed in page.images {
                    guard let image = model.image(named: placed.fileName) else { continue }
                    let cg = context.cgContext
                    cg.saveGState()
                    cg.translateBy(x: placed.frame.midX, y: placed.frame.midY)
                    cg.rotate(by: placed.rotation)
                    image.draw(in: CGRect(x: -placed.frame.width / 2, y: -placed.frame.height / 2,
                                          width: placed.frame.width, height: placed.frame.height))
                    cg.restoreGState()
                }
                lightImage(page.agentDrawing, bounds: rect, scale: 2).draw(in: rect)
                if !page.agentMarks.isEmpty {
                    let marks = ImageRenderer(content: AgentMarksLayer(marks: page.agentMarks)
                        .frame(width: rect.width, height: rect.height))
                    marks.scale = 2
                    marks.uiImage?.draw(in: rect)
                }
                lightImage(page.drawing, bounds: rect, scale: 2).draw(in: rect)

                for card in page.cards {
                    let face = ImageRenderer(content:
                        CardFace(card: card, clock: model.clock(for: card.id), artScale: card.frame.width / card.designWidth)
                            .frame(width: card.frame.width, height: card.frame.height))
                    face.scale = 2
                    face.uiImage?.draw(in: card.frame)
                }
            }
        }
    }
}
