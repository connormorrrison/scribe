import SwiftUI
import PDFKit
import UniformTypeIdentifiers

// MARK: - Routes, selection, prompts

/// Pushed onto a library screen's navigation stack.
enum LibraryRoute: Hashable {
    case note(UUID)
    case folder(UUID)
}

/// Multi-select state for a library grid.
struct LibrarySelection {
    private(set) var isActive = false
    private(set) var folders: Set<UUID> = []
    private(set) var notes: Set<UUID> = []

    var count: Int { folders.count + notes.count }

    mutating func begin() { isActive = true }

    mutating func end() {
        isActive = false
        folders = []
        notes = []
    }

    mutating func toggle(folder id: UUID) {
        if folders.remove(id) == nil { folders.insert(id) }
    }

    mutating func toggle(note id: UUID) {
        if notes.remove(id) == nil { notes.insert(id) }
    }
}

/// A question the library asks: a name to type, or PDFs to pick.
enum LibraryPrompt: Identifiable, Equatable {
    case newNote(folderID: UUID?)
    case newFolder
    case importPDF(folderID: UUID?)
    case renameNote(UUID)
    case renameFolder(UUID)

    var id: String {
        switch self {
        case .newNote(let folder): "newNote-\(folder?.uuidString ?? "")"
        case .newFolder: "newFolder"
        case .importPDF(let folder): "importPDF-\(folder?.uuidString ?? "")"
        case .renameNote(let id): "renameNote-\(id)"
        case .renameFolder(let id): "renameFolder-\(id)"
        }
    }

    var asksForName: Bool {
        if case .importPDF = self { return false }
        return true
    }
}

// MARK: - Grid and tiles

enum LibraryMetrics {
    static let tileWidth: CGFloat = 200
    /// Landscape US Letter proportions.
    static let thumbnailHeight: CGFloat = tileWidth * 8.5 / 11
    static let spacing: CGFloat = 28
}

/// The adaptive tile grid every library screen uses.
struct LibraryGrid<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: LibraryMetrics.tileWidth),
                                     spacing: LibraryMetrics.spacing, alignment: .topLeading)],
                  spacing: LibraryMetrics.spacing + 4) {
            content
        }
        .padding(.horizontal, LibraryMetrics.spacing)
        .padding(.vertical, 20)
    }
}

/// A note or PDF: a page thumbnail with its title and a caption underneath.
struct DocumentTile: View {
    let document: CanvasDocument
    var caption: String? = nil
    @Environment(CanvasStore.self) private var store: CanvasStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if document.kind == .pdf, let url = store?.fileURL(for: document) {
                    PDFThumbnail(url: url)
                } else {
                    NotePaper()
                }
            }
            .frame(width: LibraryMetrics.tileWidth, height: LibraryMetrics.thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.black.opacity(0.08))
            }
            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(document.title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(caption ?? document.modifiedAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: LibraryMetrics.tileWidth, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A folder: a tinted folder in the same box as a page thumbnail, with its name and note count.
struct FolderTile: View {
    let folder: CanvasFolder
    let documents: [CanvasDocument]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.08))
                .overlay {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.accentColor.gradient)
                }
                .frame(width: LibraryMetrics.tileWidth, height: LibraryMetrics.thumbnailHeight)

            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Text(documents.count == 1 ? "1 item" : "\(documents.count) items")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: LibraryMetrics.tileWidth, alignment: .leading)
        .contentShape(Rectangle())
    }
}

/// A blank page in the chosen background, the thumbnail for a note.
struct NotePaper: View {
    @AppStorage(AppSettings.pageBackground) private var background = PageBackground.dots

    var body: some View {
        GeometryReader { geo in
            PageBackgroundView(style: background, regions: [CGRect(origin: .zero, size: geo.size)], spacing: 12)
        }
        .background(.white)
    }
}

