import SwiftUI

/// Hub for integration setup (Bambuddy: Settings > Network / Integrations). Each row opens its own screen and
/// only shows when the signed-in account holds the permission Bambuddy checks for it.
struct IntegrationsView: View {
    var body: some View {
        SessionGate(title: "Integrations") { IntegrationsHub() }
    }
}

private struct IntegrationsHub: View {
    @ObservedObject private var session = AdminSession.shared

    var body: some View {
        List {
            Section {
                if session.can("smart_plugs:read") {
                    NavigationLink { HomeAssistantSensorsView() } label: {
                        IconLabel(title: "Home Assistant sensors", symbol: "house.fill", tint: .cyan)
                    }
                }
                if session.can("settings:read") {
                    NavigationLink { AIDetectionView() } label: {
                        IconLabel(title: "AI failure detection", symbol: "eye.trianglebadge.exclamationmark.fill", tint: .purple)
                    }
                }
                if session.can("filaments:read") {
                    NavigationLink { SpoolmanSetupView() } label: {
                        IconLabel(title: "Spoolman", symbol: "cylinder.split.1x2.fill", tint: .orange)
                    }
                }
            } header: { Text("Sensors and filament") }
            if session.can("cloud:auth") || session.can("orca_cloud:auth") {
                Section {
                    NavigationLink { CloudAccountsView() } label: {
                        IconLabel(title: "Bambu Cloud and Orca Cloud", symbol: "cloud.fill", tint: .blue)
                    }
                } header: { Text("Cloud") }
            }
            Section {
                if session.can("notification_templates:read") {
                    NavigationLink { MessageTemplatesView() } label: {
                        IconLabel(title: "Message templates", symbol: "text.bubble.fill", tint: .pink)
                    }
                }
                if session.can("settings:update"), session.me?.isAdmin != false {
                    NavigationLink { ConnectedAppsView() } label: {
                        IconLabel(title: "Connected apps", symbol: "app.connected.to.app.below.fill", tint: .indigo)
                    }
                }
            } header: { Text("Messages and apps") }
        }
        .farmBackground()
    }
}
