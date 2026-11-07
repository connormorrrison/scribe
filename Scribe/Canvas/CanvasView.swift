import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// An open note.
///
/// - Top: Back, the agent control, and Undo / Redo / More. Banners (error, choice, placing a photo) slide in below.
/// - Bottom: the page pill, the tool bar, and the type-to-agent toggle.
/// - The pages scroll between them, with an add-page button after the last.
struct CanvasView: View {
    @State private var model: CanvasModel
    let onBack: () -> Void

    @AppStorage(AppSettings.pageBackground) private var defaultBackground = PageBackground.dots
    @AppStorage(AppSettings.drawWithFinger) private var drawWithFinger = false

    @State private var showsPages = false
    @State private var showsHistory = false
    @State private var showsSettings = false
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var photoItem: PhotosPickerItem?
    @State private var colourTarget: ColourTarget?
    @State private var exportFile: PDFFile?
    @State private var shareURL: URL?
    @State private var message = ""
    @FocusState private var typing: Bool

    init(store: CanvasStore, document: CanvasDocument, onBack: @escaping () -> Void) {
        _model = State(initialValue: CanvasModel(store: store, document: document))
        self.onBack = onBack
    }

    private var background: PageBackground { model.background ?? defaultBackground }

    var body: some View {
        GeometryReader { geo in
            pages(width: min(geo.size.width - 48, 1180))
        }
        .background(Color(.secondarySystemBackground).ignoresSafeArea())
        .overlay(alignment: .top) { topEdge }
        .overlay(alignment: .bottom) { bottomEdge }
        .animation(.snappy, value: model.banner)
        .animation(.snappy, value: model.placement != nil)
        .animation(.snappy, value: model.showsKeyboard)
        .sheet(isPresented: $showsHistory) { HistorySheet(entries: model.content.history) }
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
        .sheet(item: $colourTarget) { target in
            ColourPickerSheet(initial: initialColour(for: target)) { colour in
                switch target {
                case .add: colourTarget = .edit(model.addSwatch(colour))
                case .edit(let i): model.setSwatch(i, to: colour)
                }
            }
        }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .fullScreenCover(item: $model.enlargedCard) { card in EnlargedCard(model: model, card: card) }
        .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                      document: exportFile, contentType: .pdf, defaultFilename: model.document.title) { _ in }
        .photosPicker(isPresented: $showsPhotos, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { model.beginPlacement(data) }
                photoItem = nil
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { model.beginPlacement(data) }
        }
        .onDisappear { model.saveNow() }
    }

    // MARK: Pages

    private func pages(width: CGFloat) -> some View {
        ScrollView {
            LazyVStack(spacing: 28) {
                ForEach(model.content.pages) { page in
                    PageView(model: model, page: page, width: width, background: background,
                             drawWithFinger: drawWithFinger)
                        .id(page.id)
                }

                Button("Add Page", systemImage: "plus") {
                    let id = model.addPage(after: model.content.pages.last?.id)
                    withAnimation(.snappy) { model.currentPageID = id }
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 56, height: 56)
                .contentShape(Circle())
                .buttonStyle(.plain)
                .canvasChrome(Circle())
            }
            .scrollTargetLayout()
            .frame(maxWidth: .infinity)
            .padding(.top, 84)
            .padding(.bottom, 140)
        }
        .scrollPosition(id: $model.currentPageID, anchor: .top)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Top edge

    private var topEdge: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                ChromeCircleButton(title: "Back", symbol: "chevron.left", action: onBack)
                Spacer()
                HStack(spacing: 0) {
                    ChromeIconButton(title: "Undo", symbol: "arrow.uturn.backward", disabled: !model.canUndo) {
                        model.undo()
                    }
                    ChromeIconButton(title: "Redo", symbol: "arrow.uturn.forward", disabled: !model.canRedo) {
                        model.redo()
                    }
                    moreMenu
                }
                .padding(.horizontal, 4)
                .canvasChrome(Capsule())
            }
            .overlay {
                AgentControl(state: model.agent) { model.toggleAgent() }
            }

            banners
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    @ViewBuilder
    private var banners: some View {
        if model.placement != nil {
            PlacementBanner(cancel: { model.cancelPlacement() }, place: { model.place() })
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if case .error(let text) = model.banner {
            ErrorBanner(message: text, openSettings: { showsSettings = true }, retry: { model.retry() })
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if case .choice(let prompt, let options) = model.banner {
            ChoiceBanner(prompt: prompt, options: options) { model.choose($0) }
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var moreMenu: some View {
        Menu {
            Button("History", systemImage: "clock.arrow.circlepath") { showsHistory = true }

            Section {
                Button("Export as PDF", systemImage: "arrow.down.doc") {
                    exportFile = PDFFile(data: NotePDF.data(for: model, background: background))
                }
                Button("Share", systemImage: "square.and.arrow.up") { share() }
            }

            Section {
                Picker(selection: Binding(get: { background }, set: { model.setBackground($0) })) {
                    ForEach(PageBackground.allCases) { Text($0.title).tag($0) }
                } label: {
                    Label("Page Background", systemImage: "circle.grid.3x3")
                }
                .pickerStyle(.menu)

                Menu {
                    Button("Add Page After", systemImage: "plus.rectangle.portrait") {
                        let id = model.addPage(after: model.currentPageID)
                        withAnimation(.snappy) { model.currentPageID = id }
                    }
                    Button("Duplicate Page", systemImage: "plus.rectangle.on.rectangle") {
                        if let id = model.currentPageID, let copy = model.duplicatePage(id) {
                            withAnimation(.snappy) { model.currentPageID = copy }
                        }
                    }
                    Button("Delete Page", systemImage: "trash", role: .destructive) {
                        if let id = model.currentPageID { model.deletePage(id) }
                    }
                    .disabled(model.content.pages.count <= 1)
                } label: {
                    Label("Page", systemImage: "doc")
                }

                Button("Add Space", systemImage: "arrow.up.and.down.text.horizontal") {
                    if let id = model.currentPageID { model.addSpace(to: id) }
                }

                Menu {
                    Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotos = true }
                    Button("Files", systemImage: "folder") { showsFiles = true }
                } label: {
                    Label("Add Image", systemImage: "photo.badge.plus")
                }
            }

            Section {
                Button("Clear the Agent's Marks", systemImage: "eraser.line.dashed", role: .destructive) {
                    model.clearAgentMarks()
                }
                .disabled(!model.hasAgentMarks)
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: CanvasChromeMetrics.iconSize, weight: .semibold))
                .frame(width: CanvasChromeMetrics.button, height: CanvasChromeMetrics.button)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    // MARK: Bottom edge

    private var bottomEdge: some View {
        VStack(spacing: 12) {
            if model.showsKeyboard {
                AgentTextField(text: $message, focused: $typing) {
                    model.send(message)
                    message = ""
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(alignment: .center) {
                PagePill(current: model.currentPageIndex + 1, count: model.content.pages.count) {
                    showsPages = true
                }
                .popover(isPresented: $showsPages, arrowEdge: .bottom) {
                    PagesPanel(model: model, background: background) { id in
                        showsPages = false
                        withAnimation(.snappy) { model.currentPageID = id }
                    }
                    .frame(minWidth: 420, idealWidth: 460, minHeight: 480, idealHeight: 560)
                }
                Spacer()
                ChromeCircleButton(title: model.showsKeyboard ? "Hide Keyboard" : "Type to the Agent",
                                   symbol: "keyboard", isOn: model.showsKeyboard) {
                    model.showsKeyboard.toggle()
                    typing = model.showsKeyboard
                }
            }
            .overlay {
                ToolBar(model: model) { colourTarget = $0 }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    // MARK: Actions

    private func share() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(model.document.title.isEmpty ? "Note" : model.document.title)
            .appendingPathExtension("pdf")
        try? NotePDF.data(for: model, background: background).write(to: url, options: .atomic)
        shareURL = url
    }

    private func initialColour(for target: ColourTarget) -> UIColor {
        if case .edit(let i) = target, model.swatches.indices.contains(i) { return UIColor(hex: model.swatches[i]) }
        return .systemPurple
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
