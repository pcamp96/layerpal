import SwiftUI
import UIKit

/// Loads Bambuddy images with the app's API key (thumbnail/cover routes take
/// header auth) and keeps them in memory.
actor ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() { cache.countLimit = 400 }

    func image(apiPath: String) async -> UIImage? {
        if let hit = cache.object(forKey: apiPath as NSString) { return hit }
        if let running = inflight[apiPath] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let base = ServerConfig.serverURL else { return nil }
            var path = apiPath
            if path.hasPrefix("/api/v1/") { path.removeFirst("/api/v1/".count) }
            var request = URLRequest(url: base.appending(path: "api/v1/" + path), timeoutInterval: 20)
            ServerConfig.authorize(&request)
            guard let result = try? await URLSession.shared.data(for: request),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return UIImage(data: result.0)
        }
        inflight[apiPath] = task
        let image = await task.value
        inflight[apiPath] = nil
        if let image { cache.setObject(image, forKey: apiPath as NSString) }
        return image
    }
}

/// Thumbnail/cover from a Bambuddy API path (e.g. "archives/12/thumbnail").
struct RemoteImage: View {
    let path: String?
    var contentMode: ContentMode = .fill
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.bgRaised
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "cube.transparent").font(.title3).foregroundStyle(Color.textMuted)
            }
        }
        .clipped()
        .task(id: path) {
            guard let path else { image = nil; return }
            image = await ImageCache.shared.image(apiPath: path)
        }
    }
}

/// Live camera via Bambuddy's MJPEG endpoint. Frames are split on JPEG
/// start/end markers, which works regardless of the multipart boundary.
@MainActor
final class MJPEGStream: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published private(set) var frame: UIImage?
    @Published private(set) var failed = false

    private var session: URLSession?
    private var buffer = Data()
    private var printerId: Int?
    private var fps = 8
    private var attempt = 0
    private var connectTask: Task<Void, Never>?

    /// Retries before showing "Camera unavailable". Bambuddy restarts a stalled
    /// printer connection after 30 s, so a second try usually gets frames.
    private static let maxAttempts = 3

    func start(printerId: Int, fps: Int = 8) {
        stop()
        self.printerId = printerId
        self.fps = fps
        attempt = 0
        failed = false
        connect()
    }

    private func connect() {
        guard let printerId else { return }
        attempt += 1
        let fps = fps
        connectTask = Task {
            // The printer's camera serves one connection well. A snapshot still in
            // flight (for example the camera wall tile just tapped) starves the
            // stream until Bambuddy's 30 s timeout, so let it finish first.
            await CameraActivity.shared.waitForSnapshots(printerId)
            guard !Task.isCancelled, self.printerId == printerId else { return }
            guard let url = await APIClient.shared.mediaURL("printers/\(printerId)/camera/stream",
                                                             extra: [URLQueryItem(name: "fps", value: String(fps))]) else {
                failed = true
                return
            }
            guard !Task.isCancelled, self.printerId == printerId else { return }
            let config = URLSessionConfiguration.default
            // Longer than Bambuddy's 30 s stall timeout, so a server-side reconnect
            // can still deliver frames on this request.
            config.timeoutIntervalForRequest = 40
            let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            self.session = session
            session.dataTask(with: url).resume()
        }
    }

    func stop() {
        connectTask?.cancel()
        connectTask = nil
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll()
        if let printerId { Task { await APIClient.shared.stopCamera(printerId) } }
        printerId = nil
    }

    nonisolated func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { self.consume(data) }
    }

    nonisolated func urlSession(_ session: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            // Ignore sessions we already replaced or stopped.
            guard session === self.session, self.printerId != nil else { return }
            self.session = nil
            if (error as? URLError)?.code == .cancelled { return }
            // The stream ended or stalled (printer busy, server restarting ffmpeg,
            // network blip). Reconnect a few times before showing the error.
            if self.attempt < Self.maxAttempts {
                self.buffer.removeAll()
                self.connectTask = Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled else { return }
                    self.connect()
                }
            } else if self.frame == nil {
                self.failed = true
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        let soi = Data([0xFF, 0xD8]), eoi = Data([0xFF, 0xD9])
        while let start = buffer.range(of: soi), let end = buffer.range(of: eoi, in: start.upperBound ..< buffer.endIndex) {
            let jpeg = buffer.subdata(in: start.lowerBound ..< end.upperBound)
            buffer.removeSubrange(buffer.startIndex ..< end.upperBound)
            if let image = UIImage(data: jpeg) {
                frame = image
                attempt = 0 // a working stream earns a fresh set of retries
            }
        }
        if buffer.count > 4_000_000 { buffer.removeAll() } // never let a bad stream grow unbounded
    }
}

struct LiveCameraView: View {
    let printerId: Int
    @StateObject private var stream = MJPEGStream()
    @State private var fullscreen = false

    var body: some View {
        ZStack {
            Color.black
            if let frame = stream.frame {
                Image(uiImage: frame).resizable().scaledToFit()
            } else if stream.failed {
                VStack(spacing: 6) {
                    Image(systemName: "video.slash").font(.title2)
                    Text("Camera unavailable").font(.footnote)
                    Text("Turn on LAN Mode Liveview on the printer.").font(.caption2).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if stream.frame != nil {
                Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(8)
            }
        }
        .onTapGesture { if stream.frame != nil { fullscreen = true } }
        .onAppear { stream.start(printerId: printerId) }
        .onDisappear { stream.stop() }
        .fullScreenCover(isPresented: $fullscreen) {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                if let frame = stream.frame { Image(uiImage: frame).resizable().scaledToFit() }
                Button { fullscreen = false } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).symbolRenderingMode(.hierarchical)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
    }
}

/// Tracks camera snapshot requests per printer so a live view can wait for
/// them. The printer's camera handles one connection well: if a snapshot and
/// the live stream connect together, the stream gets no frames for 30 s.
actor CameraActivity {
    static let shared = CameraActivity()
    private var inFlight: [Int: Int] = [:]
    private var lastStart: [Int: Date] = [:]

    /// Bambuddy keeps capturing for about 2 s after the app cancels a snapshot
    /// (as a camera wall tile does when you tap it), so treat a recent start as
    /// busy even when the request already ended on the phone.
    private static let serverCapture: TimeInterval = 2.5

    func snapshotStarted(_ printerId: Int) {
        inFlight[printerId, default: 0] += 1
        lastStart[printerId] = Date()
    }

    func snapshotFinished(_ printerId: Int) {
        let left = (inFlight[printerId] ?? 1) - 1
        inFlight[printerId] = left > 0 ? left : nil
    }

    private func busy(_ printerId: Int) -> Bool {
        if inFlight[printerId] != nil { return true }
        guard let started = lastStart[printerId] else { return false }
        return Date().timeIntervalSince(started) < Self.serverCapture
    }

    /// Waits until the printer has no snapshot running, then a short gap so
    /// Bambuddy closes its printer connection. Gives up after `limit` seconds;
    /// a snapshot request times out at 15 s anyway.
    func waitForSnapshots(_ printerId: Int, limit: TimeInterval = 16) async {
        guard busy(printerId) else { return }
        let deadline = Date().addingTimeInterval(limit)
        while busy(printerId), Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}
