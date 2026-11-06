import ActivityKit
import AppIntents
import BreezeKit
import Foundation

/// App-process side of the shared intents: uses the full app state, so a connect
/// from Shortcuts builds a fresh config with the current settings.
@MainActor
enum AppIntentBridge {
    static func set(connected: Bool) async throws {
        let state = AppState.shared
        await state.tunnel.load()
        if connected {
            if state.tunnel.isConnected { return }
            await state.connect()
            if let error = state.tunnel.lastError {
                throw BreezeError(error)
            }
        } else {
            await state.tunnel.stop()
        }
    }
}

enum RoutingModeAppEnum: String, AppEnum {
    case rule = "Rule"
    case global = "Global"
    case direct = "Direct"

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Режим"
    static var caseDisplayRepresentations: [RoutingModeAppEnum: DisplayRepresentation] = [
        .rule: "Умный",
        .global: "Всё через VPN",
        .direct: "Напрямую",
    ]
}

struct SetRoutingModeIntent: AppIntent {
    static var title: LocalizedStringResource = "Режим Breeze"
    static var description = IntentDescription("Переключает режим маршрутизации: умный, всё через VPN или напрямую.")

    @Parameter(title: "Режим")
    var mode: RoutingModeAppEnum

    static var parameterSummary: some ParameterSummary {
        Summary("Режим Breeze: \(\.$mode)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = AppState.shared
        await state.tunnel.load()
        if let mode = RoutingMode(rawValue: mode.rawValue) {
            state.setMode(mode)
            return .result(dialog: "Режим: \(mode.title)")
        }
        return .result(dialog: "Неизвестный режим")
    }
}

struct BreezeShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: ["Включи \(.applicationName)", "Подключи \(.applicationName)", "Turn on \(.applicationName)"],
            shortTitle: "Включить VPN",
            systemImageName: "shield.lefthalf.filled"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: ["Выключи \(.applicationName)", "Отключи \(.applicationName)", "Turn off \(.applicationName)"],
            shortTitle: "Выключить VPN",
            systemImageName: "shield.slash"
        )
        AppShortcut(
            intent: VPNStatusIntent(),
            phrases: ["Статус \(.applicationName)", "\(.applicationName) включён?"],
            shortTitle: "Статус VPN",
            systemImageName: "info.circle"
        )
        AppShortcut(
            intent: SetRoutingModeIntent(),
            phrases: ["Смени режим \(.applicationName)", "Режим \(.applicationName)"],
            shortTitle: "Режим",
            systemImageName: "arrow.triangle.branch"
        )
    }

    static var shortcutTileColor: ShortcutTileColor = .blue
}

/// Dynamic Island / Lock Screen activity while the VPN is up.
@MainActor
enum LiveActivityController {
    static func update(connected: Bool, enabled: Bool, server: String, flag: String?, mode: String, since: Date?) {
        let activities = Activity<BreezeActivityAttributes>.activities
        guard enabled, connected else {
            for activity in activities {
                Task { await activity.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        let state = BreezeActivityAttributes.ContentState(serverName: server, flag: flag, mode: mode, since: since ?? .now)
        if let activity = activities.first {
            Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
            for extra in activities.dropFirst() {
                Task { await extra.end(nil, dismissalPolicy: .immediate) }
            }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        _ = try? Activity.request(
            attributes: BreezeActivityAttributes(title: "Breeze"),
            content: ActivityContent(state: state, staleDate: nil),
            pushType: nil
        )
    }
}