/// The first page of a PDF, rendered off the main thread.
struct PDFThumbnail: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.white
            if let image {
                // Fills the landscape tile, showing the top of the page.
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: LibraryMetrics.tileWidth, height: LibraryMetrics.thumbnailHeight, alignment: .top)
            } else {
                Image(systemName: "doc.richtext").font(.system(size: 40)).foregroundStyle(.tertiary)
            }
        }
        .task(id: url) {
            let size = CGSize(width: LibraryMetrics.tileWidth * 2, height: LibraryMetrics.tileWidth * 4)
            image = await Task.detached(priority: .utility) {
                PDFDocument(url: url)?.page(at: 0)?.thumbnail(of: size, for: .mediaBox)
            }.value
        }
    }
}

/// Tiles shrink a touch while pressed.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

extension View {
    /// The tick circle shown on tiles while selecting.
    func selectionBadge(active: Bool, selected: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if active {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24))
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .background(Circle().fill(.background).padding(2))
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .opacity(active && !selected ? 0.85 : 1)
    }

    /// A filled capsule button, for the main action on content or inside a glass bar. Never glass itself: Liquid
    /// Glass belongs to floating controls, not content, and is never stacked on glass (DESIGN.md).
    func primaryActionButton() -> some View {
        buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
    }

    /// A tinted capsule button, for other actions on content or inside a glass bar.
    func secondaryActionButton() -> some View {
        buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
}

/// A screen's big title, drawn in SF Pro Rounded Semibold (iOS draws its own large titles in bold SF Pro, which
/// DESIGN.md rules out). Sits at the top of the screen's scroll view, so it scrolls away like a large title.
struct LibraryHeader: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 34, weight: .semibold, design: .rounded))
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, LibraryMetrics.spacing)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Names the screen (for back buttons and VoiceOver) without iOS drawing the title itself. With `inline`, a small
    /// rounded title is shown in the bar instead, for screens without a `LibraryHeader`.
    func roundedTitle(_ title: String, inline: Bool = false) -> some View {
        navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // A principal item replaces the system title; an empty one hides it.
                    Text(inline ? title : "")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .accessibilityHidden(!inline)
                }
            }
    }
}

enum LibraryFormat {
    /// "2 hours ago", "yesterday"…
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}

// MARK: - Toolbar items

struct SelectToolbarItem: ToolbarContent {
    @Binding var selection: LibrarySelection
    let isEmpty: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(selection.isActive ? "Done" : "Select") {
                withAnimation(.snappy) { selection.isActive ? selection.end() : selection.begin() }
            }
            .disabled(isEmpty && !selection.isActive)
        }
    }
}

struct AddToolbarItem: ToolbarContent {
    @Binding var prompt: LibraryPrompt?
    let folderID: UUID?
    let allowsFolders: Bool
    let store: CanvasStore

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("New Note", systemImage: "square.and.pencil") { prompt = .newNote(folderID: folderID) }
                if allowsFolders {
                    Button("New Folder", systemImage: "folder.badge.plus") { prompt = .newFolder }
                }
                Button("Import PDF", systemImage: "doc.badge.plus") { prompt = .importPDF(folderID: folderID) }
            } label: {
                Label("Add", systemImage: "plus")
            }
        }
    }
}

struct DeleteSelectionToolbarItem: ToolbarContent {
    let selection: LibrarySelection
    let action: () -> Void

    var body: some ToolbarContent {
        if selection.isActive {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Delete", systemImage: "trash", role: .destructive, action: action)
                    .disabled(selection.count == 0)
            }
        }
    }
}

// MARK: - Context menus

struct FolderMenu: View {
    let folder: CanvasFolder
    let store: CanvasStore
    @Binding var prompt: LibraryPrompt?

    var body: some View {
        Button("Rename", systemImage: "pencil") { prompt = .renameFolder(folder.id) }
        Divider()
        Button("Delete Folder", systemImage: "trash", role: .destructive) {
            withAnimation { store.deleteFolder(folder) }
        }
    }
}

struct DocumentMenu: View {
    let document: CanvasDocument
    let store: CanvasStore
    @Binding var prompt: LibraryPrompt?

    var body: some View {
        Button("Rename", systemImage: "pencil") { prompt = .renameNote(document.id) }
        Menu("Move To", systemImage: "folder") {
            Button("Documents", systemImage: "doc.on.doc") {
                withAnimation { store.move(documentID: document.id, to: nil) }
            }
            .disabled(document.folderID == nil)
            ForEach(store.folders) { folder in
                Button(folder.name, systemImage: "folder") {
                    withAnimation { store.move(documentID: document.id, to: folder.id) }
                }
                .disabled(document.folderID == folder.id)
            }
        }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            withAnimation { store.moveToTrash(document) }
        }
    }
}

