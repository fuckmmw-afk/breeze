import ActivityKit
import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

@main
struct BreezeWidgetsBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        VPNControl()
        BreezeLiveActivity()
    }
}

private let accent = Color(red: 0, green: 0.48, blue: 1)
private let accentGradient = LinearGradient(
    colors: [Color(red: 0.35, green: 0.66, blue: 1), accent, Color(red: 0, green: 0.38, blue: 0.9)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

// MARK: - Control Center

struct VPNControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: WidgetStore.controlKind, provider: Provider()) { isOn in
            ControlWidgetToggle("Breeze", isOn: isOn, action: ToggleVPNIntent()) { isOn in
                Label(isOn ? "Подключено" : "Выключено", systemImage: isOn ? "shield.lefthalf.filled" : "shield.slash")
            }
            .tint(accent)
        }
        .displayName("Breeze VPN")
        .description("Включить или выключить VPN.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            await VPNController.isActive()
        }
    }
}

// MARK: - Home & Lock Screen

struct StatusEntry: TimelineEntry {
    let date: Date
    let status: NEVPNStatus
    let since: Date?
    let snapshot: WidgetSnapshot?

    var active: Bool { status == .connected || status == .connecting || status == .reasserting }
    var connected: Bool { status == .connected }

    var statusText: String {
        switch status {
        case .connected: return "Подключено"
        case .connecting, .reasserting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .invalid: return "Не настроено"
        default: return "Выключено"
        }
    }

    var serverText: String {
        guard let snapshot else { return "Breeze" }
        return [snapshot.flag, snapshot.serverName].compactMap { $0 }.joined(separator: " ")
    }
}

struct StatusProvider: TimelineProvider {
    func placeholder(in _: Context) -> StatusEntry {
        StatusEntry(date: .now, status: .connected, since: .now.addingTimeInterval(-754), snapshot: WidgetSnapshot(serverName: "Германия", flag: "🇩🇪", mode: "Умный", subscription: nil, updatedAt: .now))
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        Task { completion(await current()) }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        Task {
            let entry = await current()
            completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(15 * 60))))
        }
    }

    private func current() async -> StatusEntry {
        let status = await VPNController.status()
        let since = await VPNController.connectedDate()
        return StatusEntry(date: .now, status: status, since: since, snapshot: WidgetStore.load())
    }
}

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WidgetStore.statusKind, provider: StatusProvider()) { entry in
            StatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Breeze")
        .description("Статус VPN и кнопка подключения.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct StatusWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StatusEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .accessoryInline:
            Label("Breeze: \(entry.statusText.lowercased())", systemImage: entry.connected ? "shield.lefthalf.filled" : "shield.slash")
                .containerBackground(.clear, for: .widget)
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var toggle: ToggleVPNIntent {
        ToggleVPNIntent(value: !entry.active)
    }

    private var circular: some View {
        Button(intent: toggle) {
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: entry.connected ? "shield.lefthalf.filled" : "shield.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .widgetAccentable()
            }
        }
        .buttonStyle(.plain)
        .containerBackground(.clear, for: .widget)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Label("Breeze", systemImage: entry.connected ? "shield.lefthalf.filled" : "shield.slash")
                .font(.headline)
                .widgetAccentable()
            Text(entry.statusText)
                .font(.caption)
            if entry.connected {
                Text(entry.serverText)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.clear, for: .widget)
    }

    private var powerButton: some View {
        Button(intent: toggle) {
            Image(systemName: "power")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(entry.active ? .white : accent)
                .frame(width: 46, height: 46)
                .background(Circle().fill(entry.active ? AnyShapeStyle(accentGradient) : AnyShapeStyle(accent.opacity(0.12))))
        }
        .buttonStyle(.plain)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                powerButton
                Spacer()
                Image(systemName: entry.connected ? "checkmark.shield.fill" : "shield")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(entry.connected ? accent : .secondary)
            }
            Spacer()
            Text(entry.statusText)
                .font(.headline)
            Text(entry.connected ? entry.serverText : "Breeze")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if entry.connected, let since = entry.since {
                Text(since, style: .timer)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.89, green: 0.93, blue: 1), .white], startPoint: .top, endPoint: .bottom)
        }
    }

    private var medium: some View {
        HStack(spacing: 18) {
            powerButton.scaleEffect(1.25).frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.statusText).font(.title3.weight(.semibold))
                Text(entry.serverText).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                HStack(spacing: 8) {
                    if let mode = entry.snapshot?.mode {
                        Text(mode)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(accent.opacity(0.12)))
                    }
                    if entry.connected, let since = entry.since {
                        Text(since, style: .timer)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.89, green: 0.93, blue: 1), .white], startPoint: .top, endPoint: .bottom)
        }
    }
}

// MARK: - Live Activity / Dynamic Island

struct BreezeLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BreezeActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Circle().fill(accentGradient))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Breeze · \(context.state.mode)")
                        .font(.headline)
                    Text([context.state.flag, context.state.serverName].compactMap { $0 }.joined(separator: " "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(timerInterval: context.state.since ... Date.distantFuture, countsDown: false)
                    .font(.headline.monospacedDigit())
                    .multilineTextAlignment(.trailing)
                    .frame(width: 80)
            }
            .padding(18)
            .activityBackgroundTint(Color.white.opacity(0.9))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Breeze", systemImage: "shield.lefthalf.filled")
                        .font(.headline)
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.since ... Date.distantFuture, countsDown: false)
                        .font(.headline.monospacedDigit())
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text([context.state.flag, context.state.serverName].compactMap { $0 }.joined(separator: " "))
                            .lineLimit(1)
                        Spacer()
                        Text(context.state.mode)
                            .foregroundStyle(accent)
                    }
                    .font(.subheadline)
                }
            } compactLeading: {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(timerInterval: context.state.since ... Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .frame(width: 48)
                    .font(.caption2)
            } minimal: {
                Image(systemName: "shield.lefthalf.filled")
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}
