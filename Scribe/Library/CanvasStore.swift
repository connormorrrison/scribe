import Foundation
import Observation

/// A folder in the library. Folders hold notes and other folders.
struct CanvasFolder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    /// The folder it lives in, or nil for the top of Documents. Libraries saved before folders nested have none.
    var parentID: UUID?
    var createdAt = Date()
}

/// A note or an imported PDF.
struct CanvasDocument: Identifiable, Codable, Hashable {
    enum Kind: String, Codable { case note, pdf }

    var id = UUID()
    var title: String
    var kind: Kind = .note
    /// The folder it lives in, or nil for loose in Documents.
    var folderID: UUID?
    var createdAt = Date()
    var modifiedAt = Date()
    var openedAt: Date?
    /// Set while the document is in the Trash.
    var trashedAt: Date?
    /// For a PDF: its file name inside the store's Files directory.
    var fileName: String?

    var isTrashed: Bool { trashedAt != nil }
}

/// The library: every folder and document, saved as JSON in Application Support, with imported PDFs alongside.
@MainActor
@Observable
final class CanvasStore {
    /// Days a document stays in the Trash before it is deleted for good.
    static let trashDays = 30

    private(set) var folders: [CanvasFolder] = []
    private var all: [CanvasDocument] = []

    private let directory: URL?

    /// - Parameter directory: where to keep the library; nil keeps it in memory only (previews).
    init(directory: URL? = CanvasStore.defaultDirectory) {
        self.directory = directory
        load()
        purgeExpiredTrash()
    }

