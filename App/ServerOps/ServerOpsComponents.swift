import SwiftUI
import UIKit

/// Shared pieces for the server-ops screens.

func opsBytes(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

enum OpsHaptics {
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
}

/// Inline result line: green check, red error or neutral info.
struct OpsBanner: View {
    enum Kind { case success, error, info, warning }
    let kind: Kind
    let text: String

    private var symbol: String {
        switch kind {
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .warning: "exclamationmark.circle.fill"
        case .info: "info.circle.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .success: .accentTeal
        case .error: .statusError
        case .warning: .statusWarning
        case .info: .textSecondary
        }
    }

    var body: some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: symbol) }
            .font(.footnote)
            .foregroundStyle(tint)
            .accessibilityElement(children: .combine)
    }
}

/// Label and value on one row; the value wraps instead of truncating at large type sizes.
struct OpsValueRow: View {
    let label: String
    let value: String
    var mono = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(Color.textSecondary)
            Spacer(minLength: 12)
            Text(value).font(mono ? .subheadline.monospaced() : .subheadline).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A button that shows a spinner while its action runs.
struct OpsActionButton: View {
    let title: String
    var systemImage: String?
    var role: ButtonRole?
    var busy = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            HStack {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
                Spacer()
                if busy { ProgressView() }
            }
        }
        .disabled(busy || disabled)
    }
}

/// Destructive confirmation that makes the user type a word before the button enables.
struct TypedConfirmSheet: View {
    let title: String
    let consequence: String
    let word: String
    let actionTitle: String
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""
    @FocusState private var focused: Bool

    private var matches: Bool { typed.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(word) == .orderedSame }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label {
                        Text(consequence).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusError)
                    }
                    .font(.subheadline)
                }
                Section {
                    TextField(word, text: $typed)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focused)
                } header: {
                    Text("Type \(word) to confirm")
                }
                Section {
                    Button(role: .destructive) {
                        OpsHaptics.warning()
                        dismiss()
                        onConfirm()
                    } label: {
                        Text(actionTitle).frame(maxWidth: .infinity)
                    }
                    .disabled(!matches)
                }
            }
            .farmBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(false)
    }
}

/// A file ready to share (log text, support bundle, backup ZIP).
struct OpsShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct OpsShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Writes text to a temp file so it shares as a file, not a pasted blob.
func opsTempTextFile(_ text: String, name: String) -> URL? {
    let dir = FileManager.default.temporaryDirectory.appending(path: "layerpal-ops-\(UUID().uuidString)", directoryHint: .isDirectory)
    do {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch {
        return nil
    }
}

extension Date {
    var opsShort: String { formatted(date: .abbreviated, time: .shortened) }
}
