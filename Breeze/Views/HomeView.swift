import BreezeKit
import NetworkExtension
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var state: AppState
    @Binding var tab: AppTab
    @State private var showServers = false
    @State private var showLogs = false

    private var status: NEVPNStatus { state.tunnel.status }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.sectionSpacing) {
                    header
                    PowerSection()
                    if let error = state.tunnel.lastError {
                        ErrorBanner(text: error) {
                            withAnimation(.snappy) { state.tunnel.lastError = nil }
                        }
                    }
                    if state.servers.isEmpty {
                        EmptyServersCard { tab = .subscriptions }
                    } else {
                        ServerCard { showServers = true }
                        ModeSelector()
                    }
                    if state.tunnel.isConnected {
                        StatsGrid(status: state.statusClient.status)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if let subscription = state.activeSubscription, let traffic = subscription.traffic {
                        TrafficCard(subscription: subscription, traffic: traffic)
                    }
                }
                .padding(.horizontal, Theme.pagePadding)
                .padding(.top, 8)
                .padding(.bottom, 40)
                .animation(.snappy, value: state.tunnel.isConnected)
            }
            .background(PageBackground())
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showServers) {
                ServersView(asSheet: true)
                    .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showLogs) {
                NavigationStack { LogsView() }
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Breeze")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.label)
                Text(state.activeSubscription?.name ?? "Без подписки")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                showLogs = true
            } label: {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.card))
                    .shadow(color: Theme.accent.opacity(0.08), radius: 10, y: 4)
            }
            .accessibilityLabel("Журнал")
        }
        .padding(.top, 8)
    }
}

// MARK: - Power

private struct PowerSection: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        let status = state.tunnel.status
        VStack(spacing: 22) {
            PowerButton(status: status) {
                Task { await state.toggle() }
            }
            .disabled(state.tunnel.isBusy || status == .disconnecting)

            VStack(spacing: 6) {
                Text(title(status))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.label)
                    .contentTransition(.opacity)
                if status == .connected, let since = state.tunnel.connectedDate {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.duration(context.date.timeIntervalSince(since)))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                } else {
                    Text(subtitle(status))
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            .animation(.snappy, value: status)
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func title(_ status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "Защищено"
        case .connecting: return "Подключение…"
        case .disconnecting: return "Отключение…"
        case .reasserting: return "Переподключение…"
        default: return "Не подключено"
        }
    }

    private func subtitle(_ status: NEVPNStatus) -> String {
        switch status {
        case .connecting, .reasserting: return "Устанавливаем соединение"
        case .disconnecting: return "Закрываем туннель"
        default: return "Нажмите, чтобы подключиться"
        }
    }
}

struct PowerButton: View {
    let status: NEVPNStatus
    let action: () -> Void
    @State private var spin = false
    @State private var pulse = false
    @Environment(\.colorScheme) private var colorScheme

    private var connected: Bool { status == .connected }
    private var working: Bool { status == .connecting || status == .disconnecting || status == .reasserting }

    var body: some View {
        Button(action: action) {
            ZStack {
                // soft halo
                Circle()
                    .fill(Theme.accent.opacity(connected ? 0.16 : 0.07))
                    .frame(width: 236, height: 236)
                    .scaleEffect(connected && pulse ? 1.06 : 1)
                Circle()
                    .fill(Theme.accent.opacity(connected ? 0.12 : 0.05))
                    .frame(width: 204, height: 204)

                Circle()
                    .fill(connected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.card))
                    .frame(width: 168, height: 168)
                    .shadow(
                        color: connected ? Theme.accent.opacity(0.45) : Color(red: 0.14, green: 0.42, blue: 0.84).opacity(colorScheme == .dark ? 0 : 0.14),
                        radius: connected ? 28 : 22, y: connected ? 14 : 10
                    )

                if working {
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: 184, height: 184)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .onAppear {
                            spin = false
                            withAnimation(.linear(duration: 1).repeatForever(autoreverses: false)) { spin = true }
                        }
                }

                Image(systemName: "power")
                    .font(.system(size: 54, weight: .semibold))
                    .foregroundStyle(connected ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.accent))
            }
            .frame(width: 240, height: 240)
            .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: connected)
        .animation(.spring(response: 0.45, dampingFraction: 0.8), value: connected)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel(connected ? "Отключить VPN" : "Подключить VPN")
    }
}

// MARK: - Server card

private struct ServerCard: View {
    @EnvironmentObject private var state: AppState
    let action: () -> Void

