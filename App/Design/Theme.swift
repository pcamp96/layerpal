import SwiftUI
import UIKit

/// LayerPal palette ("spool teal") for iOS light/dark: teal accent on cool slate neutrals.
extension Color {
    static let accentTeal = Color(light: 0x0E8C7E, dark: 0x12A594)
    static let bgPrimary = Color(light: 0xF2F5F5, dark: 0x111517)
    static let bgCard = Color(light: 0xFFFFFF, dark: 0x1C2225)
    static let bgRaised = Color(light: 0xE1E8E8, dark: 0x2A3237)
    static let textMuted = Color(light: 0x5C6A70, dark: 0x86939A)
    static let textSecondary = Color(light: 0x3E4A4F, dark: 0xA9B4B9)
    static let hairline = Color(light: 0xD3DCDC, dark: 0x2A3237)
    static let statusWarning = Color(hex: 0xF2A42B)
    static let statusError = Color(hex: 0xE5484D)
    static let statusFinished = Color(hex: 0x6E8BFF)

    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }

    /// Bambu tray colors are "RRGGBBAA".
    init?(hexRGBA: String?) {
        guard let hex = hexRGBA, hex.count >= 6, let value = UInt64(hex.prefix(6), radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// Card surface used across the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.bgCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.hairline.opacity(0.6), lineWidth: 0.5))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Color.textSecondary).textCase(.uppercase)
            Spacer()
            if let trailing { Text(trailing).font(.footnote).foregroundStyle(Color.textMuted) }
        }
        .padding(.horizontal, 4)
    }
}

/// Thin progress bar used on printer cards.
struct FarmProgressBar: View {
    let value: Double // 0...100
    var tint: Color = .accentTeal
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.bgRaised)
                Capsule().fill(tint).frame(width: max(0, min(1, value / 100)) * geo.size.width)
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(value)) percent")
    }
}

struct Pill: View {
    let text: String
    var tint: Color = .textSecondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

func formatMinutes(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    if h >= 24 { return "\(h / 24)d \(h % 24)h" }
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

func formatHours(_ hours: Double) -> String {
    hours >= 10 ? "\(Int(hours.rounded()))h" : String(format: "%.1fh", hours)
}

func formatGrams(_ grams: Double) -> String {
    grams >= 1000 ? String(format: "%.1f kg", grams / 1000) : "\(Int(grams.rounded())) g"
}

extension View {
    /// Lists on Bambuddy's charcoal background instead of iOS black.
    func farmBackground() -> some View {
        scrollContentBackground(.hidden).background(Color.bgPrimary)
    }
}

/// Settings-style row icon on a tinted tile.
struct IconLabel: View {
    let title: String
    let symbol: String
    var tint: Color = .accentTeal

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
