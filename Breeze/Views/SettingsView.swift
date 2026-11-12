import BreezeKit
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            List {
                modeSection
                routingSection
                networkSection
                pingSection
                iosSection
                subscriptionSection
                diagnosticsSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .breezeList()
            .navigationTitle("Настройки")
        }
    }

    private var modeSection: some View {
        Section {
            ForEach(RoutingMode.allCases) { mode in
                Button {
                    withAnimation(.snappy) { state.setMode(mode) }
                } label: {
                    HStack(spacing: 14) {
                        IconTile(systemName: icon(for: mode), color: color(for: mode))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mode.title).foregroundStyle(Theme.label)
                            Text(mode.subtitle)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        Spacer()
                        if state.settings.routingMode == mode {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text("Режим")
        }
        .listRowBackground(Theme.card)
    }

    private var routingSection: some View {
        Section {
            toggleRow("Российские сайты напрямую", icon: "house.fill", color: .indigo, isOn: $state.settings.bypassRussia)
            toggleRow("Блокировать рекламу", icon: "hand.raised.fill", color: .orange, isOn: $state.settings.blockAds)
        } header: {
            Text("Маршрутизация")
        } footer: {
            Text("В умном режиме домены .ru, .рф, Яндекс, VK и российские IP идут мимо VPN. Списки обновляются автоматически.")
        }
        .listRowBackground(Theme.card)
    }

    private var networkSection: some View {
        Section {
            Picker(selection: $state.settings.dns) {
                ForEach(DNSPreset.allCases) { Text($0.title).tag($0) }
            } label: {
                rowLabel("DNS через VPN", icon: "network", color: Theme.accent)
            }
            toggleRow("IPv6", icon: "6.circle.fill", color: .teal, isOn: $state.settings.enableIPv6)
            toggleRow("Push Apple мимо VPN", icon: "bell.badge.fill", color: .red, isOn: $state.settings.excludeAPNs)
        } header: {
            Text("Сеть")
        } footer: {
            Text("Push-уведомления надёжнее приходят, если серверы Apple не заворачивать в туннель.")
        }
        .listRowBackground(Theme.card)
    }

    private var pingSection: some View {
        Section {
            ForEach(PingMethod.allCases) { method in
                Button {
                    state.settings.pingMethod = method
                } label: {
                    HStack(spacing: 14) {
                        IconTile(systemName: method == .url ? "arrow.left.arrow.right" : "bolt.horizontal.fill", color: method == .url ? Theme.accent : .teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(method.title).foregroundStyle(Theme.label)
                            Text(method.subtitle)
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryLabel)
                        }
                        Spacer()
                        if state.settings.pingMethod == method {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Picker(selection: $state.settings.urlTestURL) {
                ForEach(AppSettings.urlTestPresets, id: \.url) { preset in
                    Text(preset.title).tag(preset.url)
                }
                if !AppSettings.urlTestPresets.contains(where: { $0.url == state.settings.urlTestURL }) {
                    Text("Свой").tag(state.settings.urlTestURL)
                }
            } label: {
                rowLabel("Адрес проверки", icon: "link", color: .indigo)
            }
            Picker(selection: $state.settings.pingTimeout) {
                ForEach([2000, 3000, 5000, 8000, 10000], id: \.self) { value in
                    Text("\(value / 1000) с").tag(value)
                }
            } label: {
                rowLabel("Таймаут", icon: "timer", color: .orange)
            }
            toggleRow("Проверять при открытии", icon: "arrow.clockwise", color: .green, isOn: $state.settings.pingOnOpen)
        } header: {
            Text("Проверка задержки")
        } footer: {
            Text("Когда VPN подключён, задержку всегда меряет само ядро через серверы. Адрес проверки также используется для автовыбора самого быстрого сервера.")
        }
        .listRowBackground(Theme.card)
    }

    private var iosSection: some View {
        Section {
            toggleRow("Подключаться автоматически", icon: "bolt.shield.fill", color: Theme.accent, isOn: $state.settings.connectOnDemand)
            toggleRow("Live Activity", icon: "capsule.portrait.fill", color: .purple, isOn: $state.settings.liveActivity)
            VStack(alignment: .leading, spacing: 10) {
                integrationHint("switch.2", "Пункт управления: «+» → Breeze VPN")
                integrationHint("lock.fill", "Экран блокировки и рабочий стол: виджет Breeze")
                integrationHint("square.stack.3d.up.fill", "Команды и Siri: «Включи Breeze», «Выключи Breeze», «Режим Breeze»")
                integrationHint("link", "Ссылки: breeze://connect, breeze://disconnect, breeze://toggle")
            }
            .padding(.vertical, 6)
        } header: {
            Text("iOS")
        } footer: {
            Text("Автоподключение включает VPN при появлении сети (On Demand). Live Activity показывает статус и время подключения в Dynamic Island.")
        }
        .listRowBackground(Theme.card)
    }

    private var subscriptionSection: some View {
        Section {
            toggleRow("Автообновление", icon: "arrow.triangle.2.circlepath", color: .green, isOn: $state.settings.autoUpdateSubscriptions)
            HStack(spacing: 14) {
                IconTile(systemName: "person.text.rectangle.fill", color: .gray)
                TextField("User-Agent", text: $state.settings.subscriptionUserAgent)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.label)
            }
            .padding(.vertical, 2)
        } header: {
            Text("Подписки")
        } footer: {
            Text("Некоторые провайдеры отдают разный формат в зависимости от User-Agent.")
        }
        .listRowBackground(Theme.card)
    }

    private var diagnosticsSection: some View {
        Section {
            NavigationLink {
                LogsView()
            } label: {
                rowLabel("Журнал", icon: "text.alignleft", color: .gray)
            }
            NavigationLink {
                ConfigPreviewView()
            } label: {
                rowLabel("Конфигурация sing-box", icon: "curlybraces", color: .purple)
            }
            Picker(selection: $state.settings.logLevel) {
                ForEach(["error", "warn", "info", "debug"], id: \.self) { Text($0).tag($0) }
            } label: {
                rowLabel("Уровень журнала", icon: "slider.horizontal.3", color: .gray)
            }
        } header: {
            Text("Диагностика")
        }
        .listRowBackground(Theme.card)
    }

    private var aboutSection: some View {
        Section {
            infoRow("Версия", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
            infoRow("Ядро", "sing-box \(LibboxBootstrap.coreVersion)")
        } header: {
            Text("О приложении")
        } footer: {
            Text("Breeze работает на ядре sing-box. Распространяется под GPL-3.0.")
        }
        .listRowBackground(Theme.card)
    }

    private func toggleRow(_ title: String, icon: String, color: Color, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            rowLabel(title, icon: icon, color: color)
        }
        .tint(Theme.accent)
    }

    private func rowLabel(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 14) {
            IconTile(systemName: icon, color: color)
            Text(title).foregroundStyle(Theme.label)
        }
        .padding(.vertical, 2)
    }

    private func integrationHint(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.secondaryLabel)
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.label)
            Spacer()
            Text(value).foregroundStyle(Theme.secondaryLabel)
        }
    }

    private func icon(for mode: RoutingMode) -> String {
        switch mode {
        case .rule: return "sparkles"
        case .global: return "globe"
        case .direct: return "arrow.right"
        }
    }

    private func color(for mode: RoutingMode) -> Color {
        switch mode {
        case .rule: return Theme.accent
        case .global: return .indigo
        case .direct: return .gray
        }
    }
}

