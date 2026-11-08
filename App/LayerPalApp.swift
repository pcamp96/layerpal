import SwiftUI

@main
struct LayerPalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var push = PushManager.shared
    @StateObject private var farm = FarmStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(push)
                .environmentObject(farm)
                .tint(.accentTeal)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var push: PushManager
    @EnvironmentObject private var farm: FarmStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.farm
    @State private var needsSetup = ServerConfig.serverURL == nil
    #if DEBUG
        @State private var debugScreen = DebugScreen.requested
    #endif

    enum Tab { case farm, queue, prints, more }

    var body: some View {
        TabView(selection: $tab) {
            FarmView()
                .tabItem { Label("Farm", systemImage: "square.grid.2x2.fill") }
                .tag(Tab.farm)
                .badge(farm.needsAttention.count)
            QueueView()
                .tabItem { Label("Queue", systemImage: "list.number") }
                .tag(Tab.queue)
            NavigationStack { ArchiveListView() }
                .tabItem { Label("Prints", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.prints)
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle.fill") }
                .tag(Tab.more)
        }
        .onChange(of: push.openPrinterName) { _, name in if name != nil { tab = .farm } }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: farm.start(); push.collapseCard(); Task { await farm.refresh() }
            case .background: farm.stop()
            default: break
            }
        }
        .onAppear {
            farm.start()
            #if DEBUG
                // Simulator screenshots: `-startTab queue|prints|more`, `-openPrinter <name>`.
                switch UserDefaults.standard.string(forKey: "startTab") {
                case "queue": tab = .queue
                case "prints": tab = .prints
                case "more": tab = .more
                default: break
                }
                if let name = UserDefaults.standard.string(forKey: "openPrinter") { push.openPrinterName = name }
            #endif
        }
        #if DEBUG
        .fullScreenCover(item: $debugScreen) { $0.view }
        #endif
        .fullScreenCover(isPresented: $needsSetup) {
            NavigationStack {
                SettingsView(onSaved: {
                    needsSetup = false
                    farm.restart()
                })
            }
        }
    }
}
