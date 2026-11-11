import ActivityKit
import os
import SwiftUI
import UIKit
import UserNotifications

/// Owns everything push: permission, the APNs device token, the push-to-start
/// token, per-activity tokens, and the relay registration.
@MainActor
final class PushManager: ObservableObject {
    static let shared = PushManager()

    @Published private(set) var deviceToken: String?
    @Published private(set) var pushToStartToken: String?
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var relayReady = false
    @Published private(set) var webhookURL: URL? = ServerConfig.webhookURL
    @Published private(set) var lastError: String?
    /// Relay checks this phone's Bambuddy every minute for the Lock Screen card.
    @Published private(set) var relayPolling = false

    /// Set by notification taps; the UI navigates to that printer.
    @Published var openPrinterName: String?

    private var observedActivities = Set<String>()
    /// When each card was first seen, to tell "token still on its way" from "never getting one".
    private var firstSeen: [String: Date] = [:]
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "LayerPal", category: "LiveActivity")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        registerCategories()
        Task { await refreshAuthorization() }
        Task { await observePushToStartTokens() }
        Task { await observeActivities() }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization == .authorized || authorization == .provisional {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await refreshAuthorization()
    }

    func didRegister(deviceToken data: Data) {
        deviceToken = data.hexString
        Task { await syncWithRelay() }
    }

    func didFailToRegister(_ error: Error) {
        lastError = "Couldn't register for push: \(error.localizedDescription)"
    }

    /// Registers this phone with the relay; returns its webhook URL.
    @discardableResult
    func syncWithRelay() async -> URL? {
        guard let deviceToken else { return nil }
        do {
            let registration = try await RelayClient.shared.register(deviceToken: deviceToken, pushToStartToken: pushToStartToken)
            relayReady = registration.pushReady
            relayPolling = registration.polling ?? false
            webhookURL = ServerConfig.webhookURL
            if !relayPolling { await provideReadOnlyKeyIfPossible() }
            lastError = registration.pushReady ? nil : "The push relay isn't set up for this build type yet."
            for activity in PrintsActivity.activities {
                if let token = activity.pushToken { await register(activity: activity, token: token.hexString) }
            }
            return webhookURL
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Asks for permission if needed and waits (briefly) for Apple to hand us a token.
    func ensureWebhookURL() async -> URL? {
        if authorization == .notDetermined { await requestAuthorization() }
        for _ in 0 ..< 20 where deviceToken == nil {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await syncWithRelay()
    }

    /// The relay needs a read-only key to check Bambuddy. Setup creates a dedicated
    /// one; for older installs whose app key is itself read-only, reuse that.
    private func provideReadOnlyKeyIfPossible() async {
        guard let server = ServerConfig.serverURL else { return }
        let farm = FarmStore.shared
        if farm.authEnabled {
            guard let key = ServerConfig.apiKey, !farm.permissions.isEmpty,
                  !farm.permissions.contains("printers:control"), !farm.permissions.contains("queue:create") else { return }
            try? await RelayClient.shared.setPollCredentials(server: server, apiKey: key)
        } else {
            try? await RelayClient.shared.setPollCredentials(server: server, apiKey: RelayClient.noAuth)
        }
        relayPolling = true
    }

    // MARK: Live Activities (one card for all active prints)

    private typealias PrintsActivity = Activity<PrintsActivityAttributes>


    private func observePushToStartTokens() async {
        for await data in PrintsActivity.pushToStartTokenUpdates {
            pushToStartToken = data.hexString
            await syncWithRelay()
        }
    }

    private func observeActivities() async {
        for activity in PrintsActivity.activities { observe(activity, isNew: false) }
        // A card arriving here was just started (by the relay's push-to-start or by us): it's the keeper.
        for await activity in PrintsActivity.activityUpdates { observe(activity, isNew: true) }
    }

    private func observe(_ activity: PrintsActivity, isNew: Bool) {
        guard observedActivities.insert(activity.id).inserted else { return }
        firstSeen[activity.id] = Date()
        log.info("observe \(activity.id, privacy: .public) new=\(isNew) state=\(String(describing: activity.activityState), privacy: .public) token=\(activity.pushToken != nil)")
        Task { await dedupeActivities(keeping: isNew ? activity : nil) }
        Task {
            for await data in activity.pushTokenUpdates {
                log.info("token for \(activity.id, privacy: .public)")
                await register(activity: activity, token: data.hexString)
            }
        }
    }

    private func register(activity _: PrintsActivity, token: String) async {
        do {
            try await RelayClient.shared.registerActivity(pushToken: token)
            log.info("registered activity token with relay")
        } catch {
            log.error("activity token registration failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Live Activity registration failed: \(error.localizedDescription)"
        }
    }

    /// Called whenever the app refreshes printer statuses. Starts the card when
    /// something is printing, keeps it current while the app is open, and ends
    /// it when everything is done. The relay keeps it current when the app isn't open.
    // MARK: One card, user-controllable

    /// The relay (push-to-start) and the app (while open) can both start a card for the
    /// same print. Keep one and point the relay at it. `Activity.activities` has no
    /// guaranteed order, so never pick by position: a just-started card wins, then one the
    /// relay can reach (has a push token), then the most recently updated.
    @discardableResult
    private func dedupeActivities(keeping preferred: PrintsActivity? = nil) async -> PrintsActivity? {
        let all = PrintsActivity.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        let keep = preferred.flatMap { p in all.first { $0.id == p.id } }
            ?? all.filter { $0.pushToken != nil }.max { $0.content.state.updatedAt < $1.content.state.updatedAt }
            ?? all.max { $0.content.state.updatedAt < $1.content.state.updatedAt }
        guard let keep else { return nil }
        for extra in all where extra.id != keep.id {
            log.info("ending duplicate card \(extra.id, privacy: .public), keeping \(keep.id, privacy: .public)")
            await extra.end(nil, dismissalPolicy: .immediate)
        }
        if all.count > 1, let token = keep.pushToken { await register(activity: keep, token: token.hexString) }
        return keep
    }

    /// "Lock Screen print activity" switch.
    func setLiveActivitiesEnabled(_ on: Bool) async {
        LiveActivityPrefs.enabled = on
        if !on {
            for activity in PrintsActivity.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            lastPushedLocal = nil
        }
        await syncWithRelay() // tells the relay whether to start/refresh cards for this phone
    }

    /// Opening the app resets the card to its collapsed state (tap 1 = details, tap 2 = app).
    func collapseCard() {
        guard LiveActivityPrefs.expanded else { return }
        LiveActivityPrefs.expanded = false
        Task { for activity in PrintsActivity.activities { await activity.update(activity.content) } }
    }

    func syncLiveActivity(_ statuses: [(Printer, PrinterStatus)]) {
        guard LiveActivityPrefs.enabled else { return }
        let snapshots = statuses.map { printer, status in
            (name: printer.name, status: PrinterStatusSnapshot(
                phase: FarmState(status) == .error && status.isPrinting ? "error" : status.phase,
                progress: Int(status.progress ?? 0),
                remainingMinutes: status.remainingTime ?? 0,
                layer: status.layerNum ?? 0,
                totalLayers: status.totalLayers ?? 0,
                jobName: status.jobName
            ))
        }
        let state = PrintsActivityAttributes.ContentState.from(snapshots)
        let existing = PrintsActivity.activities.first
        // Don't churn the card with identical content (the store flushes twice a second).
        guard state.prints != lastPushedLocal?.prints || state.printing != lastPushedLocal?.printing
            || state.paused != lastPushedLocal?.paused || state.errors != lastPushedLocal?.errors
            || existing == nil else { return }
        lastPushedLocal = state
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))

        Task {
            if state.activeCount == 0 {
                // The relay ends the card (with a "done" row) when prints finish; only clean up stale leftovers.
                if let existing, existing.content.staleDate.map({ $0 < Date() }) ?? false {
                    await existing.end(nil, dismissalPolicy: .immediate)
                }
                return
            }
            var card = await dedupeActivities() ?? existing
            // A card the relay can't reach (no update token after a grace period, e.g. one
            // push-started without input-push-token) would freeze once the app closes.
            // Replace it with one we start ourselves, which always gets a token.
            if let stuck = card, stuck.pushToken == nil,
               Date().timeIntervalSince(firstSeen[stuck.id] ?? .distantPast) > 20 {
                log.info("replacing tokenless card \(stuck.id, privacy: .public)")
                await stuck.end(nil, dismissalPolicy: .immediate)
                card = nil
            }
            if let card {
                await card.update(content)
            } else if ActivityAuthorizationInfo().areActivitiesEnabled {
                do {
                    let activity = try PrintsActivity.request(
                        attributes: PrintsActivityAttributes(title: "Prints"),
                        content: content,
                        pushType: .token
                    )
                    observe(activity, isNew: true)
                } catch {
                    lastError = "Couldn't start Live Activity: \(error.localizedDescription)"
                }
            }
        }
    }

    private var lastPushedLocal: PrintsActivityAttributes.ContentState?

    // MARK: Notification actions

    static let uploadMakeAction = "UPLOAD_MAKE"
    static let openPrinterAction = "OPEN_PRINTER"

    private func registerCategories() {
        let upload = UNNotificationAction(identifier: Self.uploadMakeAction, title: "Upload make photo",
                                          options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "camera"))
        let open = UNNotificationAction(identifier: Self.openPrinterAction, title: "Open printer",
                                        options: [.foreground], icon: UNNotificationActionIcon(systemImageName: "printer"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: "MAKERWORLD_MAKE", actions: [upload, open], intentIdentifiers: []),
            UNNotificationCategory(identifier: "PRINTER_EVENT", actions: [open], intentIdentifiers: []),
        ])
    }

    func handle(userInfo: [AnyHashable: Any], action: String) {
        let info = userInfo["bambuddy"] as? [String: Any] ?? [:]
        let makerworld = (info["makerworld_url"] as? String).flatMap(URL.init(string:))
        let printer = info["printer_name"] as? String

        switch action {
        case Self.uploadMakeAction:
            if let makerworld { UIApplication.shared.open(makerworld) }
        case Self.openPrinterAction:
            openPrinterName = printer
        case UNNotificationDefaultActionIdentifier:
            // Tapping the MakerWorld nudge itself goes straight to the model page.
            if let makerworld { UIApplication.shared.open(makerworld) } else { openPrinterName = printer }
        default:
            break
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_: UIApplication,
                     didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in PushManager.shared.start() }
        return true
    }

    func application(_: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PushManager.shared.didRegister(deviceToken: deviceToken) }
    }

    func application(_: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PushManager.shared.didFailToRegister(error) }
    }

    func userNotificationCenter(_: UNUserNotificationCenter, willPresent _: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    func userNotificationCenter(_: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        await MainActor.run { PushManager.shared.handle(userInfo: userInfo, action: action) }
    }
}