    nonisolated static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Library", isDirectory: true)
    }

    // MARK: Queries

    /// Every document that isn't in the Trash.
    var documents: [CanvasDocument] { all.filter { !$0.isTrashed } }

    /// Documents in a folder (or loose, for nil), newest first.
    func documents(inFolder folderID: UUID?) -> [CanvasDocument] {
        documents.filter { $0.folderID == folderID }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func documents(in folder: CanvasFolder) -> [CanvasDocument] { documents(inFolder: folder.id) }

    /// Most recently opened or edited first.
    var recents: [CanvasDocument] {
        Array(documents.sorted { ($0.openedAt ?? $0.modifiedAt) > ($1.openedAt ?? $1.modifiedAt) }.prefix(30))
    }

    /// Most recently trashed first.
    var trash: [CanvasDocument] {
        all.filter(\.isTrashed).sorted { ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast) }
    }

    func folder(_ id: UUID) -> CanvasFolder? { folders.first { $0.id == id } }

    /// The folders directly inside a folder (or at the top of Documents, for nil), by name.
    func folders(in parentID: UUID?) -> [CanvasFolder] {
        folders.filter { $0.parentID == parentID }
    }

    /// The folders a folder sits inside, outermost first, not including itself.
    func ancestors(of folderID: UUID) -> [CanvasFolder] {
        var chain: [CanvasFolder] = []
        var seen: Set<UUID> = [folderID]
        var next = folder(folderID)?.parentID
        while let id = next, seen.insert(id).inserted, let parent = folder(id) {
            chain.insert(parent, at: 0)
            next = parent.parentID
        }
        return chain
    }

    /// Where something lives, for captions: "Documents", or "Physics › Waves".
    func locationName(_ folderID: UUID?) -> String {
        guard let folderID, let folder = folder(folderID) else { return "Documents" }
        return (ancestors(of: folderID) + [folder]).map(\.name).joined(separator: " › ")
    }

    /// Whether `folderID` is `ancestorID` or sits somewhere inside it.
    func isFolder(_ folderID: UUID?, within ancestorID: UUID) -> Bool {
        guard let folderID else { return false }
        return folderID == ancestorID || ancestors(of: folderID).contains { $0.id == ancestorID }
    }

    /// Every note in a folder and the folders inside it, newest first.
    func allDocuments(within folderID: UUID) -> [CanvasDocument] {
        documents.filter { isFolder($0.folderID, within: folderID) }.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// How many folders and notes sit directly in a folder.
    func itemCount(in folderID: UUID) -> Int {
        folders(in: folderID).count + documents(inFolder: folderID).count
    }

    /// Whether something with this ID could go into `target`: a folder can't go inside itself.
    func canMove(_ id: UUID, to target: UUID?) -> Bool {
        if let folder = folder(id) {
            guard let target else { return true }
            return !isFolder(target, within: folder.id)
        }
        return document(id) != nil
    }

    /// The folder something lives in (nil for the top of Documents), whether it's a note or a folder.
    func location(of id: UUID) -> UUID? {
        if let folder = folder(id) { return folder.parentID }
        return document(id)?.folderID
    }

    func document(_ id: UUID) -> CanvasDocument? { all.first { $0.id == id } }

    func fileURL(for document: CanvasDocument) -> URL? {
        guard let name = document.fileName else { return nil }
        return filesDirectory?.appendingPathComponent(name)
    }

    /// Where a note keeps its pages, ink and images; nil for an in-memory store.
    func noteDirectory(for documentID: UUID) -> URL? {
        directory?.appendingPathComponent("Notes", isDirectory: true)
            .appendingPathComponent(documentID.uuidString, isDirectory: true)
    }

    /// Marks a note as edited, so it sorts to the top.
    func touch(_ documentID: UUID) {
        update(documentID) { $0.modifiedAt = .now }
    }

    /// Days left before a trashed document is deleted for good.
    func daysLeft(_ document: CanvasDocument) -> Int {
        guard let trashed = document.trashedAt else { return Self.trashDays }
        let elapsed = Calendar.current.dateComponents([.day], from: trashed, to: .now).day ?? 0
        return max(0, Self.trashDays - elapsed)
    }

    // MARK: Creating

    @discardableResult
    func createNote(title: String, in folderID: UUID?) -> CanvasDocument {
        let note = CanvasDocument(title: Self.clean(title, fallback: "Untitled"), folderID: folderID)
        all.append(note)
        save()
        return note
    }

    @discardableResult
    func createFolder(name: String, in parentID: UUID? = nil) -> CanvasFolder {
        let folder = CanvasFolder(name: Self.clean(name, fallback: "New Folder"),
                                  parentID: parentID.flatMap { self.folder($0)?.id })
        folders.append(folder)
        sortFolders()
        save()
        return folder
    }

    /// Copies a PDF into the library.
    @discardableResult
    func importPDF(from url: URL, title: String? = nil, into folderID: UUID?) throws -> CanvasDocument {
        var document = CanvasDocument(title: Self.clean(title ?? url.deletingPathExtension().lastPathComponent,
                                                        fallback: "Untitled PDF"),
                                      kind: .pdf, folderID: folderID)
        let name = "\(document.id.uuidString).pdf"
        if let files = filesDirectory {
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: files.appendingPathComponent(name))
        }
        document.fileName = name
        all.append(document)
        save()
        return document
    }

    // MARK: Changing

    func rename(documentID: UUID, to title: String) {
        update(documentID) { $0.title = Self.clean(title, fallback: $0.title); $0.modifiedAt = .now }
    }

    func rename(folderID: UUID, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == folderID }) else { return }
        folders[i].name = Self.clean(name, fallback: folders[i].name)
        sortFolders()
        save()
    }

    /// Moves a document into a folder, or loose into Documents for nil. Restores it if it was in the Trash.
    func move(documentID: UUID, to folderID: UUID?) {
        update(documentID) { $0.folderID = folderID; $0.trashedAt = nil }
    }

    /// Moves notes and folders (mixed, by ID) into a folder, or to the top of Documents for nil. Skips a folder that
    /// would end up inside itself. Returns how many moved.
    @discardableResult
    func move(_ ids: some Sequence<UUID>, to target: UUID?) -> Int {
        if let target, folder(target) == nil { return 0 }
        var moved = 0
        for id in ids where canMove(id, to: target) {
            if let i = folders.firstIndex(where: { $0.id == id }) {
                guard folders[i].parentID != target else { continue }
                folders[i].parentID = target
                moved += 1
            } else if let i = all.firstIndex(where: { $0.id == id }) {
                guard all[i].folderID != target || all[i].isTrashed else { continue }
                all[i].folderID = target
                all[i].trashedAt = nil
                moved += 1
            }
        }
        if moved > 0 { save() }
        return moved
    }

    func markOpened(_ documentID: UUID) {
        update(documentID) { $0.openedAt = .now }
    }

    // MARK: Deleting

    func moveToTrash(_ document: CanvasDocument) {
        update(document.id) { $0.trashedAt = .now }
    }

    func restore(_ document: CanvasDocument) {
        update(document.id) { doc in
            doc.trashedAt = nil
            // Its folder may have gone while it was in the Trash.
            if let folder = doc.folderID, self.folder(folder) == nil { doc.folderID = nil }
        }
    }

    func deletePermanently(_ document: CanvasDocument) {
        if let url = fileURL(for: document) { try? FileManager.default.removeItem(at: url) }
        if let url = noteDirectory(for: document.id) { try? FileManager.default.removeItem(at: url) }
        all.removeAll { $0.id == document.id }
        save()
    }

    func emptyTrash() {
        trash.forEach(deletePermanently)
    }

    /// Deletes a folder. What was inside it (notes and folders) moves up into the folder that held it.
    func deleteFolder(_ folder: CanvasFolder) {
        let parent = self.folder(folder.id)?.parentID
        for i in all.indices where all[i].folderID == folder.id { all[i].folderID = parent }
        for i in folders.indices where folders[i].parentID == folder.id { folders[i].parentID = parent }
        folders.removeAll { $0.id == folder.id }
        save()
    }

    // MARK: Storage

    private var filesDirectory: URL? { directory?.appendingPathComponent("Files", isDirectory: true) }
    private var indexURL: URL? { directory?.appendingPathComponent("library.json") }

    private struct Snapshot: Codable {
        var folders: [CanvasFolder]
        var documents: [CanvasDocument]
    }

    /// Reads `library.json`. One that exists but can't be read is set aside (kept for recovery), so the next save
    /// can't overwrite the library with an empty one.
    private func load() {
        guard let url = indexURL, FileManager.default.fileExists(atPath: url.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(Snapshot.self, from: data) else {
            StoredFile.setAside(url)
            return
        }
        folders = snapshot.folders
        all = snapshot.documents
        sortFolders()
    }

    /// Writes `library.json` atomically after every change.
    private func save() {
        guard let directory, let url = indexURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Snapshot(folders: folders, documents: all))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            StoredFile.log.error("Couldn't save the library: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func purgeExpiredTrash() {
        trash.filter { daysLeft($0) == 0 }.forEach(deletePermanently)
    }

    private func update(_ id: UUID, _ change: (inout CanvasDocument) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        change(&all[i])
        save()
    }

    private func sortFolders() {
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func clean(_ text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}