struct LogsView: View {
    enum Source: String, CaseIterable, Identifiable {
        case app = "Приложение"
        case startup = "Запуск"
        case live = "Онлайн"
        case core = "Ядро"
        case crash = "Сбои"
        var id: String { rawValue }
    }

    @EnvironmentObject private var state: AppState
    @ObservedObject private var client: CommandClient
    @ObservedObject private var events = EventLog.shared
    @State private var source: Source = .app
    @State private var signing = ""
    @State private var fileText: String?
    @State private var refreshTick = 0

    init() {
        _client = ObservedObject(wrappedValue: AppStateLogClient.shared)
    }

    private var lines: [String] {
        if source == .live {
            return client.logList
        }
        if source == .app {
            return signing.split(separator: "\n").map(String.init) + ["———"] + events.lines
        }
        return (fileText ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Источник", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.pagePadding)
            .padding(.vertical, 12)

            if lines.isEmpty {
                ContentUnavailableView {
                    Label("Записей нет", systemImage: "text.alignleft")
                } description: {
                    Text(emptyDescription)
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .listRowBackground(Theme.card)
                                .id(index)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
                    .onChange(of: lines.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
            }

            diagnosticsFooter
        }
        .background(PageBackground())
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = fullReport()
                    state.show("Отчёт скопирован")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
        .onAppear {
            source = state.tunnel.isConnected ? .live : .app
            signing = SigningInfo.report()
            if state.tunnel.isConnected { client.connect() }
            reload()
        }
        .onDisappear { client.disconnect() }
        .onChange(of: source) { _, _ in reload() }
        .onChange(of: state.tunnel.status) { _, status in
            if status == .connected { client.connect() }
            reload()
        }
        .task {
            // files keep growing while the tunnel starts; poll them
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
                reload()
            }
        }
    }

    private var diagnosticsFooter: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Статус: \(statusText) · группа: \(state.sharedGroup ?? "нет")")
            Text("Расширение: \(TunnelManager.tunnelBundleIdentifier) · порт \(LibboxBootstrap.commandPort)")
            if let error = state.tunnel.lastError {
                Text("Ошибка: \(error)").foregroundStyle(Theme.bad)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(Theme.secondaryLabel)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pagePadding)
        .padding(.vertical, 10)
        .textSelection(.enabled)
    }

