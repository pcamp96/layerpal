import ImageIO
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

/// Job thumbnail for a printer card: the print's cover when Bambuddy has the
/// 3MF, otherwise a camera snapshot (prints sent without the file, such as
/// from Bambu Handy or the cloud, have no cover). The snapshot refreshes
/// while the card is on screen and goes through the camera wall's gate.
struct PrintThumbnail: View {
    let printerId: Int
    let coverPath: String?
    let cameraAllowed: Bool
    var refresh: TimeInterval = 60
    @State private var image: UIImage?
    @State private var isCamera = false

    var body: some View {
        ZStack {
            Color.bgRaised
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "cube.transparent").font(.title3).foregroundStyle(Color.textMuted)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if isCamera, image != nil {
                Image(systemName: "video.fill")
                    .font(.system(size: 8, weight: .bold))
                    .padding(3)
                    .background(.black.opacity(0.55), in: Circle())
                    .foregroundStyle(.white)
                    .padding(3)
                    .accessibilityHidden(true)
            }
        }
        .clipped()
        .task(id: coverPath) { await load() }
    }

    private func load() async {
        if let coverPath, let cover = await ImageCache.shared.image(apiPath: coverPath) {
            image = cover
            isCamera = false
            return
        }
        guard cameraAllowed else { image = nil; return }
        // Cancelled when the card scrolls away or the screen changes.
        while !Task.isCancelled {
            await SnapshotGate.shared.acquire()
            let data = Task.isCancelled ? nil : await APIClient.shared.cameraSnapshot(printerId)
            await SnapshotGate.shared.release()
            if let data, !Task.isCancelled,
               let frame = await Task.detached(priority: .utility, operation: { Self.downsample(data) }).value {
                image = frame
                isCamera = true
            }
            try? await Task.sleep(nanoseconds: UInt64(refresh * 1_000_000_000))
        }
    }

    private nonisolated static func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
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

    /// Starts the stream unless it is already running for this printer
    /// (for example when returning from full screen).
    func ensureRunning(printerId: Int) {
        if self.printerId == printerId, session != nil || connectTask != nil { return }
        start(printerId: printerId)
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
    @State private var inlineZoom: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black
            if let frame = stream.frame {
                ZoomableImage(image: frame, scale: $inlineZoom)
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
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if stream.frame != nil {
                Button { fullscreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 32)
                        .background(.black.opacity(0.55), in: Circle())
                        .foregroundStyle(.white)
                }
                .padding(8)
                .accessibilityLabel("Full screen")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if stream.frame != nil, inlineZoom <= 1 { fullscreen = true } }
        .onAppear { stream.ensureRunning(printerId: printerId) }
        // Presenting the full-screen cover also fires onDisappear here; keep streaming for it.
        .onDisappear { if !fullscreen { stream.stop() } }
        .fullScreenCover(isPresented: $fullscreen) {
            FullscreenCamera(stream: stream) { fullscreen = false }
        }
    }
}

/// Full-screen live view: pinch or double-tap to zoom, drag to pan, swipe
/// down or tap Done to close.
private struct FullscreenCamera: View {
    @ObservedObject var stream: MJPEGStream
    let close: () -> Void
    @State private var zoom: CGFloat = 1
    @State private var pull: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(1 - min(Double(pull) / 400, 0.6)).ignoresSafeArea()
            if let frame = stream.frame {
                ZoomableImage(image: frame, scale: $zoom, doubleTapToZoom: true)
                    .offset(y: pull)
            } else {
                ProgressView().tint(.white)
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard zoom <= 1 else { return }
                    pull = max(0, value.translation.height)
                }
                .onEnded { value in
                    guard zoom <= 1 else { return }
                    if value.translation.height > 120 || value.predictedEndTranslation.height > 300 {
                        close()
                    } else {
                        withAnimation(.spring(duration: 0.25)) { pull = 0 }
                    }
                }
        )
        .overlay(alignment: .topTrailing) {
            Button(action: close) {
                Text("Done")
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }
}

/// Pinch to zoom (1x to 5x) and drag to pan while zoomed. Drag only engages
/// when zoomed, so an inline view still scrolls with its page.
struct ZoomableImage: View {
    let image: UIImage
    @Binding var scale: CGFloat
    var doubleTapToZoom = false
    @GestureState private var pinch: CGFloat = 1
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    private static let maxScale: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            let live = min(max(scale * pinch, 1), Self.maxScale)
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(live)
                .offset(clamp(CGSize(width: offset.width + drag.width, height: offset.height + drag.height),
                              scale: live, size: geo.size))
                .contentShape(Rectangle())
                .gesture(
                    MagnifyGesture()
                        .updating($pinch) { value, state, _ in state = value.magnification }
                        .onEnded { value in
                            scale = min(max(scale * value.magnification, 1), Self.maxScale)
                            offset = scale <= 1 ? .zero : clamp(offset, scale: scale, size: geo.size)
                        }
                )
                .simultaneousGesture(
                    DragGesture()
                        .updating($drag) { value, state, _ in state = value.translation }
                        .onEnded { value in
                            offset = clamp(CGSize(width: offset.width + value.translation.width,
                                                  height: offset.height + value.translation.height),
                                           scale: scale, size: geo.size)
                        },
                    including: scale > 1 ? .all : .subviews
                )
                // Only full screen gets double-tap; inline it would delay the
                // single tap that opens full screen.
                .simultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        withAnimation(.spring(duration: 0.3)) {
                            if scale > 1 { scale = 1; offset = .zero } else { scale = 2.5 }
                        }
                    },
                    including: doubleTapToZoom ? .all : .subviews
                )
        }
        .clipped()
    }

    /// Keeps the zoomed image covering the frame instead of sliding off it.
    private func clamp(_ proposed: CGSize, scale: CGFloat, size: CGSize) -> CGSize {
        guard scale > 1 else { return .zero }
        let maxX = size.width * (scale - 1) / 2, maxY = size.height * (scale - 1) / 2
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
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
