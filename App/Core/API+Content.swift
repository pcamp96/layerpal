import Foundation

/// Phase 4B endpoints: archive merge/compare/calendar/export, project templates/queue/BOM,
/// library variant groups, README and folder links, filament catalog, suppliers, forecast,
/// usage history, CSV, bulk spool actions and spool labels (Bambuddy 1.3.0). Reads need the
/// matching `*:read` permission; each write is noted per call.
extension APIClient {
    // MARK: Downloads

    /// Fetches a file (CSV export, label PDF/PNG) with the app's key and saves it in a fresh
    /// temp folder under the server's filename, ready for a share sheet or AirPrint.
    func downloadFile(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Encodable? = nil,
                      fallbackName: String, timeout: TimeInterval = 120) async throws -> URL {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var url = base.appending(path: "api/v1/" + path)
        if !query.isEmpty { url.append(queryItems: query) }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        ServerConfig.authorize(&request)
        if let body {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try encoder.encode(body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        var name = fallbackName
        if let disposition = http?.value(forHTTPHeaderField: "Content-Disposition"),
           let range = disposition.range(of: #"filename="?([^";]+)"?"#, options: .regularExpression) {
            let raw = String(disposition[range]).replacingOccurrences(of: "filename=", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let safe = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_")
            if !safe.isEmpty { name = safe }
        }
        let folder = FileManager.default.temporaryDirectory.appending(path: "layerpal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dest = folder.appending(path: name)
        try data.write(to: dest)
        return dest
    }

    // MARK: Archives: merge (archives:update_all AND archives:delete_all)

    /// GET /archives/merge-count: how many groups of duplicate archives exist.
    func archiveMergeCount() async throws -> Int {
        let r: MergeCountResponse = try await get("archives/merge-count")
        return r.groups
    }

    /// GET /archives/merge-preview: each group's oldest archive (survivor) and the ones merged into it.
    func archiveMergePreview() async throws -> [MergeGroup] {
        let r: MergePreviewResponse = try await get("archives/merge-preview")
        return r.groups
    }

    /// POST /archives/merge {survivor_ids} (1...500).
    func mergeArchives(survivorIds: [Int]) async throws -> MergeOutcome {
        struct Body: Encodable { let survivorIds: [Int] }
        return try decoder().decode(MergeOutcome.self, from: try await request("archives/merge", method: "POST", body: Body(survivorIds: survivorIds)))
    }

    // MARK: Archives: compare (archives:read_*)

    /// GET /archives/compare?archive_ids=1,2,3 (2 to 5 archives).
    func compareArchives(_ ids: [Int]) async throws -> ArchiveComparison {
        try await get("archives/compare", query: [URLQueryItem(name: "archive_ids", value: ids.map(String.init).joined(separator: ","))])
    }

    // MARK: Archives: calendar (archives:read_*)

    /// GET /archives/prints?date_from&date_to&tz&printer_id&limit&offset (limit 1...1000).
    func archivePrints(from: String, to: String, printerId: Int?, limit: Int = 500, offset: Int = 0) async throws -> PrintLogPage {
        var query = [URLQueryItem(name: "date_from", value: from), URLQueryItem(name: "date_to", value: to),
                     URLQueryItem(name: "tz", value: TimeZone.current.identifier),
                     URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        if let printerId { query.append(URLQueryItem(name: "printer_id", value: String(printerId))) }
        return try await get("archives/prints", query: query)
    }

    // MARK: Archives: export (archives:read_*; stats:read for the statistics file)

    /// GET /archives/export?format=csv|xlsx with the same filters as the archive list.
    func exportArchives(format: String, status: String?, printerId: Int?, projectId: Int?, search: String?,
                        dateFrom: String?, dateTo: String?) async throws -> URL {
        var query = [URLQueryItem(name: "format", value: format), URLQueryItem(name: "tz", value: TimeZone.current.identifier)]
        if let status { query.append(URLQueryItem(name: "status", value: status)) }
        if let printerId { query.append(URLQueryItem(name: "printer_id", value: String(printerId))) }
        if let projectId { query.append(URLQueryItem(name: "project_id", value: String(projectId))) }
        if let search, !search.isEmpty { query.append(URLQueryItem(name: "search", value: search)) }
        if let dateFrom { query.append(URLQueryItem(name: "date_from", value: dateFrom)) }
        if let dateTo { query.append(URLQueryItem(name: "date_to", value: dateTo)) }
        return try await downloadFile("archives/export", query: query, fallbackName: "archives.\(format)")
    }

    /// GET /archives/stats/export?format=&days= (stats:read).
    func exportStats(format: String, days: Int) async throws -> URL {
        try await downloadFile("archives/stats/export", query: [URLQueryItem(name: "format", value: format),
                                                                 URLQueryItem(name: "days", value: String(days))],
                               fallbackName: "statistics.\(format)")
    }

    // MARK: Projects: templates (projects:read to list, projects:create to use)

    /// GET /projects/templates.
    func projectTemplates() async throws -> [Project] { try await get("projects/templates") }

    /// POST /projects/from-template/{id}?name= (projects:create; API key needs can_manage_projects).
    func createProject(fromTemplate id: Int, name: String?) async throws -> Project {
        let query = (name?.isEmpty == false) ? [URLQueryItem(name: "name", value: name)] : []
        return try decoder().decode(Project.self, from: try await request("projects/from-template/\(id)", method: "POST", query: query))
    }

    /// POST /projects/{id}/create-template (projects:create): copies the project and its BOM into a "(Template)" project.
    func createTemplate(fromProject id: Int) async throws -> Project {
        try decoder().decode(Project.self, from: try await request("projects/\(id)/create-template", method: "POST"))
    }

    // MARK: Projects: queue, progress, timeline, BOM

    /// GET /projects/{id}/queue (projects:read; only items the caller may see in the queue).
    func projectQueue(_ id: Int) async throws -> [ProjectQueueEntry] { try await get("projects/\(id)/queue") }

    /// GET /projects/{id}/file-progress: completed runs per library file in the project's linked folders.
    func projectFileProgress(_ id: Int) async throws -> [ProjectFileProgress] { try await get("projects/\(id)/file-progress") }

    /// GET /projects/{id}/timeline?limit= (projects:read).
    func projectTimeline(_ id: Int, limit: Int = 50) async throws -> [ProjectTimelineEvent] {
        try await get("projects/\(id)/timeline", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    /// GET /projects/{id}/bom (projects:read).
    func projectBOM(_ id: Int) async throws -> [BOMItem] { try await get("projects/\(id)/bom") }

    /// POST /projects/{id}/bom (projects:update; API key needs can_manage_projects).
    func addBOMItem(_ projectId: Int, _ draft: BOMDraft) async throws -> BOMItem {
        struct Body: Encodable {
            let name: String
            let quantityNeeded: Int
            let unitPrice: Double?
            let sourcingUrl: String?
            let remarks: String?
        }
        let body = Body(name: draft.name, quantityNeeded: draft.quantityNeeded, unitPrice: draft.unitPriceValue,
                        sourcingUrl: draft.url.isEmpty ? nil : draft.url, remarks: draft.remarks.isEmpty ? nil : draft.remarks)
        return try decoder().decode(BOMItem.self, from: try await request("projects/\(projectId)/bom", method: "POST", body: body))
    }

    /// PATCH /projects/{id}/bom/{item} (projects:update). Send only what changed.
    func updateBOMItem(_ projectId: Int, _ itemId: Int, _ patch: LibPatch) async throws -> BOMItem {
        try decoder().decode(BOMItem.self, from: try await request("projects/\(projectId)/bom/\(itemId)", method: "PATCH", body: patch))
    }

    /// DELETE /projects/{id}/bom/{item} (projects:update).
    func deleteBOMItem(_ projectId: Int, _ itemId: Int) async throws {
        _ = try await request("projects/\(projectId)/bom/\(itemId)", method: "DELETE")
    }

    // MARK: Library: project folders and queueing files

    /// GET /library/folders/by-project/{id} (library:read_*).
    func libFolders(projectId: Int) async throws -> [LibFolderNode] { try await get("library/folders/by-project/\(projectId)") }

    /// GET /library/folders/by-archive/{id} (library:read_*).
    func libFolders(archiveId: Int) async throws -> [LibFolderNode] { try await get("library/folders/by-archive/\(archiveId)") }

    /// PUT /library/folders/{id} {project_id} (library:update_all; 0 unlinks).
    func libLinkFolder(_ id: Int, projectId: Int?) async throws {
        var patch = LibPatch()
        patch["project_id"] = .int(projectId ?? 0)
        _ = try await request("library/folders/\(id)", method: "PUT", body: patch)
    }

    /// PUT /library/folders/{id} {archive_id} (library:update_all; 0 unlinks).
    func libLinkFolder(_ id: Int, archiveId: Int?) async throws {
        var patch = LibPatch()
        patch["archive_id"] = .int(archiveId ?? 0)
        _ = try await request("library/folders/\(id)", method: "PUT", body: patch)
    }

    /// POST /library/files/add-to-queue {file_ids, printer_id | target_model} (queue:create). Sliced files only;
    /// a file in a project-linked folder takes that project, so the print counts toward its progress.
    func addLibraryFilesToQueue(ids: [Int], printerId: Int?, targetModel: String?) async throws -> AddFilesResult {
        struct Body: Encodable { let fileIds: [Int]; let printerId: Int?; let targetModel: String? }
        let body = Body(fileIds: ids, printerId: printerId, targetModel: printerId == nil ? targetModel : nil)
        return try decoder().decode(AddFilesResult.self, from: try await request("library/files/add-to-queue", method: "POST", body: body))
    }

    // MARK: Library: README (library:read_*)

    /// GET /library/folders/{id}/readme. 404 means the folder has no markdown file.
    func libFolderReadme(_ id: Int) async throws -> FolderReadme? {
        do {
            return try await get("library/folders/\(id)/readme")
        } catch APIError.http(404, _) {
            return nil
        }
    }

    // MARK: Library: variant groups (read: library:read_*, write: library:update_*)

    /// GET /library/variant-groups/by-file/{id}. nil when the file is in no group (404).
    func variantGroup(forFile id: Int) async throws -> VariantGroup? {
        do {
            return try await get("library/variant-groups/by-file/\(id)")
        } catch APIError.http(404, _) {
            return nil
        }
    }

    /// POST /library/variant-groups {members: [{library_file_id, target_model?}], name?} (2+ sliced files, one per printer model).
    func createVariantGroup(fileIds: [Int], targetModels: [Int: String], name: String?) async throws -> VariantGroup {
        struct Member: Encodable { let libraryFileId: Int; let targetModel: String? }
        struct Body: Encodable { let members: [Member]; let name: String? }
        let body = Body(members: fileIds.map { Member(libraryFileId: $0, targetModel: targetModels[$0]) },
                        name: (name?.isEmpty == false) ? name : nil)
        return try decoder().decode(VariantGroup.self, from: try await request("library/variant-groups", method: "POST", body: body))
    }

    /// POST /library/variant-groups/{id}/members.
    func addVariantMember(_ groupId: Int, fileId: Int, targetModel: String?) async throws -> VariantGroup {
        struct Body: Encodable { let libraryFileId: Int; let targetModel: String? }
        return try decoder().decode(VariantGroup.self, from: try await request(
            "library/variant-groups/\(groupId)/members", method: "POST", body: Body(libraryFileId: fileId, targetModel: targetModel)))
    }

    /// DELETE /library/variant-groups/{id}/members/{file}: the file stays; a group left with one member dissolves.
    func removeVariantMember(_ groupId: Int, fileId: Int) async throws {
        _ = try await request("library/variant-groups/\(groupId)/members/\(fileId)", method: "DELETE")
    }

    /// DELETE /library/variant-groups/{id}: ungroup. Files are kept.
    func deleteVariantGroup(_ groupId: Int) async throws {
        _ = try await request("library/variant-groups/\(groupId)", method: "DELETE")
    }

    /// PATCH /library/variant-groups/{id}: rename and/or full member order (priority when several printers are free).
    func updateVariantGroup(_ groupId: Int, name: String?, memberFileIds: [Int]?) async throws -> VariantGroup {
        struct Body: Encodable { let name: String?; let memberFileIds: [Int]? }
        return try decoder().decode(VariantGroup.self, from: try await request(
            "library/variant-groups/\(groupId)", method: "PATCH", body: Body(name: name, memberFileIds: memberFileIds)))
    }

    /// POST /queue/ {variants: [{library_file_id}], quantity} (queue:create): whichever printer frees up first
    /// runs the file sliced for it. Cannot be combined with a printer or a single file.
    func queueVariants(fileIds: [Int], quantity: Int) async throws {
        struct Variant: Encodable { let libraryFileId: Int }
        struct Body: Encodable { let variants: [Variant]; let quantity: Int }
        _ = try await request("queue/", method: "POST", body: Body(variants: fileIds.map(Variant.init), quantity: quantity))
    }

    // MARK: Filament catalog (read: filaments:read; writes are admin-only, so they take the admin session's `bearer`)

    /// GET /filament-catalog/.
    func filamentCatalog() async throws -> [CatalogFilament] { try await get("filament-catalog/") }

    /// POST /filament-catalog/ (filaments:create). Bambuddy refuses API keys for it, so pass the admin JWT.
    func createCatalogFilament(_ draft: CatalogFilamentDraft, bearer: String?) async throws -> CatalogFilament {
        try decoder().decode(CatalogFilament.self, from: try await request("filament-catalog/", method: "POST", body: draft.createBody(), bearer: bearer))
    }

    /// PATCH /filament-catalog/{id} (filaments:update, admin JWT).
    func updateCatalogFilament(_ id: Int, _ patch: InventoryPatch, bearer: String?) async throws -> CatalogFilament {
        try decoder().decode(CatalogFilament.self, from: try await request("filament-catalog/\(id)", method: "PATCH", body: patch, bearer: bearer))
    }

    /// DELETE /filament-catalog/{id} (filaments:delete, admin JWT).
    func deleteCatalogFilament(_ id: Int, bearer: String?) async throws {
        _ = try await request("filament-catalog/\(id)", method: "DELETE", bearer: bearer)
    }

    /// POST /filament-catalog/seed-defaults (filaments:create, admin JWT).
    func seedCatalogDefaults(bearer: String?) async throws { _ = try await request("filament-catalog/seed-defaults", method: "POST", bearer: bearer) }

    // MARK: Suppliers (read: inventory:read, write: inventory:update)

    /// GET /inventory/suppliers.
    func suppliers() async throws -> [Supplier] { try await get("inventory/suppliers") }

    /// POST /inventory/suppliers (409 on a duplicate name).
    func createSupplier(_ draft: SupplierDraft) async throws -> Supplier {
        try decoder().decode(Supplier.self, from: try await request("inventory/suppliers", method: "POST", body: draft.createBody()))
    }

    /// PATCH /inventory/suppliers/{id}.
    func updateSupplier(_ id: Int, _ patch: InventoryPatch) async throws -> Supplier {
        try decoder().decode(Supplier.self, from: try await request("inventory/suppliers/\(id)", method: "PATCH", body: patch))
    }

    /// DELETE /inventory/suppliers/{id} (409 while spools use it).
    func deleteSupplier(_ id: Int) async throws { _ = try await request("inventory/suppliers/\(id)", method: "DELETE") }

    /// GET /inventory/stats/suppliers: per-supplier spool counts, stock and spend.
    func supplierStats() async throws -> [SupplierStat] { try await get("inventory/stats/suppliers") }

    // MARK: Usage history (inventory:read; clearing needs inventory:update)

    /// GET /inventory/spools/{id}/usage?limit= (built-in inventory), /spoolman/inventory/spools/{id}/usage in Spoolman mode.
    func spoolUsage(_ id: Int, limit: Int = 100, spoolman: Bool) async throws -> [SpoolUsageRecord] {
        let base = spoolman ? "spoolman/inventory" : "inventory"
        return try await get("\(base)/spools/\(id)/usage", query: [URLQueryItem(name: "limit", value: String(limit))])
    }

    /// DELETE /inventory/spools/{id}/usage (inventory:update): clears one spool's history.
    func clearSpoolUsage(_ id: Int, spoolman: Bool) async throws {
        let base = spoolman ? "spoolman/inventory" : "inventory"
        _ = try await request("\(base)/spools/\(id)/usage", method: "DELETE")
    }

    /// GET /inventory/usage?limit=&spoolman= : the whole inventory's history, newest first.
    func allSpoolUsage(limit: Int, spoolman: Bool) async throws -> [SpoolUsageRecord] {
        try await get("inventory/usage", query: [URLQueryItem(name: "limit", value: String(limit)),
                                                 URLQueryItem(name: "spoolman", value: spoolman ? "true" : "false")])
    }

    // MARK: Forecast (inventory:read or inventory:forecast_read; writes inventory:forecast_write or inventory:update)

    /// GET /inventory/sku-settings.
    func skuSettings() async throws -> [SkuSettings] { try await get("inventory/sku-settings") }

    /// POST /inventory/sku-settings: upsert by material, subtype, brand and color name.
    func saveSkuSettings(_ s: SkuSettings) async throws -> SkuSettings {
        try decoder().decode(SkuSettings.self, from: try await request("inventory/sku-settings", method: "POST", body: s.body()))
    }

    /// GET /inventory/shopping-list.
    func shoppingList() async throws -> [ShoppingItem] { try await get("inventory/shopping-list") }

    /// POST /inventory/shopping-list.
    func addShoppingItem(material: String, subtype: String?, brand: String?, colorName: String?, quantity: Int, note: String?) async throws -> ShoppingItem {
        struct Body: Encodable {
            let material: String
            let subtype: String?
            let brand: String?
            let colorName: String?
            let quantitySpools: Int
            let note: String?
        }
        return try decoder().decode(ShoppingItem.self, from: try await request(
            "inventory/shopping-list", method: "POST",
            body: Body(material: material, subtype: subtype, brand: brand, colorName: colorName, quantitySpools: quantity, note: note)))
    }

    /// PATCH /inventory/shopping-list/{id}/status: pending | purchased | received.
    func setShoppingStatus(_ id: Int, status: String) async throws -> ShoppingItem {
        struct Body: Encodable { let status: String }
        return try decoder().decode(ShoppingItem.self, from: try await request("inventory/shopping-list/\(id)/status", method: "PATCH", body: Body(status: status)))
    }

    /// DELETE /inventory/shopping-list/{id}.
    func deleteShoppingItem(_ id: Int) async throws { _ = try await request("inventory/shopping-list/\(id)", method: "DELETE") }

    /// DELETE /inventory/shopping-list: clears everything.
    func clearShoppingList() async throws { _ = try await request("inventory/shopping-list", method: "DELETE") }

    /// GET /settings/ (settings:read) carries `forecast_global_lead_time_days`.
    func forecastLeadTimeDays() async throws -> Int {
        struct S: Decodable { let forecastGlobalLeadTimeDays: Int? }
        let s: S = try await get("settings/")
        return s.forecastGlobalLeadTimeDays ?? 0
    }

    // MARK: CSV (export: inventory:read, import: inventory:update; built-in inventory only)

    /// GET /inventory/spools/export: the active inventory as CSV.
    func exportSpoolsCSV() async throws -> URL {
        try await downloadFile("inventory/spools/export", fallbackName: "bambuddy_inventory.csv")
    }

    /// POST /inventory/spools/import?dry_run=true|false, multipart field `file`. Max size is enforced server-side (413).
    func importSpoolsCSV(fileURL: URL, dryRun: Bool) async throws -> Data {
        guard let base = ServerConfig.serverURL else { throw APIError.notConfigured }
        var url = base.appending(path: "api/v1/inventory/spools/import")
        url.append(queryItems: [URLQueryItem(name: "dry_run", value: dryRun ? "true" : "false")])
        let boundary = "LayerPal-\(UUID().uuidString)"
        let fileData = try Data(contentsOf: fileURL)
        let safeName = fileURL.lastPathComponent.replacingOccurrences(of: "\"", with: "_")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: text/csv\r\n\r\n".utf8))
        body.append(fileData)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        ServerConfig.authorize(&request)
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(code) else { throw APIError.http(code, String(decoding: data, as: UTF8.self)) }
        return data
    }

    // MARK: Bulk spool actions (inventory:update; both inventories)

    /// POST .../spools/bulk-archive | bulk-restore | bulk-delete {ids} (max 500).
    func bulkSpoolAction(_ action: String, ids: [Int], spoolman: Bool) async throws {
        struct Body: Encodable { let ids: [Int] }
        let base = spoolman ? "spoolman/inventory" : "inventory"
        _ = try await request("\(base)/spools/bulk-\(action)", method: "POST", body: Body(ids: ids))
    }

    /// POST .../spools/bulk-update {ids, update: {...}}: the same change on every spool (location, category, ...).
    func bulkUpdateSpools(ids: [Int], update: InventoryPatch, spoolman: Bool) async throws {
        struct Body: Encodable { let ids: [Int]; let update: InventoryPatch }
        let base = spoolman ? "spoolman/inventory" : "inventory"
        _ = try await request("\(base)/spools/bulk-update", method: "POST", body: Body(ids: ids, update: update))
    }

    // MARK: Locations (inventory:read), for bulk "assign location"

    /// GET /inventory/locations.
    func storageLocations() async throws -> [StorageLocation] { try await get("inventory/locations") }

    // MARK: Labels (inventory:read) and label templates (read: inventory:read, write: inventory:update)

    /// POST /inventory/labels (or /spoolman/labels): a PDF, or PNG (one file, several in a ZIP).
    func renderLabels(_ request: LabelRequest, spoolman: Bool) async throws -> URL {
        try await downloadFile(spoolman ? "spoolman/labels" : "inventory/labels", method: "POST", body: request,
                               fallbackName: request.format == "pdf" ? "labels.pdf" : "labels.png", timeout: 180)
    }

    /// POST /inventory/labels/preview (or /spoolman/labels/preview): one label as a PNG.
    func previewLabel(_ request: LabelPreviewRequest, spoolman: Bool) async throws -> Data {
        let url = try await downloadFile(spoolman ? "spoolman/labels/preview" : "inventory/labels/preview", method: "POST", body: request,
                                         fallbackName: "preview.png")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try Data(contentsOf: url)
    }

    /// GET /label-templates.
    func labelTemplates() async throws -> [LabelTemplate] { try await get("label-templates") }

    /// POST /label-templates {name, layout} (409 on a duplicate name).
    func createLabelTemplate(name: String, layout: SheetLayout) async throws -> LabelTemplate {
        struct Body: Encodable { let name: String; let layout: SheetLayout }
        return try decoder().decode(LabelTemplate.self, from: try await request("label-templates", method: "POST", body: Body(name: name, layout: layout)))
    }

    /// PUT /label-templates/{id}: the whole template.
    func replaceLabelTemplate(_ id: Int, name: String, layout: SheetLayout) async throws -> LabelTemplate {
        struct Body: Encodable { let name: String; let layout: SheetLayout }
        return try decoder().decode(LabelTemplate.self, from: try await request("label-templates/\(id)", method: "PUT", body: Body(name: name, layout: layout)))
    }

    /// DELETE /label-templates/{id}.
    func deleteLabelTemplate(_ id: Int) async throws { _ = try await request("label-templates/\(id)", method: "DELETE") }
}