    var body: some View {
        let selection = state.currentSelection
        let isAuto = selection == ConfigBuilder.autoTag
        let node = isAuto ? state.effectiveServer : state.servers.first(where: { $0.name == selection })
        Button(action: action) {
            HStack(spacing: 14) {
                if isAuto, node == nil {
                    IconTile(systemName: "bolt.fill", size: 44)
                } else {
                    FlagBadge(flag: node?.flag, size: 44)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(isAuto ? "Самый быстрый" : (node?.cleanName ?? selection))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(subtitle(isAuto: isAuto, node: node))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let node {
                    LatencyBadge(latency: state.latency(for: node.name))
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.secondaryLabel.opacity(0.6))
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    private func subtitle(isAuto: Bool, node: ServerNode?) -> String {
        if isAuto {
            if let node { return "Авто · \(node.cleanName)" }
            return "Автовыбор по задержке · \(state.servers.count) серверов"
        }
        guard let node else { return "Сервер" }
        return [node.displayType, node.transportLabel].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct EmptyServersCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            IconTile(systemName: "plus", size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Добавьте подписку")
                    .font(.headline)
                    .foregroundStyle(Theme.label)
                Text("Вставьте ссылку от вашего провайдера или конфигурацию с серверами.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryLabel)
            }
            Button("Добавить", action: action)
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
        }
        .card(padding: 22)
    }
}

// MARK: - Mode

private struct ModeSelector: View {
    @EnvironmentObject private var state: AppState
    @Namespace private var namespace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Режим")
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 6) {
                    ForEach(RoutingMode.allCases) { mode in
                        let selected = state.settings.routingMode == mode
                        Button {
                            withAnimation(.snappy) { state.setMode(mode) }
                        } label: {
                            Text(mode.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selected ? .white : Theme.accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background {
                                    if selected {
                                        Capsule()
                                            .fill(Theme.accentGradient)
                                            .matchedGeometryEffect(id: "mode", in: namespace)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(5)
                .background(Capsule().fill(Theme.tint))

                Text(state.settings.routingMode.subtitle)
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding(.horizontal, 6)
                    .contentTransition(.opacity)
            }
            .card(padding: 14)
        }
        .sensoryFeedback(.selection, trigger: state.settings.routingMode)
    }
}

// MARK: - Stats

private struct StatsGrid: View {
    let status: TunnelStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Трафик")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                StatTile(icon: "arrow.down", title: "Загрузка", value: Format.speed(status.downlink), detail: Format.bytes(status.downlinkTotal))
                StatTile(icon: "arrow.up", title: "Отдача", value: Format.speed(status.uplink), detail: Format.bytes(status.uplinkTotal))
                StatTile(icon: "point.3.connected.trianglepath.dotted", title: "Соединения", value: "\(status.connectionsOut)", detail: "активных")
                StatTile(icon: "memorychip", title: "Память", value: Format.bytes(status.memory), detail: "туннель")
            }
        }
    }
}

private struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.tint))
                Text(title)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.secondaryLabel)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .contentTransition(.numericText())
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .card(padding: 16, radius: 22)
    }
}

// MARK: - ProxySubscription traffic

struct TrafficCard: View {
    let subscription: ProxySubscription
    let traffic: SubscriptionTraffic

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: "Подписка")
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(subscription.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Spacer()
                    if let expire = traffic.expire {
                        Text("до \(Format.date(expire))")
                            .font(.footnote)
                            .foregroundStyle(expire < .now ? Theme.bad : Theme.secondaryLabel)
                    }
                }
                if traffic.total > 0 {
                    UsageBar(fraction: traffic.fraction)
                    HStack {
                        Text("\(Format.bytes(traffic.used)) из \(Format.bytes(traffic.total))")
                        Spacer()
                        Text("осталось \(Format.bytes(max(0, traffic.total - traffic.used)))")
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryLabel)
                } else {
                    Text("Использовано \(Format.bytes(traffic.used)) · безлимит")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryLabel)
                }
            }
            .card()
        }
    }
}

struct UsageBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.tint)
                Capsule()
                    .fill(fraction > 0.9 ? AnyShapeStyle(Theme.bad) : AnyShapeStyle(Theme.accentGradient))
                    .frame(width: max(8, proxy.size.width * fraction))
            }
        }
        .frame(height: 8)
    }
}

private struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.bad)
                .font(.body)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.secondaryLabel)
                    .padding(6)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.bad.opacity(0.1)))
    }
}
