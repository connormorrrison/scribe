import SwiftUI

/// The notes in one folder.
struct FolderView: View {
    @Bindable var store: CanvasStore
    let folderID: UUID
    @State private var prompt: LibraryPrompt?
    @State private var selection = LibrarySelection()
    @State private var confirmingDelete = false

    var body: some View {
        if let folder = store.folder(folderID) {
            let notes = store.documents(in: folder)
            ScrollView {
                LibraryHeader(folder.name)
                if notes.isEmpty {
                    LibraryEmptyState(title: "Empty Folder", symbol: "folder",
                                      message: "Create a note here, import a PDF, or drag notes onto this folder.",
                                      importPDF: { prompt = .importPDF(folderID: folderID) }) {
                        prompt = .newNote(folderID: folderID)
                    }
                } else {
                    LibraryGrid {
                        ForEach(notes) { doc in
                            NoteLink(document: doc, store: store, prompt: $prompt, selection: $selection)
                        }
                    }
                }
            }
            .roundedTitle(folder.name)
            .toolbar {
                SelectToolbarItem(selection: $selection, isEmpty: notes.isEmpty)
                if !selection.isActive {
                    AddToolbarItem(prompt: $prompt, folderID: folderID, allowsFolders: false, store: store)
                }
                DeleteSelectionToolbarItem(selection: selection) { confirmingDelete = true }
            }
            .confirmationDialog(selection.count == 1 ? "Delete 1 note?" : "Delete \(selection.count) notes?",
                                isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) {
                    withAnimation {
                        store.documents.filter { selection.notes.contains($0.id) }.forEach { store.moveToTrash($0) }
                        selection.end()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The notes move to the Trash, where you can restore them.")
            }
            .libraryPrompts($prompt, store: store, dropFolderID: folderID)
        } else {
            ContentUnavailableView("Folder Not Found", systemImage: "folder.badge.questionmark",
                                   description: Text("It may have been deleted."))
        }
    }
}

/// Recently opened or edited notes, across every folder.
struct RecentsView: View {
    @Bindable var store: CanvasStore
    @State private var prompt: LibraryPrompt?

    var body: some View {
        let recents = store.recents
        ScrollView {
            LibraryHeader("Recents")
            if recents.isEmpty {
                LibraryEmptyState(title: "No Recent Notes", symbol: "clock",
                                  message: "Notes you open or edit show up here.",
                                  importPDF: { prompt = .importPDF(folderID: nil) }) {
                    prompt = .newNote(folderID: nil)
                }
            } else {
                LibraryGrid {
                    ForEach(recents) { doc in
                        NoteLink(document: doc, store: store, prompt: $prompt,
                                 caption: LibraryFormat.relative(doc.openedAt ?? doc.modifiedAt).capitalizedFirst)
                    }
                }
            }
        }
        .roundedTitle("Recents")
        .toolbar {
            AddToolbarItem(prompt: $prompt, folderID: nil, allowsFolders: false, store: store)
        }
        .libraryPrompts($prompt, store: store, dropFolderID: nil)
    }
}

/// Trashed notes: restore them, or delete them for good. They go by themselves after 30 days.
struct TrashView: View {
    @Bindable var store: CanvasStore
    @State private var confirmingEmpty = false

    var body: some View {
        let trash = store.trash
        ScrollView {
            LibraryHeader("Trash")
            if trash.isEmpty {
                ContentUnavailableView {
                    Label("Trash Is Empty", systemImage: "trash").fontWeight(.semibold)
                } description: {
                    Text("Deleted notes stay here for \(CanvasStore.trashDays) days.")
                }
                .padding(.top, 120)
            } else {
                Text("Notes are deleted for good after \(CanvasStore.trashDays) days. Tap one to restore it.")
                    .font(.system(size: 15, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LibraryMetrics.spacing)
                    .padding(.top, 8)
                LibraryGrid {
                    ForEach(trash) { doc in
                        let days = store.daysLeft(doc)
                        Menu {
                            Button("Restore", systemImage: "arrow.uturn.backward") { withAnimation { store.restore(doc) } }
                            Button("Delete Now", systemImage: "trash", role: .destructive) {
                                withAnimation { store.deletePermanently(doc) }
                            }
                        } label: {
                            DocumentTile(document: doc, caption: days == 1 ? "1 day left" : "\(days) days left")
                                .opacity(0.75)
                        }
                        .buttonStyle(TileButtonStyle())
                    }
                }
            }
        }
        .roundedTitle("Trash")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Empty Trash", role: .destructive) { confirmingEmpty = true }
                    .disabled(trash.isEmpty)
            }
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Empty Trash", role: .destructive) { withAnimation { store.emptyTrash() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash is deleted for good. This can't be undone.")
        }
    }
}

/// A note or PDF, opened. The note canvas is still to come: for now a note is a blank page in the chosen background.
struct DocumentView: View {
    @Bindable var store: CanvasStore
    let documentID: UUID
    @AppStorage(AppSettings.pageBackground) private var background = PageBackground.dots

    var body: some View {
        Group {
            if let document = store.document(documentID) {
                Group {
                    if document.kind == .pdf, let url = store.fileURL(for: document) {
                        PDFKitView(url: url).ignoresSafeArea(edges: .bottom)
                    } else {
                        GeometryReader { geo in
                            PageBackgroundView(style: background, regions: [CGRect(origin: .zero, size: geo.size)])
                        }
                        .background(.white)
                        .ignoresSafeArea(edges: .bottom)
                    }
                }
                .roundedTitle(document.title, inline: true)
            } else {
                ContentUnavailableView("Note Not Found", systemImage: "doc.questionmark")
            }
        }
        .onAppear { store.markOpened(documentID) }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
