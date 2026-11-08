import PencilKit
import XCTest
@testable import Scribe

/// Everything Scribe keeps is written to disk and comes back: each test saves through the app's own code, then reads
/// it back with fresh objects (as a relaunch would) from a temporary library.
@MainActor
final class StorageTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ScribeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func relaunchedStore() -> CanvasStore { CanvasStore(directory: root) }

    /// The conversation with the agent is saved with the note, and notes saved before it existed still open.
    func testConversationIsSavedAndOlderNotesStillOpen() throws {
        let file = NoteFile(directory: root.appendingPathComponent("note"))
        var content = NoteContent()
        content.conversation = [ConversationTurn(speaker: .you, text: "What's a monad?", spoken: true),
                                ConversationTurn(speaker: .agent, text: "A way to chain steps.", spoken: true)]
        XCTAssertTrue(file.save(content))
        XCTAssertEqual(file.load().conversation, content.conversation)

        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file.contentURL!)) as! [String: Any]
        json["conversation"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file.contentURL!)
        let older = file.read()
        XCTAssertTrue(older.fromDisk)
        XCTAssertEqual(older.content.pages.count, content.pages.count)
        XCTAssertTrue(older.content.conversation.isEmpty)
    }

    // MARK: Library

    func testLibraryChangesSurviveRelaunch() throws {
        let store = CanvasStore(directory: root)
        let folder = store.createFolder(name: "Physics")
        let note = store.createNote(title: "Waves", in: nil)
        let other = store.createNote(title: "Optics", in: folder.id)
        let gone = store.createNote(title: "Scratch", in: nil)
        store.rename(documentID: note.id, to: "Waves and Sound")
        store.rename(folderID: folder.id, to: "Physics 101")
        store.move(documentID: note.id, to: folder.id)
        store.markOpened(other.id)
        store.moveToTrash(other)
        store.deletePermanently(gone)
        let pdf = try store.importPDF(from: makePDF(pages: 2), title: "Worksheet", into: nil)

        let reopened = relaunchedStore()
        XCTAssertEqual(reopened.folders.map(\.name), ["Physics 101"])
        let waves = try XCTUnwrap(reopened.document(note.id))
        XCTAssertEqual(waves.title, "Waves and Sound")
        XCTAssertEqual(waves.folderID, folder.id)
        let optics = try XCTUnwrap(reopened.document(other.id))
        XCTAssertNotNil(optics.openedAt)
        XCTAssertTrue(optics.isTrashed)
        XCTAssertNil(reopened.document(gone.id))
        let worksheet = try XCTUnwrap(reopened.document(pdf.id))
        XCTAssertEqual(worksheet.kind, .pdf)
        let file = try XCTUnwrap(reopened.fileURL(for: worksheet))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        reopened.restore(optics)
        reopened.deleteFolder(try XCTUnwrap(reopened.folder(folder.id)))
        let again = relaunchedStore()
        XCTAssertFalse(try XCTUnwrap(again.document(other.id)).isTrashed)
        XCTAssertTrue(again.folders.isEmpty)
        XCTAssertNil(try XCTUnwrap(again.document(note.id)).folderID, "A deleted folder's notes move loose")
    }

    /// Folders nest; notes and folders move together; a folder can't go inside itself; deleting a folder lifts what
    /// was inside it up a level.
    func testFoldersNestAndMoveTogether() throws {
        let store = CanvasStore(directory: root)
        let physics = store.createFolder(name: "Physics")
        let waves = store.createFolder(name: "Waves", in: physics.id)
        let sound = store.createFolder(name: "Sound")
        let note = store.createNote(title: "Doppler", in: nil)
        let other = store.createNote(title: "Beats", in: waves.id)

        XCTAssertEqual(store.folders(in: nil).map(\.name), ["Physics", "Sound"])
        XCTAssertEqual(store.folders(in: physics.id).map(\.id), [waves.id])
        XCTAssertEqual(store.locationName(waves.id), "Physics › Waves")
        XCTAssertEqual(store.allDocuments(within: physics.id).map(\.id), [other.id])

        // A note and a folder move into Waves in one go.
        XCTAssertEqual(store.move([note.id, sound.id], to: waves.id), 2)
        XCTAssertEqual(store.itemCount(in: waves.id), 3)

        // Physics can't go inside itself or anything inside it; moving to where it is already does nothing.
        XCTAssertFalse(store.canMove(physics.id, to: physics.id))
        XCTAssertFalse(store.canMove(physics.id, to: sound.id))
        XCTAssertEqual(store.move([physics.id], to: sound.id), 0)
        XCTAssertEqual(store.move([note.id], to: waves.id), 0)

        let reopened = relaunchedStore()
        XCTAssertEqual(reopened.folder(sound.id)?.parentID, waves.id)
        XCTAssertEqual(reopened.document(note.id)?.folderID, waves.id)

        // Deleting Waves lifts its notes and folders into Physics.
        reopened.deleteFolder(try XCTUnwrap(reopened.folder(waves.id)))
        XCTAssertEqual(reopened.folder(sound.id)?.parentID, physics.id)
        XCTAssertEqual(reopened.document(note.id)?.folderID, physics.id)
        XCTAssertEqual(reopened.document(other.id)?.folderID, physics.id)
    }

    /// Libraries saved before folders nested open with every folder at the top.
    func testFlatLibraryFromBeforeNestingStillOpens() throws {
        let id = UUID()
        let json = """
        {"documents": [], "folders": [{"createdAt": "2026-01-01T00:00:00Z", "id": "\(id)", "name": "Old"}]}
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("library.json"))
        let store = relaunchedStore()
        XCTAssertEqual(store.folders(in: nil).map(\.id), [id])
    }

    func testUnreadableLibraryIsSetAsideNotOverwritten() throws {
        let index = root.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: index)

        let store = CanvasStore(directory: root)
        XCTAssertTrue(store.documents.isEmpty)
        store.createNote(title: "New", in: nil)

        let kept = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("library.unreadable-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(kept[0])), Data("not json".utf8))
    }

    // MARK: Notes

    func testEveryKindOfEditIsSaved() throws {
        let store = CanvasStore(directory: root)
        let document = store.createNote(title: "Everything", in: nil)
        let model = CanvasModel(store: store, document: document)
        let first = try XCTUnwrap(model.content.pages.first?.id)

        model.canvasChanged(page: first, drawing: Self.drawing(strokes: 3))
        model.setBackground(.grid)
        let second = model.addPage(after: first)
        model.addImage(Self.pngData())
        let selection = try XCTUnwrap(model.selectedImage)
        let moved = CGRect(x: 40, y: 50, width: 200, height: 120)
        model.transformImage(selection, frame: moved, rotation: 0.5)
        model.addCard(AgentCard(kind: .atom, title: "Atom", frame: CGRect(x: 600, y: 100, width: 240, height: 200)),
                      to: second)
        model.saveNow()

        let reopened = CanvasModel(store: relaunchedStore(), document: document)
        let pages = reopened.content.pages
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0].drawing.strokes.count, 3)
        XCTAssertEqual(reopened.content.background, .grid)
        let image = try XCTUnwrap(pages[0].images.first)
        XCTAssertEqual(image.frame, moved)
        XCTAssertEqual(image.rotation, 0.5, accuracy: 0.0001)
        XCTAssertNotNil(reopened.image(named: image.fileName), "The image file is saved with the note")
        XCTAssertEqual(pages[1].cards.map(\.title), ["Atom"])
        XCTAssertFalse(reopened.content.history.isEmpty)
    }

    func testUndoneChangesAreSavedToo() throws {
        let store = CanvasStore(directory: root)
        let document = store.createNote(title: "Undo", in: nil)
        let model = CanvasModel(store: store, document: document)
        let page = try XCTUnwrap(model.content.pages.first?.id)
        model.canvasChanged(page: page, drawing: Self.drawing(strokes: 1))
        model.canvasChanged(page: page, drawing: Self.drawing(strokes: 2))
        model.undo()
        model.saveNow()

        let reopened = CanvasModel(store: relaunchedStore(), document: document)
        XCTAssertEqual(reopened.content.pages.first?.drawing.strokes.count, 1)
    }

    func testEditsSaveOnTheirOwnWithoutClosingTheNote() async throws {
        let store = CanvasStore(directory: root)
        let document = store.createNote(title: "Autosave", in: nil)
        let model = CanvasModel(store: store, document: document)
        let page = try XCTUnwrap(model.content.pages.first?.id)
        // The library keeps dates to the second, so edit in a later second than the note was made.
        try await Task.sleep(for: .seconds(1.1))
        model.canvasChanged(page: page, drawing: Self.drawing(strokes: 2))

        try await Task.sleep(for: .seconds(1.2))
        let reopened = CanvasModel(store: relaunchedStore(), document: document)
        XCTAssertEqual(reopened.content.pages.first?.drawing.strokes.count, 2)
        XCTAssertGreaterThan(try XCTUnwrap(relaunchedStore().document(document.id)).modifiedAt, document.modifiedAt)
    }

    func testImportedPDFMarkupIsSaved() throws {
        let store = CanvasStore(directory: root)
        let document = try store.importPDF(from: makePDF(pages: 3), title: "Handout", into: nil)
        let model = CanvasModel(store: store, document: document)
        XCTAssertEqual(model.content.pages.map(\.pdfPage), [0, 1, 2])
        let page = model.content.pages[1].id
        model.canvasChanged(page: page, drawing: Self.drawing(strokes: 4))
        model.saveNow()

        let reopened = CanvasModel(store: relaunchedStore(), document: document)
        XCTAssertEqual(reopened.content.pages.map(\.pdfPage), [0, 1, 2])
        XCTAssertEqual(reopened.content.pages[1].drawing.strokes.count, 4)
    }

    func testUnreadableNoteIsSetAsideNotOverwritten() throws {
        let store = CanvasStore(directory: root)
        let document = store.createNote(title: "Damaged", in: nil)
        let directory = try XCTUnwrap(store.noteDirectory(for: document.id))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: directory.appendingPathComponent("note.json"))

        let model = CanvasModel(store: store, document: document)
        model.saveNow()

        let kept = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("note.unreadable-") }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(kept[0])), Data("{ broken".utf8))
    }

    func testNotesSavedBeforeImagesRotatedStillOpen() throws {
        let placed = PlacedImage(fileName: "a.jpg", frame: CGRect(x: 1, y: 2, width: 3, height: 4), rotation: 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(placed)) as? [String: Any])
        json["rotation"] = nil
        let old = try JSONDecoder().decode(PlacedImage.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(old.rotation, 0)
        XCTAssertEqual(old.frame, placed.frame)
    }

    func testDeletedImageFilesAreCleanedUpWhenTheNoteOpens() throws {
        let store = CanvasStore(directory: root)
        let document = store.createNote(title: "Photos", in: nil)
        let model = CanvasModel(store: store, document: document)
        model.addImage(Self.pngData())
        let keep = try XCTUnwrap(model.content.pages.first?.images.first?.fileName)
        model.addImage(Self.pngData())
        let selection = try XCTUnwrap(model.selectedImage)
        let removed = try XCTUnwrap(model.placedImage(selection)?.fileName)
        model.deleteImage(selection)
        model.saveNow()

        _ = CanvasModel(store: relaunchedStore(), document: document)
        let directory = try XCTUnwrap(store.noteDirectory(for: document.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(keep).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(removed).path))
    }

    /// Pictures of visualizations are kept for the ones the note still has, and the rest go when it opens.
    func testVisualizationPicturesAreKeptOnlyForVisualizationsTheNoteHas() throws {
        let store = CanvasStore(directory: root)
        let document = store.createNote(title: "Waves", in: nil)
        let file = NoteFile(directory: store.noteDirectory(for: document.id))
        let kept = Visualization(title: "Wave", html: "<p>wave</p>")
        var content = file.load()
        content.visualizations = [kept]
        XCTAssertTrue(file.save(content))
        let gone = UUID()
        file.saveVisualizationImage(Self.pngData(), for: kept.id)
        file.saveVisualizationImage(Self.pngData(), for: gone)
        XCTAssertNotNil(file.visualizationImage(gone))

        _ = CanvasModel(store: relaunchedStore(), document: document)
        XCTAssertNotNil(file.visualizationImage(kept.id))
        XCTAssertNil(file.visualizationImage(gone))
    }

    // MARK: Tools and settings

    func testToolsAndColoursCarryOver() {
        let keys = [ToolPalette.toolKey, ToolPalette.eraserKey, "palette.pen", "palette.highlighter",
                    "palette.selectedPen", "palette.selectedHighlighter"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }

        let palette = ToolPalette()
        palette.tool = .highlighter
        palette.add(.highlighter(from: .systemPink))
        let added = palette.selectedSwatchID
        palette.eraserMode = .pixel

        let next = ToolPalette()
        XCTAssertEqual(next.tool, .highlighter)
        XCTAssertEqual(next.eraserMode, .pixel)
        XCTAssertEqual(next.selectedSwatchID, added)
        XCTAssertEqual(next.swatches.count, palette.swatches.count)
    }

    func testAPIKeysAreKeptInTheKeychain() {
        let account = "tests-\(UUID().uuidString)"
        defer { Keychain.delete(account) }
        Keychain.save("  sk-test-123  ", for: account)
        XCTAssertEqual(Keychain.read(account), "sk-test-123")
        Keychain.save("sk-test-456", for: account)
        XCTAssertEqual(Keychain.read(account), "sk-test-456")
        Keychain.save("", for: account)
        XCTAssertNil(Keychain.read(account), "Clearing the field removes the key")
    }

    // MARK: Helpers

    private static func drawing(strokes count: Int) -> PKDrawing {
        PKDrawing(strokes: (0..<count).map { n in
            let points = (0..<8).map { i in
                PKStrokePoint(location: CGPoint(x: 100 + Double(i) * 12, y: 100 + Double(n) * 30),
                              timeOffset: Double(i) * 0.01, size: CGSize(width: 3, height: 3), opacity: 1,
                              force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: .now))
        })
    }

    private static func pngData() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    private func makePDF(pages: Int) throws -> URL {
        let url = root.appendingPathComponent("source-\(UUID().uuidString).pdf")
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            for _ in 0..<pages { context.beginPage() }
        }
        try data.write(to: url)
        return url
    }
}
