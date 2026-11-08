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
    var ids: [UUID] { Array(folders) + Array(notes) }

    func contains(_ id: UUID) -> Bool { folders.contains(id) || notes.contains(id) }

    mutating func begin() { isActive = true }

    /// Selects everything given, or clears the selection if it's all selected already.
    mutating func toggleAll(folders allFolders: [UUID], notes allNotes: [UUID]) {
        if folders.count == allFolders.count && notes.count == allNotes.count {
            folders = []
            notes = []
        } else {
            folders = Set(allFolders)
            notes = Set(allNotes)
        }
    }

    /// Forgets anything that has left the screen (moved by a drag, say).
    mutating func keep(folders shown: Set<UUID>, notes shownNotes: Set<UUID>) {
        folders.formIntersection(shown)
        notes.formIntersection(shownNotes)
    }

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

/// A question the library asks: a name to type, PDFs to pick, or where to move things.
enum LibraryPrompt: Identifiable, Equatable {
    case newNote(folderID: UUID?)
    /// A new folder inside `parentID`, with `items` (notes and folders) moved into it once it's named.
    case newFolder(parentID: UUID?, items: [UUID] = [])
    case importPDF(folderID: UUID?)
    case renameNote(UUID)
    case renameFolder(UUID)
    /// Pick a folder to move these notes and folders into.
    case move([UUID])

    var id: String {
        switch self {
        case .newNote(let folder): "newNote-\(folder?.uuidString ?? "")"
        case .newFolder(let parent, let items): "newFolder-\(parent?.uuidString ?? "")-\(items.count)"
        case .importPDF(let folder): "importPDF-\(folder?.uuidString ?? "")"
        case .renameNote(let id): "renameNote-\(id)"
        case .renameFolder(let id): "renameFolder-\(id)"
        case .move(let ids): "move-\(ids.map(\.uuidString).joined())"
        }
    }

    var asksForName: Bool {
        switch self {
        case .importPDF, .move: false
        default: true
        }
    }

    var isImport: Bool {
        if case .importPDF = self { return true }
        return false
    }
}

/// What a dragged tile or sidebar row carries: the IDs of the notes and folders being dragged, so a whole selection
/// can be dropped onto a folder at once.
enum LibraryDrag {
    static func payload(_ ids: [UUID]) -> String { ids.map(\.uuidString).joined(separator: ",") }

    static func ids(_ payloads: [String]) -> [UUID] {
        payloads.flatMap { $0.split(separator: ",") }.compactMap { UUID(uuidString: String($0)) }
    }
}

extension View {
    /// Lets notes and folders be dropped onto this view to move them into `folderID` (nil: the top of Documents).
    /// `targeted` follows whether a drag is hovering over it.
    func libraryDropTarget(_ folderID: UUID?, store: CanvasStore, targeted: Binding<Bool>? = nil,
                           onMove: @escaping () -> Void = {}) -> some View {
        dropDestination(for: String.self) { payloads, _ in
            let ids = LibraryDrag.ids(payloads)
            let moved = withAnimation(.snappy) { store.move(ids, to: folderID) }
            if moved > 0 { onMove() }
            return moved > 0
        } isTargeted: { targeted?.wrappedValue = $0 }
    }
}

// MARK: - Grid and tiles

enum LibraryMetrics {
    static let tileWidth: CGFloat = 200
    /// The landscape screen a note opens on, in points: the canvas fits the page's width to it, so a tile of the
    /// same shape shows exactly what the canvas does, with nothing cut off at the sides.
    static let screenSize = CGSize(width: 1180, height: 820)
    /// Width over height of a note on the canvas, and so of every tile and folder preview.
    static let pageAspect: CGFloat = screenSize.width / screenSize.height
    static let thumbnailHeight: CGFloat = tileWidth / pageAspect
    static let spacing: CGFloat = 28
    /// Space at the left and right of every library screen.
    static let margin: CGFloat = 56
    static let cornerRadius: CGFloat = 16
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
        .padding(.horizontal, LibraryMetrics.margin)
        .padding(.vertical, 20)
    }
}

/// Artwork with a centred name and a caption underneath, like a Finder icon. Folders and notes share it, so they
/// line up.
struct LibraryTile<Artwork: View>: View {
    let title: String
    let caption: String
    @ViewBuilder var artwork: Artwork

    var body: some View {
        VStack(spacing: 10) {
            artwork
                .frame(width: LibraryMetrics.tileWidth, height: LibraryMetrics.thumbnailHeight)

            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Text(caption)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: LibraryMetrics.tileWidth)
        .padding(.vertical, 4)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hoverEffect(.highlight)
    }
}

/// A note or PDF: its page thumbnail.
struct DocumentTile: View {
    let document: CanvasDocument
    var caption: String? = nil

    var body: some View {
        LibraryTile(title: document.title,
                    caption: caption ?? document.modifiedAt.formatted(date: .abbreviated, time: .omitted)) {
            let shape = RoundedRectangle(cornerRadius: LibraryMetrics.cornerRadius, style: .continuous)
            DocumentArtwork(document: document)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 3)
        }
    }
}

