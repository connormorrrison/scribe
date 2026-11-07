import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// An open note.
///
/// - Top: Back, the agent control, Undo / Redo, and Share / More (note-wide things). Banners (error, choice,
///   placing a photo) slide in below.
/// - Bottom: the page pill (everything about pages), the tools and colours, Add Image, and the type-to-agent toggle
///   (which opens a field in the agent bar).
///
/// Each cluster is a separate piece of Liquid Glass inside one container per edge (`ChromeGroup`).
/// - The pages sit under them, one screen each, edge to edge: the dots mean "you can write here". Swipe between
///   pages; swipe past the last one, or tap + by the page count, to add a page.
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
    @State private var exportFile: PDFFile?
    @State private var shareURL: URL?

    init(store: CanvasStore, document: CanvasDocument, onBack: @escaping () -> Void) {
        _model = State(initialValue: CanvasModel(store: store, document: document))
        self.onBack = onBack
    }

    private var background: PageBackground { model.background ?? defaultBackground }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                pages(size: geo.size)
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topEdge
                Spacer(minLength: 0)
                bottomEdge
            }
        }
        .background(Color.white.ignoresSafeArea())
        .animation(.snappy, value: model.banner)
        .animation(.snappy, value: model.placement != nil)
        .animation(.snappy, value: model.showsKeyboard)
        .sheet(isPresented: $showsHistory) { HistorySheet(entries: model.content.history) }
        .sheet(isPresented: $showsSettings) { SettingsSheet() }
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

    /// Pages side by side, one screen each. Swipe for the next; swipe past the last to add one.
    private func pages(size: CGSize) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(model.content.pages) { page in
                    ScrollView(.vertical) {
                        PageView(model: model, page: page, width: size.width, background: background,
                                 drawWithFinger: drawWithFinger)
                    }
                    // Only a page written in another orientation is taller than the screen, and only then scrolls.
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollIndicators(.hidden)
                    .frame(width: size.width, height: size.height)
                    .id(page.id)
                }

                NewPagePlaceholder(background: background, size: size)
                    .id(Self.newPageID)
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollIndicators(.hidden)
        .scrollPosition(id: pagePosition)
        // While a photo is being placed, a drag moves the photo.
        .scrollDisabled(model.placement != nil)
        .scrollDismissesKeyboard(.interactively)
        .onAppear { fitPages(size) }
        .onChange(of: size) { _, new in fitPages(new) }
        .onChange(of: model.content.pages.map(\.id)) { _, _ in fitPages(size) }
        .onChange(of: model.reloadToken) { _, _ in fitPages(size) }
    }

    /// Stands for the "new page" past the last page.
    private static let newPageID = UUID()

    /// The page on screen. Landing on the new-page placeholder adds a page there.
    private var pagePosition: Binding<UUID?> {
        Binding {
            model.currentPageID
        } set: { id in
            if id == Self.newPageID {
                model.currentPageID = model.addPage(after: model.content.pages.last?.id)
            } else if let id {
                model.currentPageID = id
            }
        }
    }

    private func addPageAfterCurrent() {
        let id = model.addPage(after: model.currentPageID)
        withAnimation(.snappy) { model.currentPageID = id }
    }

    private func fitPages(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        model.fitPages(toHeight: (size.height * NotePageMetrics.width / size.width).rounded(.up))
    }

    // MARK: Top edge

    private var topEdge: some View {
        VStack(spacing: 10) {
            ChromeGroup {
                HStack(alignment: .center, spacing: CanvasChromeMetrics.groupGap) {
                    ChromeButton(title: "Back", symbol: "chevron.backward", action: onBack)
                        .canvasChrome(Capsule())
                    Spacer()
                    HStack(spacing: 0) {
                        ChromeButton(title: "Undo", symbol: "arrow.uturn.backward", disabled: !model.canUndo) {
                            model.undo()
                        }
                        ChromeButton(title: "Redo", symbol: "arrow.uturn.forward", disabled: !model.canRedo) {
                            model.redo()
                        }
                    }
                    .padding(.horizontal, 4)
                    .canvasChrome(Capsule())

                    HStack(spacing: 0) {
                        ChromeButton(title: "Share", symbol: "square.and.arrow.up") { share() }
                        moreMenu
                    }
                    .padding(.horizontal, 4)
                    .canvasChrome(Capsule())
                }
                .overlay {
                    AgentControl(model: model) { showsSettings = true }
                }
            }

            banners
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
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

    /// Note-wide things. Page things live on the page pill; Add Image sits with the tools.
    private var moreMenu: some View {
        Menu {
            Button("History", systemImage: "clock.arrow.circlepath") { showsHistory = true }
            Button("Export as PDF", systemImage: "arrow.down.doc") {
                exportFile = PDFFile(data: NotePDF.data(for: model, background: background))
            }

            Section {
                Button("Clear the Agent's Marks", systemImage: "eraser.line.dashed", role: .destructive) {
                    model.clearAgentMarks()
                }
                .disabled(!model.hasAgentMarks)
                Button("Settings", systemImage: "gearshape") { showsSettings = true }
            }
        } label: {
            ChromeSymbol(symbol: "ellipsis")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("More")
    }

    /// Everything about pages, on the page pill (touch and hold) and in the Pages popover.
    @ViewBuilder
    private var pageMenu: some View {
        Button("Add Page After", systemImage: "plus.rectangle.portrait") { addPageAfterCurrent() }
        Button("Duplicate Page", systemImage: "plus.rectangle.on.rectangle") {
            if let id = model.currentPageID, let copy = model.duplicatePage(id) {
                withAnimation(.snappy) { model.currentPageID = copy }
            }
        }
        Button("Delete Page", systemImage: "trash", role: .destructive) {
            if let id = model.currentPageID { model.deletePage(id) }
        }
        .disabled(model.content.pages.count <= 1)

        Section {
            Picker(selection: backgroundBinding) {
                ForEach(PageBackground.allCases) { Text($0.title).tag($0) }
            } label: {
                Label("Page Background", systemImage: "circle.grid.3x3")
            }
            .pickerStyle(.menu)
        }
    }

    private var backgroundBinding: Binding<PageBackground> {
        Binding(get: { background }, set: { model.setBackground($0) })
    }

    /// Next to the tools: putting a picture on the page is making something, like drawing.
    private var addImageMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { showsPhotos = true }
            Button("Files", systemImage: "folder") { showsFiles = true }
        } label: {
            ChromeSymbol(symbol: "photo.badge.plus")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .canvasChrome(Capsule())
        .accessibilityLabel("Add Image")
    }

    // MARK: Bottom edge

    private var bottomEdge: some View {
        ChromeGroup {
            HStack(alignment: .center, spacing: CanvasChromeMetrics.groupGap) {
                PagePill(current: model.currentPageIndex + 1, count: model.content.pages.count,
                         showPages: { showsPages = true }, addPage: addPageAfterCurrent)
                    .contextMenu { pageMenu }
                    .popover(isPresented: $showsPages, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
                        PagesPanel(model: model, background: background, setBackground: model.setBackground) { id in
                            showsPages = false
                            if let id { withAnimation(.snappy) { model.currentPageID = id } }
                        }
                        .presentationCompactAdaptation(.popover)
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .leading)

                ToolBar(palette: model.palette)
                addImageMenu

                ChromeButton(title: "Type to the Agent", symbol: "keyboard", selected: model.showsKeyboard) {
                    model.showsKeyboard.toggle()
                }
                .canvasChrome(Capsule())
                .frame(maxWidth: .infinity, alignment: .trailing)
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
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
