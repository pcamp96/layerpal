import Foundation

// Spool label printing. Shapes and limits match the Bambuddy 1.3.0 label and label-template
// endpoints; the server rejects anything outside them.

/// A sheet of identical labels in a grid. Lengths are millimetres.
struct SheetLayout: Codable, Hashable {
    var page: String = "a4"
    var labelWMm = 70.0
    var labelHMm = 36.0
    var cols = 3
    var rows = 8
    var topMm = 10.0
    var leftMm = 0.0
    var colGapMm = 0.0
    var rowGapMm = 0.0

    static let minWidth = 40.0, minHeight = 20.0, maxLength = 300.0, maxCols = 20, maxRows = 40
    static let pageSizesMm: [String: (w: Double, h: Double)] = ["a4": (210, 297), "letter": (215.9, 279.4)]

    var capacity: Int { cols * rows }

    private enum Keys: String, CodingKey {
        case page, cols, rows
        case labelWMm = "label_w_mm", labelHMm = "label_h_mm", topMm = "top_mm", leftMm = "left_mm"
        case colGapMm = "col_gap_mm", rowGapMm = "row_gap_mm"
    }

    init() {}

    init(from decoder: Decoder) throws {
        // The shared decoder converts snake_case to camelCase before it looks keys up, so read the camelCase names.
        let c = try decoder.container(keyedBy: DecodeKeys.self)
        page = try c.decode(String.self, forKey: .page)
        labelWMm = try c.decode(Double.self, forKey: .labelWMm)
        labelHMm = try c.decode(Double.self, forKey: .labelHMm)
        cols = try c.decode(Int.self, forKey: .cols)
        rows = try c.decode(Int.self, forKey: .rows)
        topMm = try c.decode(Double.self, forKey: .topMm)
        leftMm = try c.decode(Double.self, forKey: .leftMm)
        colGapMm = try c.decodeIfPresent(Double.self, forKey: .colGapMm) ?? 0
        rowGapMm = try c.decodeIfPresent(Double.self, forKey: .rowGapMm) ?? 0
    }

    private enum DecodeKeys: String, CodingKey { case page, labelWMm, labelHMm, cols, rows, topMm, leftMm, colGapMm, rowGapMm }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(page, forKey: .page)
        try c.encode(labelWMm, forKey: .labelWMm)
        try c.encode(labelHMm, forKey: .labelHMm)
        try c.encode(cols, forKey: .cols)
        try c.encode(rows, forKey: .rows)
        try c.encode(topMm, forKey: .topMm)
        try c.encode(leftMm, forKey: .leftMm)
        try c.encode(colGapMm, forKey: .colGapMm)
        try c.encode(rowGapMm, forKey: .rowGapMm)
    }

    /// Why this layout can't be printed, or nil. The same checks as the server.
    var problem: String? {
        guard let size = Self.pageSizesMm[page] else { return "Unknown page size." }
        if labelWMm < Self.minWidth || labelHMm < Self.minHeight { return "Labels must be at least 40 mm wide and 20 mm tall." }
        if max(labelWMm, labelHMm, topMm, leftMm, colGapMm, rowGapMm) > Self.maxLength { return "Sizes, margins and gaps can be at most 300 mm." }
        if !(1 ... Self.maxCols).contains(cols) { return "Columns must be between 1 and 20." }
        if !(1 ... Self.maxRows).contains(rows) { return "Rows must be between 1 and 40." }
        if min(topMm, leftMm, colGapMm, rowGapMm) < 0 { return "Margins and gaps must not be negative." }
        let gridW = leftMm + Double(cols) * labelWMm + Double(cols - 1) * colGapMm
        let gridH = topMm + Double(rows) * labelHMm + Double(rows - 1) * rowGapMm
        if gridW > size.w + 0.01 { return String(format: "The labels are %.2f mm wide with the left margin, but the page is %.1f mm.", gridW, size.w) }
        if gridH > size.h + 0.01 { return String(format: "The labels are %.2f mm tall with the top margin, but the page is %.1f mm.", gridH, size.h) }
        return nil
    }
}

struct LabelTemplate: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let layout: SheetLayout
}

/// The built-in label sizes (template names the label endpoints accept).
struct BuiltInLabel: Identifiable, Hashable {
    let id: String
    let title: String
    /// Labels per sheet; nil for a one-label-per-page roll/box label.
    let capacity: Int?

    static let all: [BuiltInLabel] = [
        BuiltInLabel(id: "ams_holder_74x33", title: "AMS holder, 74 × 33 mm", capacity: nil),
        BuiltInLabel(id: "ams_holder_75x55", title: "AMS holder, 75 × 55 mm", capacity: nil),
        BuiltInLabel(id: "box_40x30", title: "Box, 40 × 30 mm", capacity: nil),
        BuiltInLabel(id: "box_62x29", title: "Box, 62 × 29 mm", capacity: nil),
        BuiltInLabel(id: "avery_5160", title: "Avery 5160, Letter (30 per sheet)", capacity: 30),
        BuiltInLabel(id: "avery_l7160", title: "Avery L7160, A4 (21 per sheet)", capacity: 21),
    ]
}

/// A label line the picker can switch on (field names the label endpoints accept), in print order.
struct LabelFieldOption: Identifiable {
    let id: String
    let title: String

    static let all: [LabelFieldOption] = [
        LabelFieldOption(id: "brand", title: "Brand"), LabelFieldOption(id: "material", title: "Material"),
        LabelFieldOption(id: "hex", title: "Color code"), LabelFieldOption(id: "name", title: "Color name"),
        LabelFieldOption(id: "location", title: "Storage location"), LabelFieldOption(id: "material_number", title: "Material number"),
        LabelFieldOption(id: "temps", title: "Nozzle temperatures"), LabelFieldOption(id: "weight", title: "Weight"),
        LabelFieldOption(id: "note", title: "Note"), LabelFieldOption(id: "added", title: "Date added"),
        LabelFieldOption(id: "qr", title: "QR code"), LabelFieldOption(id: "spool_id", title: "Spool number"),
    ]

    /// What labels carried before the lines were selectable (DEFAULT_LABEL_FIELDS).
    static let defaults: Set<String> = ["brand", "material", "hex", "name", "location", "qr", "spool_id"]
}

/// POST /inventory/labels body (LabelRequest). `layout` goes with template "custom" and only then.
struct LabelRequest: Encodable {
    var spoolIds: [Int]
    var template: String
    var layout: SheetLayout?
    var monochrome: Bool
    var fields: [String]?
    var startingPosition: Int
    var format: String
    var dpi: Int
}

/// POST /inventory/labels/preview body (LabelPreviewRequest).
struct LabelPreviewRequest: Encodable {
    var spoolId: Int
    var template: String
    var layout: SheetLayout?
    var monochrome: Bool
    var fields: [String]?
}
