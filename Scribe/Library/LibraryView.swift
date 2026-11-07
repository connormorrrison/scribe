import SwiftUI

/// A place in the sidebar.
enum SidebarItem: Hashable {
    case recents
    case documents
    case folder(UUID)
    case note(UUID)
    case trash
    case settings
}

/// The dashboard: a sidebar (Recents, Documents with its folders and notes, Trash, Settings) and the chosen screen
/// beside it, with search in the top-right corner.
struct LibraryView: View {
    @Bindable var store: CanvasStore
    @State private var item: SidebarItem? = .documents
    @State private var path: [LibraryRoute] = []
    @State private var documentsExpanded = true
    @State private var expandedFolders: Set<UUID> = []
    @State private var query = ""
    /// Starts with the sidebar showing, in portrait too.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        screen(for: item ?? .documents)
                    } else {
                        SearchResultsView(store: store, query: query)
                    }
                }
                .searchable(text: $query, placement: .toolbar, prompt: "Search Notes")
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .note(let id): DocumentView(store: store, documentID: id)
                    case .folder(let id): FolderView(store: store, folderID: id)
                    }
                }
            }
        }
        .environment(store)
        // A new sidebar choice starts its screen fresh.
        .onChange(of: item) {
            path = []
            query = ""
        }
        // Opening a note hides the sidebar so the whole page shows; leaving it brings the sidebar back.
        .onChange(of: showingNote) { _, note in
            withAnimation(.snappy) { columns = note ? .detailOnly : .all }
        }
        // If the open folder or note goes away, fall back to Documents.
        .onChange(of: store.folders) { fallBackIfGone() }
        .onChange(of: store.documents) { fallBackIfGone() }
    }

    /// Whether the detail column is showing a note, either pushed or chosen in the sidebar.
    private var showingNote: Bool {
        if let last = path.last {
            if case .note = last { return true }
            return false
        }
        if case .note = item { return true }
        return false
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $item) {
            Section {
                Label("Recents", systemImage: "clock")
                    .tag(SidebarItem.recents)

                DisclosureGroup(isExpanded: $documentsExpanded) {
                    ForEach(store.folders) { folder in
                        folderRow(folder)
                    }
                    ForEach(store.documents(inFolder: nil)) { doc in
                        noteRow(doc)
                    }
                } label: {
                    Label("Documents", systemImage: "doc.on.doc")
                        .dropDestination(for: String.self) { ids, _ in move(ids, to: nil) }
                }
                .tag(SidebarItem.documents)

                Label("Trash", systemImage: "trash")
                    .badge(store.trash.count)
                    .tag(SidebarItem.trash)
                    .dropDestination(for: String.self) { ids, _ in trash(ids) }
            }

            Section {
                Label("Settings", systemImage: "gearshape")
                    .tag(SidebarItem.settings)
            }
        }
        .roundedTitle("Scribe", inline: true)
    }

    /// A folder that opens to show its notes.
    private func folderRow(_ folder: CanvasFolder) -> some View {
        DisclosureGroup(isExpanded: Binding(get: { expandedFolders.contains(folder.id) },
                                            set: { if $0 { expandedFolders.insert(folder.id) } else { expandedFolders.remove(folder.id) } })) {
            ForEach(store.documents(in: folder)) { doc in
                noteRow(doc)
            }
        } label: {
            Label(folder.name, systemImage: "folder")
                .dropDestination(for: String.self) { ids, _ in move(ids, to: folder.id) }
        }
        .tag(SidebarItem.folder(folder.id))
    }

    private func noteRow(_ doc: CanvasDocument) -> some View {
        Label(doc.title, systemImage: doc.kind == .pdf ? "doc.richtext" : "doc.text")
            .lineLimit(1)
            .tag(SidebarItem.note(doc.id))
            .draggable(doc.id.uuidString)
    }

    @ViewBuilder
    private func screen(for item: SidebarItem) -> some View {
        switch item {
        case .recents: RecentsView(store: store)
        case .documents: DocumentsView(store: store)
        case .folder(let id): FolderView(store: store, folderID: id).id(id)
        case .note(let id): DocumentView(store: store, documentID: id) { self.item = .documents }.id(id)
        case .trash: TrashView(store: store)
        case .settings: SettingsView()
        }
    }

    private func fallBackIfGone() {
        switch item {
        case .folder(let id) where store.folder(id) == nil: item = .documents
        case .note(let id) where store.document(id)?.isTrashed ?? true: item = .documents
        default: break
        }
    }

    // MARK: Dropping notes onto sidebar rows

    private func move(_ ids: [String], to folderID: UUID?) -> Bool {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        withAnimation { uuids.forEach { store.move(documentID: $0, to: folderID) } }
        return !uuids.isEmpty
    }

    private func trash(_ ids: [String]) -> Bool {
        let docs = ids.compactMap(UUID.init(uuidString:)).compactMap(store.document)
        withAnimation { docs.forEach(store.moveToTrash) }
        return !docs.isEmpty
    }
}

/// Notes whose title matches the search, from every folder.
struct SearchResultsView: View {
    @Bindable var store: CanvasStore
    let query: String
    @State private var prompt: LibraryPrompt?

    var body: some View {
        let needle = query.trimmingCharacters(in: .whitespaces)
        let results = store.documents
            .filter { $0.title.localizedStandardContains(needle) }
            .sorted { $0.modifiedAt > $1.modifiedAt }

        ScrollView {
            LibraryHeader("Search")
            if results.isEmpty {
                ContentUnavailableView.search(text: needle)
                    .padding(.top, 80)
            } else {
                LibraryGrid {
                    ForEach(results) { doc in
                        NoteLink(document: doc, store: store, prompt: $prompt,
                                 caption: doc.folderID.flatMap(store.folder)?.name ?? "Documents")
                    }
                }
            }
        }
        .roundedTitle("Search")
        .libraryPrompts($prompt, store: store, dropFolderID: nil)
    }
}

#Preview {
    LibraryView(store: CanvasStore(directory: nil))
}
