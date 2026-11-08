import Foundation

// MARK: - Home Assistant sensors

/// A Home Assistant entity bound to a printer (printer HA-sensor response).
struct SetupHASensor: Decodable, Identifiable, Hashable {
    let id: Int
    let printerId: Int
    let name: String
    let entityId: String
    let kind: String
    let deviceClass: String?
    let unit: String?
    let alertState: String?
    let alertAbove: Double?
    let alertBelow: Double?
    let blockPrint: Bool?
    let notifyOnAlert: Bool?
    let showOnPrinterCard: Bool?
    let lastState: String?
}

/// A Home Assistant entity bound to a storage location (location HA-sensor response).
struct SetupHALocSensor: Decodable, Identifiable, Hashable {
    let id: Int
    let locationId: Int
    let name: String
    let entityId: String
    let kind: String
    let deviceClass: String?
    let unit: String?
    let alertState: String?
    let alertAbove: Double?
    let alertBelow: Double?
    let notifyOnAlert: Bool?
    let showOnCard: Bool?
    let lastState: String?
}

/// Live state of one sensor (PrinterHASensorReading / LocationHASensorReading).
struct SetupHAReading: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let entityId: String
    let kind: String
    let deviceClass: String?
    let unit: String?
    let state: String?
    let value: Double?
    let alerting: Bool?
    let reachable: Bool?

    var display: String {
        guard reachable != false, let state else { return "Unavailable" }
        if kind == "numeric", let value {
            let text = value.formatted(.number.precision(.fractionLength(0 ... 1)))
            return unit.map { "\(text) \($0)" } ?? text
        }
        return state.capitalized
    }
}

/// An entity the picker offers (HADisplayEntity).
struct SetupHAEntity: Decodable, Identifiable, Hashable {
    let entityId: String
    let friendlyName: String
    let state: String?
    let domain: String
    let deviceClass: String?
    let unitOfMeasurement: String?
    var id: String { entityId }
    var kind: String { domain == "binary_sensor" ? "binary" : "numeric" }
}

/// GET /inventory/locations
struct SetupStorageLocation: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let identifier: String?
    let spoolCount: Int?
}

// MARK: - Spoolman

/// GET /spoolman/status
struct SetupSpoolmanStatus: Decodable {
    let enabled: Bool
    let connected: Bool
    let url: String?
    let nativeTags: Bool?
}

/// SyncResult from POST /spoolman/sync/{printer_id} and /sync-all.
struct SetupSyncResult: Decodable {
    struct Skipped: Decodable, Hashable { let location: String; let reason: String?; let filamentType: String? }
    let success: Bool
    let syncedCount: Int
    let skippedCount: Int?
    let skipped: [Skipped]?
    let errors: [String]?
}

// MARK: - Bambu Cloud / Orca Cloud

/// GET /cloud/status
struct SetupCloudStatus: Decodable {
    let isAuthenticated: Bool
    let email: String?
    let region: String?
    let signInExpired: Bool?
}

/// POST /cloud/login and /cloud/verify
struct SetupCloudLogin: Decodable {
    let success: Bool
    let needsVerification: Bool?
    let message: String?
    let verificationType: String?
    let tfaKey: String?
    let reason: String?
}

/// GET /orca-cloud/status
struct SetupOrcaStatus: Decodable {
    let connected: Bool
    let email: String?
    let userId: String?
}

/// POST /orca-cloud/device/start
struct SetupOrcaStart: Decodable {
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let interval: Int
    let expiresIn: Int
}

/// POST /orca-cloud/device/poll
struct SetupOrcaPoll: Decodable {
    let status: String
    let connected: Bool?
}

// MARK: - Message templates

/// GET /notification-templates/
struct SetupTemplate: Decodable, Identifiable, Hashable {
    let id: Int
    let eventType: String
    let name: String
    var titleTemplate: String
    var bodyTemplate: String
    let isDefault: Bool?
}

/// GET /notification-templates/variables
struct SetupEventVariables: Decodable, Hashable {
    let eventType: String
    let eventName: String
    let variables: [String]
    let supportsPhoto: Bool?
}

// MARK: - Connected apps

/// GET /connect/apps (the secret is only in the create/rotate response).
struct SetupConnectedApp: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let clientId: String
    let redirectUri: String
    let enabled: Bool
    let createdAt: Date?
    let lastUsedAt: Date?
    /// Present only on POST /connect/apps and /rotate-secret.
    let clientSecret: String?
}
