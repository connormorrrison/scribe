import SwiftUI

/// The folders and notes in one folder, Finder-style. Documents is the top level (`folderID` nil).
///
/// Notes and folders can be dragged onto a folder (here or in the sidebar) to move them; while selecting, dragging
/// any selected tile carries the whole selection. Select also offers Move, New Folder (with the selection inside)
/// and Delete in a bottom bar.
struct FolderView: View {
    @Bindable var store: CanvasStore
    let folderID: UUID?
    @State private var prompt: LibraryPrompt?
    @State private var selection = LibrarySelection()
    @State private var confirmingDelete = false

    var body: some View {
        if let folderID, store.folder(folderID) == nil {
            ContentUnavailableView("Folder Not Found", systemImage: "folder.badge.questionmark",
                                   description: Text("It may have been deleted."))
        } else {
            contents
        }
    }

    private var title: String {
        folderID.flatMap(store.folder)?.name ?? "Documents"
    }

    private var contents: some View {
        let folders = store.folders(in: folderID)
        let notes = store.documents(inFolder: folderID)
        let isEmpty = folders.isEmpty && notes.isEmpty

        return ScrollView {
            LibraryHeader(title)
            if isEmpty {
                LibraryEmptyState(title: folderID == nil ? "No Documents" : "Empty Folder",
                                  symbol: "folder",
                                  message: folderID == nil
                                      ? "Create a note, import a PDF, or drop one here."
                                      : "Create a note here, import a PDF, or drag notes and folders onto this folder.",
                                  importPDF: { prompt = .importPDF(folderID: folderID) }) {
                    prompt = .newNote(folderID: folderID)
                }
            } else {
                LibraryGrid {
                    ForEach(folders) { folder in
                        FolderLink(folder: folder, store: store, prompt: $prompt, selection: $selection)
                    }
                    ForEach(notes) { doc in
                        NoteLink(document: doc, store: store, prompt: $prompt, selection: $selection)
                    }
                }
            }
        }
        .roundedTitle(title)
        .toolbar {
            SelectToolbarItem(selection: $selection, isEmpty: isEmpty,
                              allFolders: folders.map(\.id), allNotes: notes.map(\.id))
            if !selection.isActive {
                AddToolbarItem(prompt: $prompt, folderID: folderID, allowsFolders: true, store: store)
            }
            SelectionActionsToolbar(selection: selection, prompt: $prompt, folderID: folderID) {
                confirmingDelete = true
            }
        }
        .toolbar(selection.isActive ? .visible : .automatic, for: .bottomBar)
        // Anything moved away (by a drag from the sidebar, say) drops out of the selection.
        .onChange(of: folders.map(\.id) + notes.map(\.id)) {
            selection.keep(folders: Set(folders.map(\.id)), notes: Set(notes.map(\.id)))
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .libraryPrompts($prompt, store: store, dropFolderID: folderID) {
            withAnimation(.snappy) { selection.end() }
        }
    }

    private var deleteTitle: String {
        let n = selection.count
        return n == 1 ? "Delete 1 item?" : "Delete \(n) items?"
    }

    private var deleteMessage: String {
        if selection.folders.isEmpty { return "The notes move to the Trash, where you can restore them." }
        let place = folderID == nil ? "Documents" : "this folder"
        return selection.notes.isEmpty
            ? "What's inside the folders moves into \(place)."
            : "What's inside the folders moves into \(place). Selected notes move to the Trash."
    }

    private func deleteSelection() {
        let folders = store.folders.filter { selection.folders.contains($0.id) }
        let notes = store.documents.filter { selection.notes.contains($0.id) }
        withAnimation {
            notes.forEach { store.moveToTrash($0) }
            folders.forEach { store.deleteFolder($0) }
            selection.end()
        }
    }
}

/// A folder tile that opens the folder, takes notes and folders dropped onto it, can itself be dragged into another
/// folder, and has the folder menu.
struct FolderLink: View {
    let folder: CanvasFolder
    let store: CanvasStore
    @Binding var prompt: LibraryPrompt?
    @Binding var selection: LibrarySelection
    @State private var targeted = false

