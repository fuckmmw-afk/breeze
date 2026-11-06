import AppIntents
import Foundation

/// Toggle used by the Control Center control, widget buttons and Shortcuts.
struct ToggleVPNIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Переключить VPN"
    static var description = IntentDescription("Включает или выключает Breeze.")

    @Parameter(title: "Включён")
    var value: Bool

    init() {}

    init(value: Bool) {
        self.value = value
    }

    func perform() async throws -> some IntentResult {
        try await BreezeIntentActions.set(connected: value)
        return .result()
    }
}

struct ConnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Включить VPN"
    static var description = IntentDescription("Подключает Breeze с последними настройками.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BreezeIntentActions.set(connected: true)
        return .result(dialog: "Breeze подключается")
    }
}

struct DisconnectVPNIntent: AppIntent {
    static var title: LocalizedStringResource = "Выключить VPN"
    static var description = IntentDescription("Отключает Breeze.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await BreezeIntentActions.set(connected: false)
        return .result(dialog: "Breeze отключён")
    }
}

struct VPNStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Статус VPN"
    static var description = IntentDescription("Сообщает, подключён ли Breeze. Возвращает да/нет для автоматизаций.")

    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let active = await VPNController.isActive()
        var text = active ? "Breeze подключён" : "Breeze выключен"
        if active, let server = WidgetStore.load()?.serverName {
            text += " · \(server)"
        }
        return .result(value: active, dialog: IntentDialog(stringLiteral: text))
    }
}

enum BreezeIntentActions {
    static func set(connected: Bool) async throws {
        #if BREEZE_APP
            try await AppIntentBridge.set(connected: connected)
        #else
            if connected {
                try await VPNController.start()
            } else {
                try await VPNController.stop()
            }
        #endif
        await VPNController.waitUntilSettled(timeout: connected ? 6 : 3)
        WidgetStore.reloadAll()
    }
}
