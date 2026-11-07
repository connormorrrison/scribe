import PencilKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pages panel

/// Every page as a thumbnail: tap to jump to it, touch and hold to duplicate or delete.
struct PagesPanel: View {
    let model: CanvasModel
    let background: PageBackground
    let jump: (UUID) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 20) {
                    ForEach(Array(model.content.pages.enumerated()), id: \.element.id) { index, page in
                        Button { jump(page.id) } label: {
                            VStack(spacing: 8) {
                                PageThumbnail(model: model, page: page, background: background)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                                            .stroke(page.id == model.currentPageID ? Color.accentColor : .clear,
                                                    lineWidth: 3)
                                    }
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Duplicate", systemImage: "plus.rectangle.on.rectangle") {
                                model.duplicatePage(page.id)
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                model.deletePage(page.id)
                            }
                            .disabled(model.content.pages.count <= 1)
                        }
                        .accessibilityLabel("Page \(index + 1)")
                    }
                }
                .padding(20)
            }
            .roundedTitle("Pages", inline: true)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Page", systemImage: "plus") {
                        jump(model.addPage(after: model.content.pages.last?.id))
                    }
                }
            }
        }
    }
}

/// A small picture of a page, with its photos, ink and cards.
struct PageThumbnail: View {
    let model: CanvasModel
    let page: NotePage
    let background: PageBackground
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let k = geo.size.width / NotePageMetrics.width
            ZStack(alignment: .topLeading) {
                Color.white
                PageBackgroundView(style: background, regions: [CGRect(origin: .zero, size: geo.size)],
                                   spacing: NotePageMetrics.backgroundSpacing * k)
                ForEach(page.images) { placed in
                    if let image = model.image(named: placed.fileName) {
                        Image(uiImage: image).resizable()
                            .frame(width: placed.frame.width * k, height: placed.frame.height * k)
                            .offset(x: placed.frame.minX * k, y: placed.frame.minY * k)
                    }
                }
                ForEach(page.cards) { card in
                    RoundedRectangle(cornerRadius: 16 * k, style: .continuous)
                        .fill(Landing.card)
                        .frame(width: card.frame.width * k, height: card.frame.height * k)
                        .offset(x: card.frame.minX * k, y: card.frame.minY * k)
                }
                Image(uiImage: lightImage(page.agentDrawing, bounds: page.bounds, scale: k * displayScale)).resizable()
                Image(uiImage: lightImage(page.drawing, bounds: page.bounds, scale: k * displayScale)).resizable()
            }
        }
        .aspectRatio(NotePageMetrics.width / page.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
    }
}

// MARK: - History

struct HistorySheet: View {
    let entries: [HistoryEntry]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView("No History Yet", systemImage: "clock.arrow.circlepath",
                                           description: Text("What you and the agent do in this note shows up here."))
                } else {
                    List(entries.reversed()) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: entry.author == .agent ? "sparkles" : "person.fill")
                                .foregroundStyle(entry.author == .agent ? Landing.blue : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text)
                                Text(entry.date, format: .relative(presentation: .named))
                                    .font(.system(size: 13, weight: .regular, design: .rounded))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .roundedTitle("History", inline: true)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
    }
}

// MARK: - Colour picker

/// The system colour picker; every pick is applied straight away.
struct ColourPickerSheet: UIViewControllerRepresentable {
    let initial: UIColor
    let picked: (UIColor) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.selectedColor = initial
        picker.supportsAlpha = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIColorPickerViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var parent: ColourPickerSheet
        init(parent: ColourPickerSheet) { self.parent = parent }

        func colorPickerViewController(_ picker: UIColorPickerViewController, didSelect color: UIColor,
                                       continuously: Bool) {
            guard !continuously else { return }
            parent.picked(color)
        }

        func colorPickerViewControllerDidFinish(_ picker: UIColorPickerViewController) {
            parent.dismiss()
        }
    }
}

// MARK: - Share

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Enlarged card

struct EnlargedCard: View {
    let model: CanvasModel
    let card: AgentCard
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width - 64, (geo.size.height - 64) * card.frame.width / card.frame.height)
            let size = CGSize(width: side, height: side * card.frame.height / card.frame.width)
            CardFace(card: card, clock: model.clock(for: card.id), artScale: size.width / card.designWidth) {
                Button("Close", systemImage: "arrow.down.right.and.arrow.up.left") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(0.14), in: Circle())
                    .buttonStyle(.plain)
            }
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                if card.isAnimated {
                    let playing = model.clock(for: card.id)?.isPlaying ?? false
                    HStack(spacing: 8) {
                        Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") {
                            model.togglePlay(card.id)
                        }
                        Button("Stop", systemImage: "stop.fill") { model.stopAnimation(card.id) }
                    }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .background(Color.black.opacity(0.85).ignoresSafeArea())
    }
}

// MARK: - PDF

struct PDFFile: FileDocument {
    static let readableContentTypes: [UTType] = [.pdf]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Renders a note as a PDF, one PDF page per note page.
@MainActor
enum NotePDF {
    static func data(for model: CanvasModel, background: PageBackground) -> Data {
        let first = model.content.pages.first?.bounds ?? CGRect(x: 0, y: 0, width: NotePageMetrics.width,
                                                                height: NotePageMetrics.height)
        let renderer = UIGraphicsPDFRenderer(bounds: first)
        return renderer.pdfData { context in
            for page in model.content.pages {
                let rect = page.bounds
                context.beginPage(withBounds: rect, pageInfo: [:])
                UIColor.white.setFill()
                UIRectFill(rect)

                let paper = ImageRenderer(content:
                    PageBackgroundView(style: background, regions: [rect], spacing: NotePageMetrics.backgroundSpacing)
                        .frame(width: rect.width, height: rect.height))
                paper.scale = 2
                paper.uiImage?.draw(in: rect)

                for placed in page.images {
                    model.image(named: placed.fileName)?.draw(in: placed.frame)
                }
                lightImage(page.agentDrawing, bounds: rect, scale: 2).draw(in: rect)
                lightImage(page.drawing, bounds: rect, scale: 2).draw(in: rect)

                for card in page.cards {
                    let face = ImageRenderer(content:
                        CardFace(card: card, clock: model.clock(for: card.id), artScale: card.frame.width / card.designWidth)
                            .frame(width: card.frame.width, height: card.frame.height))
                    face.scale = 2
                    face.uiImage?.draw(in: card.frame)
                }
            }
        }
    }
}
