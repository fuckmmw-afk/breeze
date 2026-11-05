import BreezeKit
import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        NavigationStack {
            List {
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

                Section {
                    toggleRow("Российские сайты напрямую", icon: "house.fill", color: .indigo, isOn: $state.settings.bypassRussia)
                    toggleRow("Блокировать рекламу", icon: "hand.raised.fill", color: .orange, isOn: $state.settings.blockAds)
                } header: {
                    Text("Маршрутизация")
                } footer: {
                    Text("В умном режиме домены .ru, .рф, Яндекс, VK и российские IP идут мимо VPN. Списки обновляются автоматически.")
                }
                .listRowBackground(Theme.card)

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
            .listStyle(.insetGrouped)
            .breezeList()
            .navigationTitle("Настройки")
        }
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
    @EnvironmentObject private var state: AppState
    @ObservedObject private var client: CommandClient

    init() {
        _client = ObservedObject(wrappedValue: AppStateLogClient.shared)
    }

    var body: some View {
        Group {
            if !state.tunnel.isConnected {
                ContentUnavailableView {
                    Label("Журнал пуст", systemImage: "text.alignleft")
                } description: {
                    Text("Записи появятся, когда VPN будет подключён.")
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(client.logList.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: line))
                                .textSelection(.enabled)
                                .listRowBackground(Theme.card)
                                .id(index)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: client.logList.count) { _, count in
                        if count > 0 {
                            proxy.scrollTo(count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .background(PageBackground())
        .navigationTitle("Журнал")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = client.logList.joined(separator: "\n")
                    state.show("Журнал скопирован")
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(client.logList.isEmpty)
            }
        }
        .onAppear { if state.tunnel.isConnected { client.connect() } }
        .onDisappear { client.disconnect() }
    }

    private func color(for line: String) -> Color {
        if line.contains("ERROR") || line.contains("FATAL") { return Theme.bad }
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
