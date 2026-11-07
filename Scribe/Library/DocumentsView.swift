import SwiftUI

/// Folders and loose notes side by side, Finder-style.
struct DocumentsView: View {
    @Bindable var store: CanvasStore
    @State private var prompt: LibraryPrompt?
    @State private var selection = LibrarySelection()
    @State private var confirmingDelete = false

    var body: some View {
        let looseNotes = store.documents(inFolder: nil)

        ScrollView {
            LibraryHeader("Documents")
            if store.folders.isEmpty && looseNotes.isEmpty {
                LibraryEmptyState(title: "No Documents",
                                  symbol: "folder",
                                  message: "Create a note, import a PDF, or drop one here.",
                                  importPDF: { prompt = .importPDF(folderID: nil) }) {
                    prompt = .newNote(folderID: nil)
                }
            } else {
                LibraryGrid {
                    ForEach(store.folders) { folder in
                        folderTile(folder)
                    }

                    ForEach(looseNotes) { doc in
                        NoteLink(document: doc, store: store, prompt: $prompt, selection: $selection)
                    }
                }
            }
        }
        .roundedTitle("Documents")
        .toolbar {
            SelectToolbarItem(selection: $selection, isEmpty: store.folders.isEmpty && looseNotes.isEmpty)
            if !selection.isActive {
                AddToolbarItem(prompt: $prompt, folderID: nil, allowsFolders: true, store: store)
            }
            DeleteSelectionToolbarItem(selection: selection) { confirmingDelete = true }
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteSelection() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage)
        }
        .libraryPrompts($prompt, store: store, dropFolderID: nil)
    }

    @ViewBuilder
    private func folderTile(_ folder: CanvasFolder) -> some View {
        let tile = FolderTile(folder: folder, documents: store.documents(in: folder))
            .selectionBadge(active: selection.isActive, selected: selection.folders.contains(folder.id))
        if selection.isActive {
            Button { selection.toggle(folder: folder.id) } label: { tile }
                .buttonStyle(TileButtonStyle())
        } else {
            NavigationLink(value: LibraryRoute.folder(folder.id)) { tile }
                .buttonStyle(TileButtonStyle())
                .contextMenu { FolderMenu(folder: folder, store: store, prompt: $prompt) }
                .dropDestination(for: String.self) { ids, _ in
                    moveNotes(ids, to: folder.id)
                }
        }
    }

    private var deleteTitle: String {
        let n = selection.count
        return n == 1 ? "Delete 1 item?" : "Delete \(n) items?"
    }

    private var deleteMessage: String {
        selection.folders.isEmpty
            ? "The notes move to the Trash, where you can restore them."
            : "Notes in deleted folders move to Documents. Selected notes move to the Trash."
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

    private func moveNotes(_ ids: [String], to folderID: UUID) -> Bool {
        let uuids = ids.compactMap(UUID.init(uuidString:))
        withAnimation { uuids.forEach { store.move(documentID: $0, to: folderID) } }
        return !uuids.isEmpty
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
        let tile = DocumentTile(document: document, caption: caption)
            .selectionBadge(active: selection.isActive, selected: selection.notes.contains(document.id))
        if selection.isActive {
            Button { selection.toggle(note: document.id) } label: { tile }
                .buttonStyle(TileButtonStyle())
        } else {
            NavigationLink(value: LibraryRoute.note(document.id)) { tile }
                .buttonStyle(TileButtonStyle())
                .draggable(document.id.uuidString) {
                    DocumentTile(document: document).frame(width: LibraryMetrics.tileWidth)
                }
                .contextMenu { DocumentMenu(document: document, store: store, prompt: $prompt) }
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
                    .prominentGlassButton()
                if let importPDF {
                    Button("Import PDF", systemImage: "doc.badge.plus", action: importPDF)
                        .secondaryGlassButton()
                }
            }
        }
        .padding(.top, 120)
    }
}
