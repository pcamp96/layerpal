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

    func start(printerId: Int, fps: Int = 8) {
        stop()
        self.printerId = printerId
        failed = false
        Task {
            guard let url = await APIClient.shared.mediaURL("printers/\(printerId)/camera/stream",
                                                             extra: [URLQueryItem(name: "fps", value: String(fps))]) else {
                failed = true
                return
            }
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
            self.session = session
            session.dataTask(with: url).resume()
        }
    }

    func stop() {
        session?.invalidateAndCancel()
        session = nil
        buffer.removeAll()
        if let printerId { Task { await APIClient.shared.stopCamera(printerId) } }
        printerId = nil
    }

    nonisolated func urlSession(_: URLSession, dataTask _: URLSessionDataTask, didReceive data: Data) {
        MainActor.assumeIsolated { self.consume(data) }
    }

    nonisolated func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            if error != nil, self.frame == nil { self.failed = true }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        let soi = Data([0xFF, 0xD8]), eoi = Data([0xFF, 0xD9])
        while let start = buffer.range(of: soi), let end = buffer.range(of: eoi, in: start.upperBound ..< buffer.endIndex) {
            let jpeg = buffer.subdata(in: start.lowerBound ..< end.upperBound)
            buffer.removeSubrange(buffer.startIndex ..< end.upperBound)
            if let image = UIImage(data: jpeg) { frame = image }
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
