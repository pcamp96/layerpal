import SwiftUI
import UIKit

/// Runs admin-session writes from a screen that isn't wrapped in `AdminGate` (for example Locations,
/// whose reads use the app's API key). When the session is missing or expired it raises the sign-in
/// sheet, then repeats the action once the user has signed in.
@MainActor
final class AdminActionRunner: ObservableObject {
    @Published var error: String?
    @Published private(set) var busy = false
    private var retry: (() async -> Void)?

    func run(_ action: @escaping () async throws -> Void) {
        Task { await attempt(action) }
    }

    private func attempt(_ action: @escaping () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await action()
            error = nil
        } catch AdminError.signInRequired {
            error = nil
            retry = { [weak self] in await self?.attempt(action) }
        } catch {
            self.error = AdminError.friendly(error)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }

    fileprivate func signedIn() {
        guard let pending = retry else { return }
        retry = nil
        Task { await pending() }
    }

    fileprivate func signInDismissed() { retry = nil }
}

private struct AdminActionModifier: ViewModifier {
    @ObservedObject var runner: AdminActionRunner
    @ObservedObject private var session = AdminSession.shared
    /// Parent and pushed screens both use this modifier; only the one on screen presents the sheet.
    @State private var onScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear { onScreen = true }
            .onDisappear { onScreen = false }
            .sheet(isPresented: Binding(get: { session.showSignIn && onScreen }, set: { session.showSignIn = $0 })) { AdminSignInSheet() }
            .onChange(of: session.isSignedIn) { _, signedIn in if signedIn { runner.signedIn() } }
            .onChange(of: session.showSignIn) { _, showing in if !showing, !session.isSignedIn { runner.signInDismissed() } }
            .task { await session.refreshStatus() }
    }
}

extension View {
    /// Adds the admin sign-in sheet and retry-after-sign-in behaviour for `runner`'s actions.
    func adminActions(_ runner: AdminActionRunner) -> some View { modifier(AdminActionModifier(runner: runner)) }
}
