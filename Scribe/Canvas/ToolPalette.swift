import PencilKit
import SwiftUI
import UIKit

enum CanvasTool: String, CaseIterable, Identifiable {
    case pen, highlighter, eraser, lasso

    var id: Self { self }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        case .lasso: "Lasso"
        }
    }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        case .lasso: "lasso"
        }
    }

    /// Pen and highlighter show colour swatches in the tool bar.
    var hasSwatches: Bool { self == .pen || self == .highlighter }
}

enum EraserMode: String, CaseIterable, Identifiable {
    case stroke, pixel

    var id: Self { self }

    var title: String {
        switch self {
        case .stroke: "Stroke Eraser"
        case .pixel: "Pixel Eraser"
        }
    }
}

/// One colour in a tool's swatch list. For the highlighter, the swatch is a light colour and the ink a saturated,
/// see-through one.
struct InkSwatch: Codable, Identifiable, Hashable {
    var id = UUID()
    var swatchHex: String
    var inkHex: String
    var inkAlpha: Double = 1

    var swatch: Color { Color(uiColor: UIColor(hex: swatchHex)) }
    var inkColor: UIColor { UIColor(hex: inkHex).withAlphaComponent(inkAlpha) }

    static func pen(_ hex: String) -> InkSwatch { InkSwatch(swatchHex: hex, inkHex: hex) }

    /// A highlighter swatch from any colour: the swatch is that colour, the ink a saturated version at low alpha.
    static func highlighter(from color: UIColor) -> InkSwatch {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let ink = UIColor(hue: h, saturation: max(s, 0.75), brightness: 1, alpha: 1)
        return InkSwatch(swatchHex: color.hex, inkHex: ink.hex, inkAlpha: 0.38)
    }

    static let penDefaults: [InkSwatch] = [.pen("#1C1C1E"), .pen("#007AFF"), .pen("#FF3B30")]
    static let highlighterDefaults: [InkSwatch] = [
        InkSwatch(swatchHex: "#FFF3A3", inkHex: "#FFD60A", inkAlpha: 0.40),
        InkSwatch(swatchHex: "#C9F2D2", inkHex: "#34C759", inkAlpha: 0.32),
        InkSwatch(swatchHex: "#CFE5FF", inkHex: "#0A84FF", inkAlpha: 0.26),
    ]
}

/// The tool, the eraser mode, and each inking tool's colours. Colours persist per tool, app-wide.
@MainActor @Observable
final class ToolPalette {
    /// The tool and eraser mode carry over to the next launch, like the colours.
    var tool: CanvasTool { didSet { UserDefaults.standard.set(tool.rawValue, forKey: Self.toolKey) } }
    var eraserMode: EraserMode { didSet { UserDefaults.standard.set(eraserMode.rawValue, forKey: Self.eraserKey) } }

    private(set) var penSwatches: [InkSwatch] { didSet { Self.save(penSwatches, Self.penKey) } }
    private(set) var highlighterSwatches: [InkSwatch] { didSet { Self.save(highlighterSwatches, Self.highlighterKey) } }
    private var selectedPen: UUID? { didSet { Self.saveID(selectedPen, Self.selectedPenKey) } }
    private var selectedHighlighter: UUID? { didSet { Self.saveID(selectedHighlighter, Self.selectedHighlighterKey) } }

    static let toolKey = "palette.tool"
    static let eraserKey = "palette.eraserMode"
    private static let penKey = "palette.pen"
    private static let highlighterKey = "palette.highlighter"
    private static let selectedPenKey = "palette.selectedPen"
    private static let selectedHighlighterKey = "palette.selectedHighlighter"

