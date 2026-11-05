import BreezeKit
import SwiftUI
import UIKit

struct SubscriptionsView: View {
    @EnvironmentObject private var state: AppState
    @State private var showAdd = false
    @State private var renaming: ProxySubscription?
    @State private var newName = ""
    @State private var deleting: ProxySubscription?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if state.subscriptions.isEmpty {
                        emptyState
                    }
                    ForEach(state.subscriptions) { subscription in
                        SubscriptionCard(
                            subscription: subscription,
                            active: subscription.id == state.activeSubscription?.id,
                            updating: state.updatingIDs.contains(subscription.id)
                        )
                        .onTapGesture {
                            withAnimation(.snappy) { state.activate(subscription.id) }
                        }
                        .contextMenu { menu(for: subscription) }
                    }
                    if !state.subscriptions.isEmpty {
                        Text("Нажмите на подписку, чтобы сделать её активной. Удерживайте для действий.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryLabel)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.top, 8)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.vertical, 12)
            }
            .background(PageBackground())
            .navigationTitle("Подписки")
            .refreshable { await state.updateAll() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAdd = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel("Добавить подписку")
                }
            }
            .sheet(isPresented: $showAdd) {
                AddSubscriptionSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .alert("Переименовать", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Название", text: $newName)
                Button("Готово") {
                    if let renaming { state.rename(renaming.id, to: newName) }
                    renaming = nil
                }
                Button("Отмена", role: .cancel) { renaming = nil }
            }
            .confirmationDialog(
                "Удалить «\(deleting?.name ?? "")»?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Удалить", role: .destructive) {
                    if let deleting {
                        withAnimation(.snappy) { state.delete(deleting.id) }
                    }
                    deleting = nil
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for subscription: ProxySubscription) -> some View {
        if subscription.kind == .remote {
            Button {
                Task { await state.update(subscription.id) }
            } label: {
                Label("Обновить", systemImage: "arrow.clockwise")
            }
            if let url = subscription.url {
                Button {
                    UIPasteboard.general.string = url
                    state.show("Ссылка скопирована")
                } label: {
                    Label("Скопировать ссылку", systemImage: "doc.on.doc")
                }
            }
        }
        Button {
            newName = subscription.name
            renaming = subscription
        } label: {
            Label("Переименовать", systemImage: "pencil")
        }
        Button(role: .destructive) {
            deleting = subscription
        } label: {
            Label("Удалить", systemImage: "trash")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(Theme.tint).frame(width: 96, height: 96)
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            VStack(spacing: 6) {
                Text("Пока пусто")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.label)
                Text("Добавьте ссылку на подписку или вставьте ключи вида vless://, vmess://, trojan://, ss://, hy2://")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
                    .multilineTextAlignment(.center)
            }
            Button("Добавить подписку") { showAdd = true }
                .buttonStyle(PrimaryButtonStyle())
        }
        .card(padding: 28)
        .padding(.top, 24)
    }
}

private struct SubscriptionCard: View {
    let subscription: ProxySubscription
    let active: Bool
    let updating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(systemName: subscription.kind == .remote ? "link" : "doc.text.fill", color: active ? Theme.accent : Theme.secondaryLabel, size: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(subscription.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(details)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer()
                if updating {
                    ProgressView()
                } else if active {
                    SelectedMark()
                }
            }
            if let traffic = subscription.traffic {
                VStack(alignment: .leading, spacing: 8) {
                    if traffic.total > 0 {
                        UsageBar(fraction: traffic.fraction)
                    }
                    HStack {
                        Text(traffic.total > 0 ? "\(Format.bytes(traffic.used)) из \(Format.bytes(traffic.total))" : "\(Format.bytes(traffic.used)) · безлимит")
                        Spacer()
                        if let expire = traffic.expire {
                            Text("до \(Format.date(expire))")
                                .foregroundStyle(expire < .now ? Theme.bad : Theme.secondaryLabel)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryLabel)
                }
            }
        }
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(active ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
    }

    private var details: String {
        var parts = ["\(subscription.servers.count) серверов"]
        if let updated = subscription.updatedAt {
            parts.append("обновлено \(Format.relative(updated))")
        } else if subscription.kind == .local {
            parts.append("вручную")
        }
        return parts.joined(separator: " · ")
    }
}

struct AddSubscriptionSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case link = "Ссылка"
        case text = "Ключи / конфиг"
        var id: String { rawValue }
    }

    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .link
    @State private var url = ""
    @State private var text = ""
    @State private var name = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Picker("Тип", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(text: mode == .link ? "Ссылка на подписку" : "Ключи или конфигурация")
                        Group {
                            if mode == .link {
                                TextField("https://…", text: $url, axis: .vertical)
                                    .keyboardType(.URL)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .lineLimit(1 ... 4)
                            } else {
                                TextEditor(text: $text)
                                    .font(.system(.footnote, design: .monospaced))
                                    .frame(minHeight: 140)
                                    .scrollContentBackground(.hidden)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))

                        Button {
                            paste()
                        } label: {
                            Label("Вставить из буфера", systemImage: "doc.on.clipboard")
                        }
                        .buttonStyle(SoftButtonStyle())
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        SectionTitle(text: "Название (необязательно)")
                        TextField("Например, Домашний VPN", text: $name)
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.card))
                    }

                    Button {
                        Task { await submit() }
                    } label: {
                        if working {
                            ProgressView().tint(.white)
                        } else {
                            Text("Добавить")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(working || (mode == .link ? url.isEmpty : text.isEmpty))
                    .opacity((mode == .link ? url.isEmpty : text.isEmpty) ? 0.5 : 1)
                }
                .padding(Theme.pagePadding)
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Новая подписка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
    }

    private func paste() {
        guard let value = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            state.show("Буфер обмена пуст")
            return
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://"), !value.contains("\n") {
            mode = .link
            url = value
        } else {
            mode = .text
            text = value
        }
    }

    private func submit() async {
        working = true
        defer { working = false }
        let ok: Bool
        if mode == .link {
            ok = await state.addSubscription(url: url, name: name)
        } else {
            ok = state.addLocal(text: text, name: name)
        }
        if ok { dismiss() }
    }
}
