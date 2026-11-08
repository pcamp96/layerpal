import Foundation
import SwiftUI

/// Live state of the whole farm.
///
/// One WebSocket (`/api/v1/ws`) carries every printer's status. Messages are
/// partial status objects, so each is merged key by key into a raw dictionary
/// per printer, decoded off the main thread, and published in batches at most
/// twice a second so an 80-printer farm doesn't thrash SwiftUI. If the socket
/// can't stay up, it falls back to `GET /bulk/printer-statuses` polling.
@MainActor
final class FarmStore: ObservableObject {
    static let shared = FarmStore()

    enum Connection: Equatable { case connecting, live, polling, offline(String) }

    @Published private(set) var printers: [Printer] = []
    @Published private(set) var statuses: [Int: PrinterStatus] = [:]
    @Published private(set) var permissions: Set<String> = []
    @Published private(set) var authEnabled = true
    @Published private(set) var connection: Connection = .connecting
    @Published private(set) var lastUpdated: Date?

    private let merger = StatusMerger()
    private var socketTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var running = false

    // MARK: Permissions

    func can(_ permission: String) -> Bool { !authEnabled || permissions.contains(permission) }
    var canControl: Bool { can("printers:control") }
    var canQueue: Bool { can("queue:create") }

    func canControl(_ printerId: Int) -> Bool { canControl && (statuses[printerId]?.acceptsControl ?? false) }

    // MARK: Derived views

    var activePrinters: [Printer] { printers.filter { $0.isActive != false } }

    func state(_ id: Int) -> FarmState { FarmState(statuses[id]) }

    func count(_ state: FarmState) -> Int { activePrinters.filter { self.state($0.id) == state }.count }

    /// Printers that need a person: errors, paused, finished/awaiting plate clear.
    var needsAttention: [Printer] {
        activePrinters.filter { p in
            let s = state(p.id)
            return s == .error || s == .paused || statuses[p.id]?.awaitingPlateClear == true
        }
    }

    /// Soonest-finishing active prints first.
    var printingSoonestFirst: [Printer] {
        activePrinters.filter { statuses[$0.id]?.isPrinting == true }.sorted {
            (statuses[$0.id]?.remainingTime ?? .max) < (statuses[$1.id]?.remainingTime ?? .max)
        }
    }

    var locations: [String] {
        Array(Set(activePrinters.map { $0.location?.isEmpty == false ? $0.location! : "" })).sorted {
            $0.isEmpty ? false : ($1.isEmpty ? true : $0.localizedStandardCompare($1) == .orderedAscending)
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !running, ServerConfig.serverURL != nil else { return }
        running = true
        Task { await refresh() }
        socketTask = Task { [weak self] in await self?.socketLoop() }
        flushTask = Task { [weak self] in await self?.flushLoop() }
    }

    func stop() {
        running = false
        socketTask?.cancel()
        flushTask?.cancel()
        pollTask?.cancel()
        socketTask = nil
        flushTask = nil
        pollTask = nil
    }

    func restart() {
        stop()
        printers = []
        statuses = [:]
        Task { await merger.reset() }
        start()
    }

    /// Full REST refresh: printer list, permissions, and every status in one bulk call.
    func refresh() async {
        guard let server = ServerConfig.serverURL else { return }
        do {
            authEnabled = (try? await APIClient.shared.authStatus(server: server).authEnabled) ?? true
            let list = try await APIClient.shared.printers()
            printers = list
            if authEnabled, let me = try? await APIClient.shared.me() {
                permissions = Set(me.permissions ?? [])
            }
            let ids = list.filter { $0.isActive != false }.map(\.id)
            if !ids.isEmpty {
                let data = try await APIClient.shared.bulkStatusData(ids: ids)
                await merger.ingestBulk(data)
                await flush()
            }
            if case .offline = connection { connection = .polling }
        } catch {
            connection = .offline(error.localizedDescription)
        }
    }

    // MARK: WebSocket

    private func socketLoop() async {
        var backoff: UInt64 = 2
        while !Task.isCancelled {
            connection = .connecting
            do {
                try await runSocket()
                backoff = 2
            } catch {
                if Task.isCancelled { return }
                startPolling()
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 60)
            }
        }
    }

    private func runSocket() async throws {
        guard let base = ServerConfig.serverURL,
              var components = URLComponents(url: base.appending(path: "api/v1/ws"), resolvingAgainstBaseURL: false)
        else { throw APIError.notConfigured }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        if authEnabled { components.queryItems = [URLQueryItem(name: "token", value: try await APIClient.shared.wsToken())] }
        guard let url = components.url else { throw APIError.notConfigured }

        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                try? await task.send(.string(#"{"type":"ping"}"#))
            }
        }
        defer { pinger.cancel() }

        var announcedLive = false
        while !Task.isCancelled {
            let message = try await task.receive()
            if !announcedLive {
                announcedLive = true
                connection = .live
                pollTask?.cancel()
                pollTask = nil
            }
            let data: Data
            switch message {
            case let .string(text): data = Data(text.utf8)
            case let .data(d): data = d
            @unknown default: continue
            }
            let needsRefresh = await merger.ingestMessage(data)
            if needsRefresh { Task { await refresh() } }
        }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        connection = .polling
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    // MARK: Batching

    private func flushLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await flush()
        }
    }

    private func flush() async {
        let changed = await merger.drain()
        guard !changed.isEmpty else { return }
        for (id, status) in changed { statuses[id] = status }
        lastUpdated = Date()
        PushManager.shared.syncLiveActivity(activePrinters.compactMap { p in statuses[p.id].map { (p, $0) } })
    }
}

/// Merges partial status dictionaries and decodes them off the main actor.
actor StatusMerger {
    private var raw: [Int: [String: Any]] = [:]
    private var dirty = Set<Int>()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    func reset() {
        raw = [:]
        dirty = []
    }

    func ingestBulk(_ data: Data) {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        for item in list {
            guard let id = item["id"] as? Int else { continue }
            raw[id, default: [:]].merge(item) { _, new in new }
            dirty.insert(id)
        }
    }

    /// Returns true when the message means the printer list itself changed.
    func ingestMessage(_ data: Data) -> Bool {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = msg["type"] as? String else { return false }
        switch type {
        case "printer_status":
            guard let id = msg["printer_id"] as? Int, let payload = msg["data"] as? [String: Any] else { return false }
            raw[id, default: [:]].merge(payload) { _, new in new }
            dirty.insert(id)
            return false
        case "printer_locations_changed":
            return true
        default:
            return false
        }
    }

    func drain() -> [Int: PrinterStatus] {
        var out: [Int: PrinterStatus] = [:]
        for id in dirty {
            guard let dict = raw[id], let data = try? JSONSerialization.data(withJSONObject: dict),
                  let status = try? decoder.decode(PrinterStatus.self, from: data) else { continue }
            out[id] = status
        }
        dirty.removeAll()
        return out
    }
}