    private var emptyDescription: String {
        switch source {
        case .app:
            return "Событий пока нет."
        case .live:
            return "Онлайн-журнал работает, когда VPN подключён."
        case .startup:
            if state.sharedGroup == nil {
                return "Нет общей группы в профиле подписи, поэтому расширение не может оставить записи."
            }
            return "Расширение ещё не запускалось. Если записей нет и после попытки подключения, система не смогла запустить расширение (обычно это проблема подписи)."
        case .core:
            return "Ядро ещё ничего не записало."
        case .crash:
            return "Сбоев не было."
        }
    }

    private var statusText: String {
        switch state.tunnel.status {
        case .connected: return "подключено"
        case .connecting: return "подключение"
        case .disconnecting: return "отключение"
        case .reasserting: return "переподключение"
        case .disconnected: return "отключено"
        case .invalid: return "не настроено"
        @unknown default: return "?"
        }
    }

    private func reload() {
        switch source {
        case .live, .app:
            fileText = nil
        case .startup:
            let launch = DiagnosticLog.read(DiagnosticLog.launchName, group: state.sharedGroup, maxBytes: 8 * 1024)
            let diag = DiagnosticLog.read(DiagnosticLog.fileName, group: state.sharedGroup)
            fileText = [launch.map { "— запуски процесса —\n" + $0 }, diag.map { "— последний старт —\n" + $0 }]
                .compactMap { $0 }
                .joined(separator: "\n")
        case .core:
            fileText = DiagnosticLog.read(DiagnosticLog.boxLogName, group: state.sharedGroup)
        case .crash:
            fileText = DiagnosticLog.read(DiagnosticLog.stderrName, group: state.sharedGroup)
        }
    }

    private func fullReport() -> String {
        let group = state.sharedGroup
        return [
            "Breeze \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") core \(LibboxBootstrap.coreVersion)",
            "status: \(statusText), group: \(group ?? "none"), extension: \(TunnelManager.tunnelBundleIdentifier), port: \(LibboxBootstrap.commandPort)",
            "error: \(state.tunnel.lastError ?? "none")",
            "--- signing", SigningInfo.report(),
            "--- app events", events.lines.joined(separator: "\n"),
            "--- launches", DiagnosticLog.read(DiagnosticLog.launchName, group: group, maxBytes: 8 * 1024) ?? "(empty)",
            "--- startup", DiagnosticLog.read(DiagnosticLog.fileName, group: group) ?? "(empty)",
            "--- core", DiagnosticLog.read(DiagnosticLog.boxLogName, group: group, maxBytes: 16 * 1024) ?? "(empty)",
            "--- stderr", DiagnosticLog.read(DiagnosticLog.stderrName, group: group, maxBytes: 16 * 1024) ?? "(empty)",
            "--- live", client.logList.suffix(200).joined(separator: "\n"),
        ].joined(separator: "\n")
    }

    private func color(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("FATAL") || line.contains("FAILED") || line.contains("panic") || line.contains("НЕТ") || line.contains("НЕ НАЙДЕНО") { return Theme.bad }
        if line.contains("WARN") { return Theme.fair }
        return Theme.label
    }
}

/// The log stream lives as long as the app so reopening the screen is instant.
enum AppStateLogClient {
    static let shared = CommandClient(.log, logMaxLines: 800)
}

struct ConfigPreviewView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let config = state.buildConfig()
        ScrollView {
            Text(config)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.label)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card(padding: 16, radius: 18)
                .padding(Theme.pagePadding)
        }
        .background(PageBackground())
        .navigationTitle("Конфигурация")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = config
                    state.show("Конфигурация скопирована")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
            }
        }
    }
}
