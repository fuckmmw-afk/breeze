import SwiftUI
import UIKit

enum Theme {
    static let accent = Color(light: 0x007AFF, dark: 0x0A84FF)
    static let accentDeep = Color(light: 0x0062E6, dark: 0x0A6CFF)
    static let accentSoft = Color(light: 0x5AA9FF, dark: 0x4A9DFF)

    static let background = Color(light: 0xF2F6FC, dark: 0x0A0E15)
    static let backgroundTop = Color(light: 0xE3EEFF, dark: 0x0F1A2C)
    static let card = Color(light: 0xFFFFFF, dark: 0x151B25)
    static let tint = Color(light: 0xE8F1FF, dark: 0x16263F)
    static let separator = Color(light: 0xE2E8F1, dark: 0x242C39)
    static let label = Color(light: 0x0B1A33, dark: 0xF2F5FA)
    static let secondaryLabel = Color(light: 0x8A94A6, dark: 0x8B95A7)

    static let good = Color(light: 0x34C759, dark: 0x30D158)
    static let fair = Color(light: 0xFF9F0A, dark: 0xFFB340)
    static let bad = Color(light: 0xFF3B30, dark: 0xFF453A)

    static let cardRadius: CGFloat = 24
    static let rowRadius: CGFloat = 16
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accentSoft, accent, accentDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func latencyColor(_ ms: Int) -> Color {
        if ms < 0 { return bad }
        if ms < 300 { return good }
        if ms < 800 { return fair }
        return bad
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Soft blue-white page background.
struct PageBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Theme.backgroundTop, Theme.background, Theme.background],
            startPoint: .top,
            endPoint: .center
        )
        .ignoresSafeArea()
    }
}

struct CardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var padding: CGFloat = 18
    var radius: CGFloat = Theme.cardRadius

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.card)
                    .shadow(color: colorScheme == .dark ? .clear : Color(red: 0.14, green: 0.42, blue: 0.84).opacity(0.08), radius: 20, x: 0, y: 8)
            )
    }
}

extension View {
    func card(padding: CGFloat = 18, radius: CGFloat = Theme.cardRadius) -> some View {
        modifier(CardModifier(padding: padding, radius: radius))
    }

    /// Inset-grouped list look on the blue-white background.
    func breezeList() -> some View {
        scrollContentBackground(.hidden)
            .background(PageBackground())
            .listSectionSpacing(Theme.sectionSpacing)
    }
}

struct SectionTitle: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.footnote.weight(.medium))
                .tracking(0.3)
                .foregroundStyle(Theme.secondaryLabel)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.horizontal, 6)
    }
}

/// Round badge with the server flag (or a globe).
struct FlagBadge: View {
    let flag: String?
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(Theme.tint)
            if let flag {
                Text(flag).font(.system(size: size * 0.55))
            } else {
                Image(systemName: "globe")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(width: size, height: size)
    }
}

/// iOS settings-style rounded square icon.
struct IconTile: View {
    let systemName: String
    var color: Color = Theme.accent
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color.gradient))
    }
}

struct LatencyBadge: View {
    let latency: Int?
    var testing = false

    var body: some View {
        Group {
            if testing {
                ProgressView().controlSize(.mini)
            } else if let latency {
                Text(latency < 0 ? "—" : "\(latency) мс")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.latencyColor(latency))
            } else {
                EmptyView()
            }
        }
        .padding(.horizontal, latency == nil && !testing ? 0 : 10)
        .padding(.vertical, 5)
        .background {
            if let latency, !testing {
                Capsule().fill(Theme.latencyColor(latency).opacity(0.12))
            }
        }
        .animation(.snappy, value: latency)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.accentGradient))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.tint))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

/// Pressable card without the default list highlight.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

enum Format {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func speed(_ value: Int64) -> String {
        "\(bytes(value))/с"
    }

    static func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: .now)
    }

    static func date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }
}
