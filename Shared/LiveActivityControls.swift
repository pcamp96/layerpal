import ActivityKit
import AppIntents
import Foundation

/// Live Activity preferences shared by the app, the widget, and the expand intent
/// (App Group defaults, so the widget can read them while rendering).
enum LiveActivityPrefs {
    private static var defaults: UserDefaults {
        let group = (Bundle.main.object(forInfoDictionaryKey: "AppGroup") as? String).flatMap { $0.hasPrefix("$(") ? nil : $0 }
            ?? "group.\(ServerConfig.bundleBase)"
        return UserDefaults(suiteName: group) ?? .standard
    }

    /// User's "Lock Screen print activity" switch. Defaults to on.
    static var enabled: Bool {
        get { defaults.object(forKey: "la.enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "la.enabled") }
    }

    /// First tap on the card expands it in place; the next tap opens the app.
    static var expanded: Bool {
        get { defaults.bool(forKey: "la.expanded") }
        set { defaults.set(newValue, forKey: "la.expanded") }
    }
}

/// Runs in the background (no app launch) when the collapsed card is tapped.
struct ExpandPrintsActivityIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Show print details"
    static var description = IntentDescription("Expands the LayerPal print card on the Lock Screen.")
    static var isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        LiveActivityPrefs.expanded = true
        // Re-render with the same content so the widget picks up the new flag.
        for activity in Activity<PrintsActivityAttributes>.activities {
            await activity.update(activity.content)
        }
        return .result()
    }
}
