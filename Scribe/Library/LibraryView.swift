import SwiftUI

/// A place in the sidebar.
enum SidebarItem: Hashable {
    case recents
    case documents
    case folder(UUID)
    case trash
    case settings
}

/// The dashboard: a sidebar (Recents, Documents with its folders, Trash, Settings) and the chosen screen beside it.
struct LibraryView: View {
    @Bindable var store: CanvasStore
    @State private var item: SidebarItem? = .documents
    @State private var path: [LibraryRoute] = []
    @State private var documentsExpanded = true
    /// Starts with the sidebar showing, in portrait too.
    @State private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
        } detail: {
            NavigationStack(path: $path) {
                screen(for: item ?? .documents)
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
        .onChange(of: item) { path = [] }
        // If the open folder is deleted, fall back to Documents.
        .onChange(of: store.folders) {
            if case .folder(let id) = item, store.folder(id) == nil { item = .documents }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $item) {
            Section {
                Label("Recents", systemImage: "clock")
                    .tag(SidebarItem.recents)

                DisclosureGroup(isExpanded: $documentsExpanded) {
                    ForEach(store.folders) { folder in
                        Label(folder.name, systemImage: "folder")
                            .tag(SidebarItem.folder(folder.id))
                            .dropDestination(for: String.self) { ids, _ in move(ids, to: folder.id) }
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

    @ViewBuilder
    private func screen(for item: SidebarItem) -> some View {
        switch item {
        case .recents: RecentsView(store: store)
        case .documents: DocumentsView(store: store)
        case .folder(let id): FolderView(store: store, folderID: id).id(id)
        case .trash: TrashView(store: store)
        case .settings: SettingsView()
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

#Preview {
    LibraryView(store: CanvasStore(directory: nil))
}
