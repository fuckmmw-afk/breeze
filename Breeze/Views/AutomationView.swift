import BreezeKit
import SwiftUI

/// "On Wi‑Fi use this server, on cellular pick the fastest of that group."
struct AutomationView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        List {
            Section {
                Toggle(isOn: $state.settings.automation.enabled) {
                    HStack(spacing: 14) {
                        IconTile(systemName: "wand.and.stars", color: .purple)
                        Text("Переключать по сети").foregroundStyle(Theme.label)
                    }
                    .padding(.vertical, 2)
                }
                .tint(Theme.accent)
            } footer: {
                Text("Туннель сам выбирает правило при подключении и при каждой смене Wi‑Fi ↔ сотовая сеть, даже когда приложение закрыто. Для группы сразу проверяется задержка всех её серверов и включается самый быстрый. Сервер, выбранный вручную, действует до смены сети.")
            }
            .listRowBackground(Theme.card)

            if state.settings.automation.enabled {
                ForEach(NetworkKind.allCases) { kind in
                    RuleSection(kind: kind)
                }
                Section {
                    HStack {
                        Text("Сейчас").foregroundStyle(Theme.label)
                        Spacer()
                        Text(state.network?.title ?? "нет сети").foregroundStyle(Theme.secondaryLabel)
                    }
                }
                .listRowBackground(Theme.card)
            }
        }
        .listStyle(.insetGrouped)
        .breezeList()
        .navigationTitle("Автоматизации")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.snappy, value: state.settings.automation)
    }
}

private struct RuleSection: View {
    @EnvironmentObject private var state: AppState
    let kind: NetworkKind
    @State private var keywords = ""

    private var target: Binding<AutomationTarget> {
        $state.settings.automation[kind]
    }

    var body: some View {
        let rule = target.wrappedValue
        Section {
            Picker("Действие", selection: target.kind) {
                Text("Не менять").tag(AutomationTarget.Kind.off)
                Text("Сервер").tag(AutomationTarget.Kind.server)
                Text("Группа").tag(AutomationTarget.Kind.group)
            }
            .pickerStyle(.segmented)
            .padding(.vertical, 4)

            switch rule.kind {
            case .off:
                EmptyView()
            case .server:
                NavigationLink {
                    AutomationServerPicker(kind: kind, multiple: false)
                } label: {
                    HStack {
                        Text("Сервер").foregroundStyle(Theme.label)
                        Spacer()
                        Text(serverTitle(rule.server))
                            .foregroundStyle(Theme.secondaryLabel)
                            .lineLimit(1)
                    }
                }
            case .group:
                HStack(spacing: 12) {
                    Image(systemName: "text.magnifyingglass")
                        .foregroundStyle(Theme.accent)
                    TextField("Слова в названии, через запятую", text: $keywords)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(commitKeywords)
                        .foregroundStyle(Theme.label)
                }
                NavigationLink {
                    AutomationServerPicker(kind: kind, multiple: true)
                } label: {
                    HStack {
                        Text("Выбрать вручную").foregroundStyle(Theme.label)
                        Spacer()
                        Text(rule.servers.isEmpty ? "нет" : "\(rule.servers.count)")
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
            }
        } header: {
            Label(kind.title, systemImage: kind == .wifi ? "wifi" : "antenna.radiowaves.left.and.right")
        } footer: {
            Text(footer(rule))
        }
        .listRowBackground(Theme.card)
        .onAppear { keywords = rule.keywords }
        .onDisappear(perform: commitKeywords)
    }

    private func commitKeywords() {
        // committed on Return / leaving the screen, not per keystroke: every change reloads the tunnel
        let value = keywords.trimmingCharacters(in: .whitespaces)
        if target.wrappedValue.keywords != value {
            target.wrappedValue.keywords = value
        }
    }

    private func serverTitle(_ name: String?) -> String {
        guard let name else { return "не выбран" }
        return state.servers.first { $0.name == name }?.cleanName ?? "нет в подписке"
    }

    private func footer(_ rule: AutomationTarget) -> String {
        switch rule.kind {
        case .off:
            return "В этой сети сервер не меняется."
        case .server:
            return rule.members(in: state.servers).isEmpty
                ? "Выберите сервер из активной подписки."
                : "В этой сети всегда этот сервер."
        case .group:
            var preview = rule
            preview.keywords = keywords
            let count = preview.members(in: state.servers).count
            if count == 0 {
                return "Например «LTE» — войдут все серверы, в названии которых есть это слово. Можно добавить серверы и вручную."
            }
            return "В группе \(count) \(Self.servers(count)). При переходе в эту сеть они проверяются и включается самый быстрый."
        }
    }

    static func servers(_ count: Int) -> String {
        let mod10 = count % 10, mod100 = count % 100
        if mod10 == 1, mod100 != 11 { return "сервер" }
        if (2 ... 4).contains(mod10), !(12 ... 14).contains(mod100) { return "сервера" }
        return "серверов"
    }
}

/// Server list for a rule: one server, or a hand-picked set for a group.
private struct AutomationServerPicker: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let kind: NetworkKind
    let multiple: Bool
    @State private var query = ""

    private var target: Binding<AutomationTarget> {
        $state.settings.automation[kind]
    }

    private var filtered: [ServerNode] {
        guard !query.isEmpty else { return state.servers }
        return state.servers.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let rule = target.wrappedValue
        let picked = Set(rule.servers)
        let words = rule.keywordList
        List {
            Section {
                ForEach(filtered) { node in
                    let byKeyword = multiple && words.contains { node.name.localizedCaseInsensitiveContains($0) }
                    let selected = multiple ? picked.contains(node.name) : rule.server == node.name
                    Button {
                        toggle(node.name)
                    } label: {
                        HStack(spacing: 14) {
                            FlagBadge(flag: node.flag, size: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.cleanName)
                                    .foregroundStyle(Theme.label)
                                    .lineLimit(2)
                                if byKeyword {
                                    Text("входит по ключевому слову")
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryLabel)
                                }
                            }
                            Spacer(minLength: 8)
                            LatencyBadge(latency: state.latency(for: node.name), testing: state.pingPending.contains(node.name))
                            Image(systemName: selected || byKeyword ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected ? Theme.accent : Theme.secondaryLabel.opacity(byKeyword ? 0.8 : 0.4))
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button {
                            Task { await state.ping(node.name) }
                        } label: {
                            Label("Пинг", systemImage: "bolt.horizontal.fill")
                        }
                        .tint(Theme.accent)
                    }
                }
            } footer: {
                if multiple {
                    Text("Отмечено вручную: \(rule.servers.count). Серверы с ключевым словом входят в группу автоматически.")
                }
            }
            .listRowBackground(Theme.card)
        }
        .listStyle(.insetGrouped)
        .breezeList()
        .searchable(text: $query, prompt: "Поиск")
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if multiple {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Отметить найденные") {
                            var servers = target.wrappedValue.servers
                            for node in filtered where !servers.contains(node.name) {
                                servers.append(node.name)
                            }
                            target.wrappedValue.servers = servers
                        }
                        Button("Снять все", role: .destructive) {
                            target.wrappedValue.servers = []
                        }
                    } label: {
                        Image(systemName: "checklist")
                    }
                }
            }
        }
    }

    private func toggle(_ name: String) {
        if multiple {
            var servers = target.wrappedValue.servers
            if let index = servers.firstIndex(of: name) {
                servers.remove(at: index)
            } else {
                servers.append(name)
            }
            target.wrappedValue.servers = servers
        } else {
            target.wrappedValue.server = name
            dismiss()
        }
    }
}
