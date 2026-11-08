import SafariServices
import SwiftUI
import UIKit

/// External links (Bambuddy: sidebar links to other apps). Listing needs `external_links:read`, which an
/// API key carries. Bambuddy frames them in an iframe; on iOS they open in an in-app Safari sheet.
/// Adding, editing, deleting and reordering links (admin sign-in) live behind the toolbar's Manage button.
struct ExternalLinksView: View {
    @EnvironmentObject private var farm: FarmStore
    @State private var links: [ExtLink] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var opened: ExtLink?
    @State private var managing = false

    private var canManage: Bool { ["external_links:create", "external_links:update", "external_links:delete"].contains { farm.can($0) } }

    var body: some View {
        Group {
            if !farm.can("external_links:read") {
                ContentUnavailableView("Not available for this key", systemImage: "lock.fill",
                                       description: Text("LayerPal's Bambuddy login doesn't have external_links:read."))
            } else {
                list
            }
        }
        .background(Color.bgPrimary)
        .navigationTitle("External links")
        .toolbar {
            if canManage {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { managing = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Manage links")
                }
            }
        }
        .sheet(isPresented: $managing) {
            NavigationStack {
                ExternalLinksManageView { Task { await load() } }
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { managing = false } } }
            }
        }
    }

    private var list: some View {
        List {
            if let error { Text(error).font(.footnote).foregroundStyle(Color.statusError) }
            ForEach(links) { link in
                Button { open(link) } label: {
                    HStack {
                        IconLabel(title: link.name, symbol: link.symbol)
                        Spacer()
                        if let badge = link.badgeCount, badge > 0 {
                            Text("\(badge)").font(.caption.weight(.semibold)).padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.statusError, in: Capsule()).foregroundStyle(.white)
                                .accessibilityLabel("\(badge) notifications")
                        }
                        Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(Color.textMuted)
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityHint("Opens \(host(link)) in Safari")
            }
        }
        .farmBackground()
        .overlay {
            if loaded, links.isEmpty, error == nil {
                ContentUnavailableView("No external links", systemImage: "link",
                                       description: Text("Add links in Bambuddy's Settings."))
            } else if !loaded, error == nil { ProgressView() }
        }
        .fullScreenCover(item: $opened) { link in
            if let url = URL(string: link.url) { LinkSafariView(url: url).ignoresSafeArea() }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func host(_ link: ExtLink) -> String { URL(string: link.url)?.host() ?? link.url }

    private func open(_ link: ExtLink) {
        // SFSafariViewController only takes http(s); the server also enforces this.
        guard let url = URL(string: link.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            error = "\(link.name) doesn't have a web address Safari can open."
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        opened = link
    }

    private func load() async {
        do {
            links = try await APIClient.shared.linkList()
            error = nil
        } catch { self.error = AdminError.friendly(error) }
        loaded = true
    }
}

/// In-app Safari sheet.
struct LinkSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context _: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredControlTintColor = UIColor(Color.accentTeal)
        return controller
    }

    func updateUIViewController(_: SFSafariViewController, context _: Context) {}
}
