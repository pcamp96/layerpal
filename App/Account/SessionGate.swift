import SwiftUI
import UIKit

/// Wraps a screen that runs on the user's own sign-in session (account, integrations setup). Same job as
/// AdminGate, with neutral wording: these screens are for any signed-in user, not only admins.
struct SessionGate<Content: View>: View {
    var title: String
    var permission: String?
    /// Account pages mean nothing when Bambuddy's login is switched off.
    var needsLogin = false
    @ViewBuilder var content: Content
    @ObservedObject private var session = AdminSession.shared

    var body: some View {
        Group {
            if session.authEnabled == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if needsLogin, session.authEnabled == false {
                ContentUnavailableView("Bambuddy login is off", systemImage: "lock.open.fill",
                                       description: Text("There are no user accounts to manage while Bambuddy's login is switched off."))
            } else if !session.isReady {
                signInCard
            } else if let permission, !session.can(permission) {
                ContentUnavailableView("Not available for your account", systemImage: "lock.fill",
                                       description: Text("Your Bambuddy account doesn't have \(permission)."))
            } else {
                content
            }
        }
        .background(Color.bgPrimary)
        .navigationTitle(title)
        .task { await session.refreshStatus() }
        .sheet(isPresented: $session.showSignIn) { AdminSignInSheet() }
    }

    private var signInCard: some View {
        ScrollView {
            Card {
                VStack(spacing: 12) {
                    Image(systemName: "person.badge.key.fill").font(.largeTitle).foregroundStyle(Color.accentTeal)
                    Text("Sign in to continue").font(.headline)
                    Text("\(title) uses your own Bambuddy sign-in. LayerPal keeps the session on this iPhone, never your password.")
                        .font(.subheadline).foregroundStyle(Color.textSecondary).multilineTextAlignment(.center)
                    Button { session.showSignIn = true } label: { Text("Sign in").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.accentTeal)
                }
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
    }
}

/// Copies a secret to the clipboard for two minutes, on this device only (no Universal Clipboard).
func copySecretToClipboard(_ text: String) {
    UIPasteboard.general.setItems([["public.utf8-plain-text": text]],
                                  options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
}

/// Inline error line used under forms.
struct InlineError: View {
    let message: String?
    var body: some View {
        if let message {
            Text(message).font(.footnote).foregroundStyle(Color.statusError)
                .accessibilityLabel("Error: \(message)")
        }
    }
}