// MARK: - Prompts: naming, importing and dropping PDFs

extension View {
    /// Handles `prompt` (name alerts and the PDF picker) and accepts PDFs dropped onto the screen.
    func libraryPrompts(_ prompt: Binding<LibraryPrompt?>, store: CanvasStore, dropFolderID: UUID?) -> some View {
        modifier(LibraryPrompts(prompt: prompt, store: store, dropFolderID: dropFolderID))
    }
}

private struct LibraryPrompts: ViewModifier {
    @Binding var prompt: LibraryPrompt?
    let store: CanvasStore
    let dropFolderID: UUID?

    /// The prompt being answered, kept until the alert's buttons have run.
    @State private var active: LibraryPrompt?
    @State private var text = ""
    @State private var dropTargeted = false
    @State private var importError: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: prompt) { _, new in
                guard let new else { return }
                active = new
                text = defaultText(for: new)
            }
            .alert(title, isPresented: Binding(get: { prompt?.asksForName == true },
                                               set: { if !$0 { prompt = nil } })) {
                TextField(placeholder, text: $text)
                Button("Cancel", role: .cancel) {}
                Button(confirmTitle) { commit() }
            }
            .fileImporter(isPresented: Binding(get: { prompt?.asksForName == false },
                                               set: { if !$0 { prompt = nil } }),
                          allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
                importPicked(result)
            }
            .onDrop(of: [.pdf], isTargeted: $dropTargeted) { providers in
                importDropped(providers)
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .alert("Couldn't Import PDF", isPresented: Binding(get: { importError != nil },
                                                              set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
    }

    private var title: String {
        switch active {
        case .newNote: "New Note"
        case .newFolder: "New Folder"
        case .renameNote: "Rename Note"
        case .renameFolder: "Rename Folder"
        default: ""
        }
    }

    private var placeholder: String {
        switch active {
        case .newFolder, .renameFolder: "Folder name"
        default: "Note title"
        }
    }

    private var confirmTitle: String {
        switch active {
        case .renameNote, .renameFolder: "Rename"
        default: "Create"
        }
    }

    private func defaultText(for prompt: LibraryPrompt) -> String {
        switch prompt {
        case .newNote: "Untitled"
        case .newFolder: "New Folder"
        case .renameNote(let id): store.document(id)?.title ?? ""
        case .renameFolder(let id): store.folder(id)?.name ?? ""
        case .importPDF: ""
        }
    }

    private func commit() {
        withAnimation {
            switch active {
            case .newNote(let folderID): store.createNote(title: text, in: folderID)
            case .newFolder: store.createFolder(name: text)
            case .renameNote(let id): store.rename(documentID: id, to: text)
            case .renameFolder(let id): store.rename(folderID: id, to: text)
            case .importPDF, nil: break
            }
        }
        active = nil
    }

    private func importPicked(_ result: Result<[URL], Error>) {
        let folderID: UUID? = if case .importPDF(let id) = active { id } else { nil }
        active = nil
        switch result {
        case .success(let urls):
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    _ = try withAnimation { try store.importPDF(from: url, into: folderID) }
                } catch {
                    importError = error.localizedDescription
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private func importDropped(_ providers: [NSItemProvider]) {
        let folderID = dropFolderID
        for provider in providers {
            let name = provider.suggestedName
            _ = provider.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, error in
                // The file is only valid inside this callback, so copy it out first.
                guard let url else { return }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
                guard (try? FileManager.default.copyItem(at: url, to: copy)) != nil else { return }
                let title = name ?? url.deletingPathExtension().lastPathComponent
                Task { @MainActor in
                    defer { try? FileManager.default.removeItem(at: copy) }
                    do {
                        _ = try withAnimation { try store.importPDF(from: copy, title: title, into: folderID) }
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            }
        }
    }
}

// MARK: - PDF viewer

struct PDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.backgroundColor = .secondarySystemBackground
        view.document = PDFDocument(url: url)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
