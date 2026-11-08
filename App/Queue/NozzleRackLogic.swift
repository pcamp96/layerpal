import Foundation

// H2C nozzle-rack positions. Positions are 1-based (R1...R6); the physical nozzle id is 15 higher.
// The server re-checks every pick at dispatch and refuses one that no longer fits, so these checks
// follow the same rules: same diameter, same flow type, never the same position twice.

/// What one filament group needs of a hotend (`group` on a filament requirement).
struct RackGroupInfo: Decodable, Hashable {
    let onRack: Bool
    let nozzleDiameter: String
    let volumeType: String
    let filamentColor: String

    private enum CodingKeys: String, CodingKey { case onRack, nozzleDiameter, volumeType, filamentColor }

    init(onRack: Bool, nozzleDiameter: String, volumeType: String, filamentColor: String) {
        self.onRack = onRack
        self.nozzleDiameter = nozzleDiameter
        self.volumeType = volumeType
        self.filamentColor = filamentColor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        onRack = try c.decodeIfPresent(Bool.self, forKey: .onRack) ?? false
        nozzleDiameter = try c.decodeIfPresent(String.self, forKey: .nozzleDiameter) ?? ""
        volumeType = try c.decodeIfPresent(String.self, forKey: .volumeType) ?? ""
        filamentColor = try c.decodeIfPresent(String.self, forKey: .filamentColor) ?? ""
    }
}

/// One of the six rack positions as offered to the user.
struct RackPositionOption: Identifiable {
    let position: Int
    let diameter: String
    let nozzleType: String
    let eligible: Bool
    let reason: String?
    var id: Int { position }

    var title: String { diameter.isEmpty ? "R\(position)" : "R\(position) · \(diameter)" }
}

enum NozzleRack {
    static let positionBase = 15
    static let size = 6

    /// Model names and internal codes of nozzle-rack printers. The H3C tool changer is deliberately not
    /// here: the server won't dispatch rack choices to it.
    private static let rackModels: Set<String> = ["H2C", "O1C", "O1C2"]

    static func isRackModel(_ model: String?) -> Bool {
        guard let model else { return false }
        let key = model.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            .replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        return rackModels.contains(key)
    }

    /// Rack slots keyed by 1-based position. The firmware leaves a mounted rack nozzle out of the list
    /// while it sits on the carriage (id 0), so a single gap is filled from the carriage entry.
    static func byPosition(_ slots: [AdvRackSlot]) -> [Int: AdvRackSlot] {
        var out: [Int: AdvRackSlot] = [:]
        var carriage: AdvRackSlot?
        for slot in slots {
            if (positionBase + 1...positionBase + size).contains(slot.id) {
                out[slot.id - positionBase] = slot
            } else if slot.id == 0 {
                carriage = slot
            }
        }
        let gaps = (1...size).filter { out[$0] == nil }
        if gaps.count == 1, let carriage, !carriage.isEmpty {
            out[gaps[0]] = carriage
        }
        return out
    }

    static func isEligible(_ slot: AdvRackSlot?, for group: RackGroupInfo) -> Bool {
        guard let slot, !slot.isEmpty else { return false }
        guard let held = diameter(slot.nozzleDiameter), let wanted = diameter(group.nozzleDiameter),
              held == wanted else { return false }
        let volume = group.volumeType.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (slot.nozzleType ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !volume.isEmpty, !type.isEmpty {
            let slotHighFlow = type.uppercased().hasPrefix("HH")
            let groupHighFlow = volume.lowercased().hasPrefix("high flow")
            if slotHighFlow != groupHighFlow { return false }
        }
        return true
    }

    /// All six positions for one group, each with the reason it can't be used when it can't.
    static func options(_ slots: [AdvRackSlot], for group: RackGroupInfo) -> [RackPositionOption] {
        let placed = byPosition(slots)
        return (1...size).map { position in
            let slot = placed[position]
            let diameter = slot?.nozzleDiameter ?? ""
            let type = slot?.nozzleType ?? ""
            let eligible = isEligible(slot, for: group)
            var reason: String?
            if !eligible {
                if slot == nil || slot?.isEmpty == true {
                    reason = "No nozzle in this position."
                } else {
                    let held = describe(diameter, type)
                    let needed = describe(group.nozzleDiameter, group.volumeType)
                    reason = "Has a \(held) nozzle; this filament needs \(needed)."
                }
            }
            return RackPositionOption(position: position, diameter: diameter, nozzleType: type, eligible: eligible, reason: reason)
        }
    }

    /// A position for every rack-bound group; nil when some group can't be placed.
    static func autoAssign(_ slots: [AdvRackSlot], groups: [Int: RackGroupInfo], pinned: [Int: Int] = [:]) -> [Int: Int]? {
        let placed = byPosition(slots)
        let rackGroups = groups.filter { $0.value.onRack }.sorted { $0.key < $1.key }
        var result: [Int: Int] = [:]
        var taken: Set<Int> = []
        for (id, group) in rackGroups {
            guard let position = pinned[id] else { continue }
            if taken.contains(position) || !isEligible(placed[position], for: group) { return nil }
            taken.insert(position)
            result[id] = position
        }
        for (id, group) in rackGroups where pinned[id] == nil {
            let candidates = (1...size).filter { !taken.contains($0) && isEligible(placed[$0], for: group) }
            guard let lowest = candidates.first else { return nil }
            let wantedColor = colorKey(group.filamentColor)
            let byColor = wantedColor.isEmpty ? nil
                : candidates.first { colorKey(placed[$0]?.filamentColor) == wantedColor }
            let chosen = byColor ?? lowest
            taken.insert(chosen)
            result[id] = chosen
        }
        return result
    }

    // MARK: Helpers

    /// A diameter rounded to hundredths, so "0.40" and "0.4" agree. nil when it doesn't parse.
    private static func diameter(_ text: String?) -> Int? {
        let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed) else { return nil }
        return Int((value * 100).rounded())
    }

    /// First six hex digits, lowercased, without a leading "#".
    private static func colorKey(_ color: String?) -> String {
        var text = (color ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        return String(text.prefix(6)).lowercased()
    }

    private static func describe(_ diameter: String, _ kind: String) -> String {
        let parts = [diameter.isEmpty ? "" : "\(diameter) mm", kind].filter { !$0.isEmpty }
        return parts.isEmpty ? "an unknown size" : parts.joined(separator: " ")
    }
}
