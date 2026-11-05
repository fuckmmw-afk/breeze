import BreezeKit
import SwiftUI

struct ServersView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    var asSheet = false
    @State private var query = ""

    private var filtered: [ServerNode] {
        let servers = state.servers
        guard !query.isEmpty else { return servers }
        return servers.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.displayType.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if state.servers.isEmpty {
                    ContentUnavailableView {
                        Label("Нет серверов", systemImage: "globe")
                    } description: {
                        Text("Добавьте подписку на вкладке «Подписки».")
                    }
                    .background(PageBackground())
                } else {
                    list
                }
            }
            .navigationTitle("Серверы")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.testLatency() }
                    } label: {
                        if state.testingLatency {
                            ProgressView()
                        } else {
                            Label("Проверить задержку", systemImage: "bolt.horizontal.fill")
                        }
                    }
                    .disabled(state.servers.isEmpty)
                }
                if asSheet {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Готово") { dismiss() }
                    }
                }
            }
        }
    }

    private var list: some View {
        List {
            if state.servers.count > 1, query.isEmpty {
                Section {
                    AutoServerRow(
                        subtitle: autoSubtitle,
                        selected: state.currentSelection == ConfigBuilder.autoTag
                    ) {
                        choose(ConfigBuilder.autoTag)
                    }
                }
            }
            serverSection
        }
        .listStyle(.insetGrouped)
        .breezeList()
        .searchable(text: $query, prompt: "Поиск")
        .refreshable { await state.testLatency() }
    }

    private var serverSection: some View {
        let selection = state.currentSelection
        let activeAuto = selection == ConfigBuilder.autoTag ? state.effectiveServer?.name : nil
        let title = "\(state.activeSubscription?.name ?? "Серверы") · \(filtered.count)"
        return Section {
            ForEach(filtered) { node in
                ServerButtonRow(
                    node: node,
                    latency: state.latency(for: node.name),
                    selected: selection == node.name,
                    active: activeAuto == node.name
                ) {
                    choose(node.name)
                }
            }
        } header: {
            Text(title)
        }
    }

    private var autoSubtitle: String {
        if let server = state.effectiveServer, state.currentSelection == ConfigBuilder.autoTag {
            return "Сейчас: \(server.cleanName)"
        }
        return "Выбирает сервер с наименьшей задержкой"
    }

    private func choose(_ tag: String) {
        withAnimation(.snappy) { state.select(tag) }
        if asSheet {
            Task {
                try? await Task.sleep(nanoseconds: 250 * NSEC_PER_MSEC)
                dismiss()
            }
        }
    }
}

private struct AutoServerRow: View {
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                IconTile(systemName: "bolt.fill", size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Самый быстрый")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.label)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer()
                if selected {
                    SelectedMark()
                }
            }
            .padding(.vertical, 6)
        }
        .listRowBackground(Theme.card)
    }
}

private struct ServerButtonRow: View {
    let node: ServerNode
    let latency: Int?
    let selected: Bool
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ServerRow(node: node, latency: latency, selected: selected, active: active)
        }
        .listRowBackground(Theme.card)
    }
}

struct ServerRow: View {
    let node: ServerNode
    let latency: Int?
    let selected: Bool
    var active = false

    var body: some View {
        HStack(spacing: 14) {
            FlagBadge(flag: node.flag, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(node.cleanName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text([node.displayType, node.transportLabel].compactMap { $0 }.joined(separator: " · "))
                    if active {
                        Text("авто")
                            .foregroundStyle(Theme.accent)
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.secondaryLabel)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            LatencyBadge(latency: latency)
            if selected {
                SelectedMark()
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

struct SelectedMark: View {
    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.title3)
            .foregroundStyle(.white, Theme.accent)
            .transition(.scale.combined(with: .opacity))
    }
}
