import SwiftUI
import UIKit

/// The printers an admin screen can offer in a picker (GET /printers/ with the admin session).
/// If the list can't load, pickers still show the ids already saved.
@MainActor
final class PrinterChoices: ObservableObject {
    @Published private(set) var printers: [AdminPrinter] = []
    @Published private(set) var loaded = false

    func load() async {
        guard !loaded else { return }
        printers = (try? await AdminSession.shared.perform { try await APIClient.shared.adminPrinters(bearer: $0) }) ?? []
        printers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        loaded = true
    }

    func name(_ id: Int) -> String { printers.first { $0.id == id }?.name ?? "Printer #\(id)" }
}

/// One-printer filter for a notification provider: "All printers" or a single printer (`printer_id`).
struct PrinterFilterPicker: View {
    @Binding var printerId: Int?
    @StateObject private var choices = PrinterChoices()

    var body: some View {
        Picker("Printer", selection: $printerId) {
            Text("All printers").tag(Int?.none)
            if let id = printerId, !choices.printers.contains(where: { $0.id == id }) {
                Text(choices.name(id)).tag(Int?.some(id))
            }
            ForEach(choices.printers) { Text($0.name).tag(Int?.some($0.id)) }
        }
        .task { await choices.load() }
    }
}

/// Multi-select list of printers with a "limit to specific printers" switch, for API-key scope.
/// `selection == nil` means every printer.
struct PrinterScopeSection: View {
    @Binding var selection: Set<Int>?
    /// A restricted key can't be widened back to all printers: Bambuddy's PATCH ignores null.
    var canWiden = true
    @StateObject private var choices = PrinterChoices()

    private var limited: Binding<Bool> {
        Binding(get: { selection != nil },
                set: { on in selection = on ? (selection ?? []) : nil })
    }

    var body: some View {
        Section {
            Toggle("Limit to specific printers", isOn: limited).disabled(selection != nil && !canWiden)
            if let current = selection {
                ForEach(choices.printers) { printer in
                    Button {
                        var next = current
                        if next.contains(printer.id) { next.remove(printer.id) } else { next.insert(printer.id) }
                        selection = next
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        HStack {
                            Text(printer.name).foregroundStyle(.primary)
                            Spacer()
                            Image(systemName: current.contains(printer.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(current.contains(printer.id) ? Color.accentTeal : Color.textMuted)
                        }
                    }
                    .accessibilityAddTraits(current.contains(printer.id) ? .isSelected : [])
                }
                if choices.loaded, choices.printers.isEmpty {
                    Text("Couldn't load the printer list.").font(.footnote).foregroundStyle(Color.statusWarning)
                }
                if current.isEmpty {
                    Text("Pick at least one printer.").font(.footnote).foregroundStyle(Color.statusWarning)
                }
            }
        } header: {
            Text("Printers")
        } footer: {
            Text(selection != nil && !canWiden
                ? "Bambuddy can't widen a limited key back to every printer. Select all of them, or make a new key."
                : "A limited key only sees and controls these printers, whatever else it's allowed to do.")
        }
        .task { await choices.load() }
    }
}
