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
                    Button {
                        choose(ConfigBuilder.autoTag)
                    } label: {
                        HStack(spacing: 14) {
                            IconTile(systemName: "bolt.fill", size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Самый быстрый")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.label)
                                Text(autoSubtitle)
                                    .font(.footnote)
                                    .foregroundStyle(Theme.secondaryLabel)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if state.currentSelection == ConfigBuilder.autoTag {
                                SelectedMark()
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .listRowBackground(Theme.card)
                }
            }

            Section {
                ForEach(filtered) { node in
                    Button {
                        choose(node.name)
                    } label: {
                        ServerRow(
                            node: node,
                            latency: state.latency(for: node.name),
                            selected: state.currentSelection == node.name,
                            active: state.effectiveServer?.name == node.name && state.currentSelection == ConfigBuilder.autoTag
                        )
                    }
                    .listRowBackground(Theme.card)
                }
            } header: {
                Text("\(state.activeSubscription?.name ?? "Серверы") · \(filtered.count)")
            }
        }
        .listStyle(.insetGrouped)
        .breezeList()
        .searchable(text: $query, prompt: "Поиск")
        .refreshable { await state.testLatency() }
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
