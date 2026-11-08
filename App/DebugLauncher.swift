#if DEBUG
    import SwiftUI

    /// Simulator screenshots: `-openScreen camwall|plugs|firmware|locations|projects|stats|inventory|maintenance|activity|library`.
    struct DebugScreen: Identifiable {
        let id: String

        static var requested: DebugScreen? {
            UserDefaults.standard.string(forKey: "openScreen").map(DebugScreen.init(id:))
        }

        @ViewBuilder @MainActor var view: some View {
            NavigationStack {
                switch id {
                case "camwall": CamWallView()
                case "plugs": SmartPlugsView()
                case "firmware": FirmwareView()
                case "locations": LocationsView()
                case "projects": ProjectsView()
                case "stats": StatsView()
                case "inventory": InventoryHomeView()
                case "maintenance": MaintenanceHomeView()
                case "activity": ActivityView()
                case "library": LibraryHomeView()
                case "system": SystemInfoView()
                case "admin-printers": PrintersAdminView()
                case "maint-types": MaintenanceTypesView()
                case "trash": LibraryTrashView()
                case "profiles": ProfilesView()
                case "pipelines": PipelinesView()
                case "sources": ModelSourcesView()
                case "finance": FinanceView()
                case "links": ExternalLinksView()
                case "vprinters": VirtualPrintersView()
                case "tokens": TokensView()
                case "stats2": StatsDashboardView()
                case "printlog": PrintLogView()
                case "pending": PendingUploadsView()
                case "catalog": FilamentCatalogView()
                case "labels": LabelTemplatesView()
                case "integrations": IntegrationsView()
                case "account": AccountView()
                case "backups": BackupsView()
                case "updates": UpdatesView()
                default: Text("Unknown screen \(id)")
                }
            }
        }
    }
#endif