    init() {
        tool = UserDefaults.standard.string(forKey: Self.toolKey).flatMap(CanvasTool.init(rawValue:)) ?? .pen
        eraserMode = UserDefaults.standard.string(forKey: Self.eraserKey).flatMap(EraserMode.init(rawValue:)) ?? .stroke
        let pens = Self.load(Self.penKey) ?? InkSwatch.penDefaults
        let highlighters = Self.load(Self.highlighterKey) ?? InkSwatch.highlighterDefaults
        penSwatches = pens
        highlighterSwatches = highlighters
        selectedPen = Self.loadID(Self.selectedPenKey).flatMap { id in pens.contains { $0.id == id } ? id : nil }
            ?? pens.first?.id
        selectedHighlighter = Self.loadID(Self.selectedHighlighterKey)
            .flatMap { id in highlighters.contains { $0.id == id } ? id : nil } ?? highlighters.first?.id
        // Save now so the default swatches keep their IDs (and the selection) across launches.
        Self.save(penSwatches, Self.penKey)
        Self.save(highlighterSwatches, Self.highlighterKey)
        Self.saveID(selectedPen, Self.selectedPenKey)
        Self.saveID(selectedHighlighter, Self.selectedHighlighterKey)
    }

    // MARK: The active tool's swatches

    private var isHighlighter: Bool { tool == .highlighter }

    var swatches: [InkSwatch] { isHighlighter ? highlighterSwatches : penSwatches }
    var selectedSwatchID: UUID? { isHighlighter ? selectedHighlighter : selectedPen }
    var canRemoveSwatch: Bool { swatches.count > 1 }

    /// A new swatch for the active tool from any colour.
    func swatch(from color: UIColor) -> InkSwatch {
        isHighlighter ? .highlighter(from: color) : .pen(color.hex)
    }

    func select(_ swatch: InkSwatch) {
        if isHighlighter { selectedHighlighter = swatch.id } else { selectedPen = swatch.id }
    }

    func add(_ swatch: InkSwatch) {
        if isHighlighter {
            highlighterSwatches.append(swatch)
            selectedHighlighter = swatch.id
        } else {
            penSwatches.append(swatch)
            selectedPen = swatch.id
        }
    }

    /// Always keeps at least one swatch.
    func remove(_ swatch: InkSwatch) {
        if isHighlighter {
            guard highlighterSwatches.count > 1 else { return }
            highlighterSwatches.removeAll { $0.id == swatch.id }
            if selectedHighlighter == swatch.id { selectedHighlighter = highlighterSwatches.first?.id }
        } else {
            guard penSwatches.count > 1 else { return }
            penSwatches.removeAll { $0.id == swatch.id }
            if selectedPen == swatch.id { selectedPen = penSwatches.first?.id }
        }
    }

    /// Gives the swatch `id` a new colour, keeping its place and selection.
    func replace(_ id: UUID, with new: InkSwatch) {
        var new = new
        new.id = id
        if let i = highlighterSwatches.firstIndex(where: { $0.id == id }) { highlighterSwatches[i] = new }
        if let i = penSwatches.firstIndex(where: { $0.id == id }) { penSwatches[i] = new }
    }

    // MARK: PencilKit

    private var activeSwatch: InkSwatch {
        swatches.first { $0.id == selectedSwatchID } ?? swatches.first ?? .pen("#1C1C1E")
    }

    var pencilKitTool: PKTool {
        switch tool {
        case .pen: PKInkingTool(.pen, color: activeSwatch.inkColor, width: 3)
        case .highlighter: PKInkingTool(.marker, color: activeSwatch.inkColor, width: 22)
        case .eraser: PKEraserTool(eraserMode == .stroke ? .vector : .bitmap)
        case .lasso: PKLassoTool()
        }
    }

    // MARK: Saving

    private static func save(_ list: [InkSwatch], _ key: String) {
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func load(_ key: String) -> [InkSwatch]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([InkSwatch].self, from: data), !list.isEmpty else { return nil }
        return list
    }

    private static func saveID(_ id: UUID?, _ key: String) { UserDefaults.standard.set(id?.uuidString, forKey: key) }

    private static func loadID(_ key: String) -> UUID? {
        UserDefaults.standard.string(forKey: key).flatMap(UUID.init)
    }
}