/// A folder, like a Home Screen folder but landscape: a tinted tile holding small previews of its first four
/// notes (including notes in folders inside it). Every folder is the same neutral gray, outlined in the accent
/// colour while something is dragged over it.
struct FolderTile: View {
    let folder: CanvasFolder
    let documents: [CanvasDocument]
    let itemCount: Int
    var dropTargeted = false

    var body: some View {
        LibraryTile(title: folder.name, caption: itemCount == 1 ? "1 item" : "\(itemCount) items") {
            FolderArtwork(documents: documents)
                .overlay {
                    if dropTargeted {
                        let shape = RoundedRectangle(cornerRadius: LibraryMetrics.cornerRadius, style: .continuous)
                        shape.fill(Color.accentColor.opacity(0.12))
                            .overlay(shape.strokeBorder(Color.accentColor, lineWidth: 3))
                    }
                }
                .scaleEffect(dropTargeted ? 1.04 : 1)
                .animation(.snappy(duration: 0.2), value: dropTargeted)
        }
    }
}

struct FolderArtwork: View {
    let documents: [CanvasDocument]

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LibraryMetrics.cornerRadius, style: .continuous)
        let previews = Array(documents.prefix(4))
        let cell = RoundedRectangle(cornerRadius: 6, style: .continuous)

        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if index < previews.count {
                            DocumentArtwork(document: previews[index])
                                .aspectRatio(LibraryMetrics.pageAspect, contentMode: .fit)
                                .clipShape(cell)
                                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                        } else {
                            cell.fill(Color.primary.opacity(0.04))
                                .aspectRatio(LibraryMetrics.pageAspect, contentMode: .fit)
                        }
                    }
                }
            }
        }
        .padding(12)
        // Content, so a plain neutral fill rather than glass (DESIGN.md). Adapts to dark mode.
        .background(Color(.tertiarySystemFill), in: shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

/// What a note or PDF looks like, filling whatever frame it gets: the top of its first page.
struct DocumentArtwork: View {
    let document: CanvasDocument

    var body: some View {
        // A PDF's tile shows its markup too.
        NoteThumbnail(document: document)
    }
}

/// A blank page in the chosen background, the thumbnail for a note.
struct NotePaper: View {
    @AppStorage(AppSettings.pageBackground) private var background = PageBackground.dots

    var body: some View {
        GeometryReader { geo in
            PageBackgroundView(style: background, regions: [CGRect(origin: .zero, size: geo.size)],
                               spacing: max(6, geo.size.width / 16))
        }
        .background(.white)
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
            .padding(.horizontal, LibraryMetrics.margin)
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
    /// Everything on screen, for Select All.
    var allFolders: [UUID] = []
    var allNotes: [UUID] = []

    var body: some ToolbarContent {
        if selection.isActive {
            ToolbarItem(placement: .topBarLeading) {
                let allSelected = selection.count == allFolders.count + allNotes.count
                Button(allSelected ? "Deselect All" : "Select All") {
                    withAnimation(.snappy) { selection.toggleAll(folders: allFolders, notes: allNotes) }
                }
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button(selection.isActive ? "Done" : "Select") {
                withAnimation(.snappy) { selection.isActive ? selection.end() : selection.begin() }
            }
            .fontWeight(selection.isActive ? .semibold : .regular)
            .disabled(isEmpty && !selection.isActive)
        }
    }
}

/// While selecting: a bottom bar to move the selection, put it in a new folder, or delete it, like Files and Notes.
struct SelectionActionsToolbar: ToolbarContent {
    let selection: LibrarySelection
    @Binding var prompt: LibraryPrompt?
    /// The folder on screen, where a new folder is made.
    let folderID: UUID?
    let delete: () -> Void

    var body: some ToolbarContent {
        if selection.isActive {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Move", systemImage: "folder") { prompt = .move(selection.ids) }
                    .disabled(selection.count == 0)
                Button("New Folder", systemImage: "folder.badge.plus") {
                    prompt = .newFolder(parentID: folderID, items: selection.ids)
                }
                .disabled(selection.count == 0)
                Spacer()
                Text(selection.count == 0 ? "Select Items"
                     : selection.count == 1 ? "1 Selected" : "\(selection.count) Selected")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(selection.count == 0 ? .secondary : .primary)
                    .fixedSize()
                Spacer()
                Button("Delete", systemImage: "trash", role: .destructive, action: delete)
                    .disabled(selection.count == 0)
            }
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
                    Button("New Folder", systemImage: "folder.badge.plus") { prompt = .newFolder(parentID: folderID) }
                }
                Button("Import PDF", systemImage: "doc.badge.plus") { prompt = .importPDF(folderID: folderID) }
            } label: {
                Label("Add", systemImage: "plus")
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
        Button("Move To…", systemImage: "folder") { prompt = .move([folder.id]) }
        Button("New Folder Inside", systemImage: "folder.badge.plus") { prompt = .newFolder(parentID: folder.id) }
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
        Button("Move To…", systemImage: "folder") { prompt = .move([document.id]) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            withAnimation { store.moveToTrash(document) }
        }
    }
}

// MARK: - Prompts: naming, importing and dropping PDFs

extension View {
    /// Handles `prompt` (name alerts, the PDF picker and the Move sheet) and accepts PDFs dropped onto the screen.
    /// `onMoved` runs after notes or folders are moved or put in a new folder, to end a selection.
    func libraryPrompts(_ prompt: Binding<LibraryPrompt?>, store: CanvasStore, dropFolderID: UUID?,
                        onMoved: @escaping () -> Void = {}) -> some View {
        modifier(LibraryPrompts(prompt: prompt, store: store, dropFolderID: dropFolderID, onMoved: onMoved))
    }
}

private struct LibraryPrompts: ViewModifier {
    @Binding var prompt: LibraryPrompt?
    let store: CanvasStore
    let dropFolderID: UUID?
    let onMoved: () -> Void

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
            .sheet(item: Binding(get: { if case .move(let ids) = prompt { MoveRequest(ids: ids) } else { nil } },
                                 set: { if $0 == nil { prompt = nil } })) { request in
                MoveSheet(store: store, ids: request.ids) { target in
                    withAnimation(.snappy) { store.move(request.ids, to: target) }
                    onMoved()
                }
            }
            .fileImporter(isPresented: Binding(get: { prompt?.isImport == true },
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
        case .newFolder(_, let items) where !items.isEmpty:
            items.count == 1 ? "New Folder with 1 Item" : "New Folder with \(items.count) Items"
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
        case .importPDF, .move: ""
        }
    }

    private func commit() {
        withAnimation {
            switch active {
            case .newNote(let folderID): store.createNote(title: text, in: folderID)
            case .newFolder(let parentID, let items):
                let folder = store.createFolder(name: text, in: parentID)
                if !items.isEmpty {
                    store.move(items, to: folder.id)
                    onMoved()
                }
            case .renameNote(let id): store.rename(documentID: id, to: text)
            case .renameFolder(let id): store.rename(folderID: id, to: text)
            case .importPDF, .move, nil: break
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

// MARK: - Move sheet

private struct MoveRequest: Identifiable {
    let ids: [UUID]
    var id: String { ids.map(\.uuidString).joined() }
}

/// "Move 3 Items": Documents and every folder as an indented tree. Tap one to move there. Where the items already
/// are, and folders they can't go into (a folder can't go inside itself), are greyed out. New Folder makes one
/// inside the highlighted folder and moves everything there.
struct MoveSheet: View {
    let store: CanvasStore
    let ids: [UUID]
    let move: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var newName = "New Folder"
    /// Where New Folder puts the folder it makes.
    @State private var parentForNew: UUID?

    var body: some View {
        NavigationStack {
            List {
                row(name: "Documents", symbol: "doc.on.doc", folderID: nil, depth: 0)
                ForEach(tree, id: \.folder.id) { entry in
                    row(name: entry.folder.name, symbol: "folder", folderID: entry.folder.id, depth: entry.depth + 1)
                }
            }
            .listStyle(.insetGrouped)
            .roundedTitle(title, inline: true)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newName = "New Folder"
                        naming = true
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
            .alert("New Folder", isPresented: $naming) {
                TextField("Folder name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create and Move") {
                    let folder = withAnimation { store.createFolder(name: newName, in: firstValidParent) }
                    choose(folder.id)
                }
            } message: {
                Text("Made inside \(store.locationName(firstValidParent)), with the items moved into it.")
            }
        }
    }

    private var title: String {
        ids.count == 1 ? "Move 1 Item" : "Move \(ids.count) Items"
    }

    /// Every folder, depth first, each under its parent.
    private var tree: [(folder: CanvasFolder, depth: Int)] {
        var out: [(CanvasFolder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for folder in store.folders(in: parent) {
                out.append((folder, depth))
                walk(folder.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }

    /// Where everything selected already is, if it's all in one place.
    private var commonLocation: UUID?? {
        let places = Set(ids.map { store.location(of: $0) })
        return places.count == 1 ? places.first : .none
    }

    private func isAvailable(_ folderID: UUID?) -> Bool {
        if let common = commonLocation, common == folderID { return false }
        return ids.contains { store.canMove($0, to: folderID) && store.location(of: $0) != folderID }
    }

    /// New folders go where the items are now, so New Folder groups them in place.
    private var firstValidParent: UUID? { commonLocation ?? nil }

    private func row(name: String, symbol: String, folderID: UUID?, depth: Int) -> some View {
        let available = isAvailable(folderID)
        let here = commonLocation.map { $0 == folderID } ?? false
        return Button {
            choose(folderID)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .foregroundStyle(available ? Color.accentColor : Color.secondary)
                    .frame(width: 24)
                Text(name)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(available ? .primary : .secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if here {
                    Text("Current")
                        .font(.system(size: 15, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * 24)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private func choose(_ folderID: UUID?) {
        move(folderID)
        dismiss()
    }
}

// MARK: - PDF viewer