    var body: some View {
        let selected = selection.folders.contains(folder.id)
        let tile = FolderTile(folder: folder, documents: store.allDocuments(within: folder.id),
                              itemCount: store.itemCount(in: folder.id), dropTargeted: targeted)
            .selectionBadge(active: selection.isActive, selected: selected)
        Group {
            if selection.isActive {
                Button { selection.toggle(folder: folder.id) } label: { tile }
            } else {
                NavigationLink(value: LibraryRoute.folder(folder.id)) { tile }
                    .contextMenu { FolderMenu(folder: folder, store: store, prompt: $prompt) }
            }
        }
        .buttonStyle(TileButtonStyle())
        .draggable(LibraryDrag.payload(dragIDs(selected: selected))) {
            DragPreview(count: dragIDs(selected: selected).count) {
                FolderTile(folder: folder, documents: store.allDocuments(within: folder.id),
                           itemCount: store.itemCount(in: folder.id))
            }
        }
        .libraryDropTarget(folder.id, store: store, targeted: $targeted) {
            withAnimation(.snappy) { selection.end() }
        }
    }

    /// Dragging a selected tile drags the whole selection.
    private func dragIDs(selected: Bool) -> [UUID] {
        selection.isActive && selected ? selection.ids : [folder.id]
    }
}

/// What a drag looks like: the tile, with a count badge when several items go together.
struct DragPreview<Tile: View>: View {
    let count: Int
    @ViewBuilder let tile: Tile

    var body: some View {
        tile
            .frame(width: LibraryMetrics.tileWidth)
            .overlay(alignment: .topTrailing) {
                if count > 1 {
                    Text("\(count)")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
    }
}

/// A note tile that opens the note, can be dragged onto a folder, and has the note menu.
struct NoteLink: View {
    let document: CanvasDocument
    let store: CanvasStore
    @Binding var prompt: LibraryPrompt?
    @Binding var selection: LibrarySelection
    var caption: String? = nil

    init(document: CanvasDocument, store: CanvasStore, prompt: Binding<LibraryPrompt?>,
         selection: Binding<LibrarySelection> = .constant(LibrarySelection()), caption: String? = nil) {
        self.document = document
        self.store = store
        self._prompt = prompt
        self._selection = selection
        self.caption = caption
    }

    var body: some View {
        let selected = selection.notes.contains(document.id)
        let tile = DocumentTile(document: document, caption: caption)
            .selectionBadge(active: selection.isActive, selected: selected)
        let ids = selection.isActive && selected ? selection.ids : [document.id]
        Group {
            if selection.isActive {
                Button { selection.toggle(note: document.id) } label: { tile }
            } else {
                NavigationLink(value: LibraryRoute.note(document.id)) { tile }
                    .contextMenu { DocumentMenu(document: document, store: store, prompt: $prompt) }
            }
        }
        .buttonStyle(TileButtonStyle())
        // Dragging a selected tile drags the whole selection.
        .draggable(LibraryDrag.payload(ids)) {
            DragPreview(count: ids.count) { DocumentTile(document: document) }
        }
    }
}

/// The empty state every library screen uses.
struct LibraryEmptyState: View {
    let title: String
    let symbol: String
    let message: String
    var importPDF: (() -> Void)? = nil
    let create: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
                .fontWeight(.semibold)
        } description: {
            Text(message)
        } actions: {
            HStack(spacing: 12) {
                Button("New Note", systemImage: "plus", action: create)
                    .primaryActionButton()
                if let importPDF {
                    Button("Import PDF", systemImage: "doc.badge.plus", action: importPDF)
                        .secondaryActionButton()
                }
            }
        }
        .padding(.top, 120)
    }
}
