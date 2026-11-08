import Foundation

/// Models for the File Manager (phase 2B). Shapes match the Bambuddy 1.3.0 library,
/// library-trash and MakerWorld responses.

/// A JSON value of unknown shape (3MF metadata, MakerWorld design/instances).
enum LibJSON: Decodable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case object([String: LibJSON])
    case array([LibJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([String: LibJSON].self) {
            self = .object(v)
        } else if let v = try? c.decode([LibJSON].self) {
            self = .array(v)
        } else {
            self = .null
        }
    }

    var string: String? {
        switch self {
        case let .string(v): v.isEmpty ? nil : v
        case let .int(v): String(v)
        case let .double(v): String(v)
        default: nil
        }
    }

    var double: Double? {
        switch self {
        case let .double(v): v
        case let .int(v): Double(v)
        case let .string(v): Double(v)
        default: nil
        }
    }

    var bool: Bool? { if case let .bool(v) = self { v } else { nil } }
    var object: [String: LibJSON]? { if case let .object(v) = self { v } else { nil } }
}

extension Dictionary where Key == String, Value == LibJSON {
    func str(_ key: String) -> String? { self[key]?.string }
    func num(_ key: String) -> Double? { self[key]?.double }
}

// MARK: Folders

/// GET /library/folders: a tree of FolderTreeItem.
struct LibFolderNode: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let parentId: Int?
    let fileCount: Int?
    let isExternal: Bool?
    let externalReadonly: Bool?
    let projectId: Int?
    let projectName: String?
    let archiveId: Int?
    let archiveName: String?
    let canWrite: Bool?
    let canRename: Bool?
    let canDelete: Bool?
    let children: [LibFolderNode]?

    var kids: [LibFolderNode] { children ?? [] }
    var isReadonlyExternal: Bool { isExternal == true && externalReadonly == true }

    /// This node and every descendant, depth first.
    var flattened: [LibFolderNode] { [self] + kids.flatMap(\.flattened) }

    func find(_ id: Int) -> LibFolderNode? {
        if self.id == id { return self }
        for k in kids { if let hit = k.find(id) { return hit } }
        return nil
    }
}

extension Array where Element == LibFolderNode {
    func find(_ id: Int) -> LibFolderNode? {
        for n in self { if let hit = n.find(id) { return hit } }
        return nil
    }

    var flattened: [LibFolderNode] { flatMap(\.flattened) }
}

// MARK: Files

struct LibTagRef: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
}

/// GET /library/tags
struct LibTag: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let fileCount: Int?
}

/// GET /library/files (FileListResponse).
struct LibFileItem: Decodable, Identifiable, Hashable {
    let id: Int
    let folderId: Int?
    let isExternal: Bool?
    let filename: String
    let fileType: String?
    let fileSize: Int?
    let thumbnailPath: String?
    let printCount: Int?
    let createdById: Int?
    let createdByUsername: String?
    let createdAt: Date?
    let fsModifiedAt: Date?
    let printTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let slicedForModel: String?
    let tags: [LibTagRef]?
    let variantCount: Int?
    let variantGroupId: Int?
    let hasNotes: Bool?
    let photoCount: Int?

    /// Sorted by modified date, else added date.
    var date: Date { fsModifiedAt ?? createdAt ?? .distantPast }

    /// Sliced and printable: the server's `file_type` is `gcode.3mf` or `gcode`.
    var isSliced: Bool {
        let type = (fileType ?? "").lowercased()
        return type == "gcode.3mf" || type == "gcode" || filename.lowercased().contains(".gcode")
    }

    var thumbnailAPIPath: String { "library/files/\(id)/thumbnail" }
}

/// GET /library/files/{id} (FileResponse).
struct LibFileDetail: Decodable, Identifiable {
    let id: Int
    let folderId: Int?
    let folderName: String?
    let projectName: String?
    let filename: String
    let fileType: String?
    let fileSize: Int?
    let metadata: [String: LibJSON]?
    let printCount: Int?
    let lastPrintedAt: Date?
    let notes: String?
    let externalUrl: String?
    let sourceUrl: String?
    let duplicateCount: Int?
    let createdById: Int?
    let createdByUsername: String?
    let createdAt: Date?
    let printTimeSeconds: Int?
    let filamentUsedGrams: Double?
    let slicedForModel: String?
}

/// GET /library/files/{id}/plates
struct LibPlatesResponse: Decodable {
    let plates: [LibPlate]
}

struct LibPlate: Decodable, Identifiable, Hashable {
    let index: Int
    let name: String?
    let objects: [String]?
    let hasThumbnail: Bool?
    let printTimeSeconds: Double?
    let filamentUsedGrams: Double?

    var id: Int { index }
    var title: String { name?.isEmpty == false ? name! : "Plate \(index)" }
}

/// POST /library/files (FileUploadResponse).
struct LibUploadResult: Decodable {
    let id: Int
    let filename: String
    let duplicateOf: Int?
}

// MARK: Trash

struct LibTrashFile: Decodable, Identifiable, Hashable {
    let id: Int
    let filename: String
    let fileSize: Int?
    let thumbnailPath: String?
    let folderName: String?
    let createdByUsername: String?
    let deletedAt: Date?
    let autoPurgeAt: Date?
}

struct LibTrashPage: Decodable {
    let items: [LibTrashFile]
    let total: Int
    let retentionDays: Int?
}

/// DELETE /library/files/{id}
struct LibDeleteResult: Decodable {
    let trashed: Bool?
}

// MARK: MakerWorld

struct MWStatus: Decodable {
    let hasCloudToken: Bool
    let canDownload: Bool
    let signInExpired: Bool?
}

/// POST /makerworld/resolve. `design` and `instances` pass MakerWorld's JSON through verbatim.
struct MWResolved: Decodable {
    let modelId: Int
    let profileId: Int?
    let design: [String: LibJSON]
    let instances: [[String: LibJSON]]
    let alreadyImportedLibraryIds: [Int]?
}

struct MWPlate: Identifiable, Hashable {
    let instanceId: Int
    let profileId: Int?
    let title: String?
    let cover: String?
    let materialCount: Int?
    let needsAms: Bool
    let primaryPrinter: String?

    var id: Int { instanceId }

    init?(_ json: [String: LibJSON]) {
        guard let id = json.num("id").map({ Int($0) }) else { return nil }
        instanceId = id
        profileId = json.num("profileId").map { Int($0) }
        title = json.str("title")
        cover = json.str("cover")
        materialCount = json.num("materialCnt").map { Int($0) }
        needsAms = json["needAms"]?.bool == true
        primaryPrinter = json["compatibility"]?.object?.str("devProductName")
    }
}

struct MWImportResult: Decodable {
    let libraryFileId: Int
    let filename: String
    let folderId: Int?
    let profileId: Int?
    let wasExisting: Bool
}

struct MWRecentImport: Decodable, Identifiable, Hashable {
    let libraryFileId: Int
    let filename: String
    let folderId: Int?
    let sourceUrl: String?
    let createdAt: String?

    var id: Int { libraryFileId }
}
