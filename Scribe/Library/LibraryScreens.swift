import SwiftUI

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
                    .padding(.horizontal, LibraryMetrics.margin)
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
    /// What Back does; nil pops the navigation stack.
    var onBack: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let document = store.document(documentID) {
                // Notes and imported PDFs open the same way: a PDF is a note with its pages as paper.
                CanvasView(store: store, document: document) {
                    if let onBack { onBack() } else { dismiss() }
                }
                .toolbar(.hidden, for: .navigationBar)
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
