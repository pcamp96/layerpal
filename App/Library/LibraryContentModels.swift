import Foundation

// Variant groups and folder README. Shapes match the Bambuddy 1.3.0 library responses.

/// GET /library/folders/{id}/readme: the first markdown file in the folder.
struct FolderReadme: Decodable {
    let filename: String
    let content: String
    let truncated: Bool
}

struct VariantMember: Decodable, Identifiable {
    let libraryFileId: Int
    let filename: String
    /// The printer model the file was sliced for ("H2S", "X1C"...), read from the file itself.
    let targetModel: String
    let position: Int

    var id: Int { libraryFileId }
    var modelName: String { targetModel.isEmpty ? "Unknown model" : (Printer.modelNames[targetModel] ?? targetModel) }
}

/// One job sliced several times, one file per printer model, in priority order.
struct VariantGroup: Decodable, Identifiable {
    let id: Int
    let name: String
    let members: [VariantMember]
}
