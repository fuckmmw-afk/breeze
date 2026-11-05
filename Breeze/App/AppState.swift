import BreezeKit
import Combine
import Foundation
import Network
import NetworkExtension
import SwiftUI

private struct PersistedState: Codable {
    var subscriptions: [Subscription] = []
    var activeSubscriptionID: UUID?
    var selectedServer: String?
    var settings = AppSettings()
}

@MainActor
final class AppState: ObservableObject {
    @Published var subscriptions: [Subscription] = [] { didSet { save() } }
    @Published var activeSubscriptionID: UUID? { didSet { save() } }
    @Published var selectedServer: String? { didSet { save() } }
    @Published var settings = AppSettings() { didSet { if settings != oldValue { save(); scheduleReload() } } }

    @Published var tcpLatency: [String: Int] = [:]
    @Published var testingLatency = false
    @Published var updatingIDs: Set<UUID> = []
    @Published var toast: String?

    let tunnel = TunnelManager.shared
    let statusClient = CommandClient(.status)
    let groupClient = CommandClient(.groups)

    private var cancellables = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    private var loading = true

    private static var stateURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("breeze-state.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.stateURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data)
        {
            subscriptions = state.subscriptions
            activeSubscriptionID = state.activeSubscriptionID
            selectedServer = state.selectedServer
            settings = state.settings
        }
        loading = false

        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        tunnel.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.tunnelStatusChanged(status) }
            .store(in: &cancellables)
        for client in [statusClient, groupClient] {
            client.objectWillChange
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }
    }

    private func save() {
        guard !loading else { return }
        let state = PersistedState(
            subscriptions: subscriptions,
            activeSubscriptionID: activeSubscriptionID,
            selectedServer: selectedServer,
            settings: settings
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
    }

    // MARK: - Derived

    var activeSubscription: Subscription? {
        subscriptions.first { $0.id == activeSubscriptionID } ?? subscriptions.first
    }

    var servers: [ServerNode] {
        activeSubscription?.servers ?? []
    }

    var proxyGroup: OutboundGroupInfo? {
        groupClient.groups.first { $0.tag == ConfigBuilder.selectorTag }
    }

    var autoGroup: OutboundGroupInfo? {
        groupClient.groups.first { $0.tag == ConfigBuilder.autoTag }
    }

    /// Tag currently selected in the selector (live from the core when connected).
    var currentSelection: String {
        if tunnel.isConnected, let group = proxyGroup, !group.selected.isEmpty {
            return group.selected
        }
        if let selectedServer, selectedServer == ConfigBuilder.autoTag || servers.contains(where: { $0.name == selectedServer }) {
            return selectedServer
        }
        return servers.count > 1 ? ConfigBuilder.autoTag : (servers.first?.name ?? "")
    }

    /// Real server behind the selection (resolves "auto").
    var effectiveServer: ServerNode? {
        var tag = currentSelection
        if tag == ConfigBuilder.autoTag {
            guard let picked = autoGroup?.selected, !picked.isEmpty else { return nil }
            tag = picked
        }
        return servers.first { $0.name == tag }
    }

    func latency(for tag: String) -> Int? {
        if tunnel.isConnected {
            for group in [proxyGroup, autoGroup].compactMap({ $0 }) {
                if let item = group.items.first(where: { $0.tag == tag }), item.urlTestDelay != 0 {
                    return Int(item.urlTestDelay)
                }
            }
        }
        return tcpLatency[tag]
    }

    // MARK: - Tunnel

    private func tunnelStatusChanged(_ status: NEVPNStatus) {
        if status == .connected {
            statusClient.connect()
            groupClient.connect()
        } else if status == .disconnected || status == .invalid {
            statusClient.disconnect()
            groupClient.disconnect()
            AppStateLogClient.shared.disconnect()
        }
    }

    func buildConfig() -> String {
        ConfigBuilder.build(servers: servers, selected: selectedServer, settings: settings)
    }

    var runtime: TunnelRuntimeOptions {
        TunnelRuntimeOptions(excludeAPNs: settings.excludeAPNs, systemProxyEnabled: false)
    }

    func toggle() async {
        if tunnel.isConnected || tunnel.status == .connecting || tunnel.status == .reasserting {
            await tunnel.stop()
            return
        }
        await connect()
    }

    func connect() async {
        guard !servers.isEmpty else {
            tunnel.lastError = "Сначала добавьте подписку с серверами"
            return
        }
        let config = buildConfig()
        if let error = TunnelCommands.checkConfig(config) {
            tunnel.lastError = "Ошибка конфигурации: \(error)"
            return
        }
        await tunnel.start(config: config, runtime: runtime)
    }

    /// Re-applies the config to a running tunnel (debounced).
    func scheduleReload() {
        guard !loading, tunnel.isConnected else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600 * NSEC_PER_MSEC)
            guard !Task.isCancelled, let self else { return }
            await self.reloadNow()
        }
    }

    func reloadNow() async {
        guard tunnel.isConnected else { return }
        let config = buildConfig()
        if let error = TunnelCommands.checkConfig(config) {
            tunnel.lastError = "Ошибка конфигурации: \(error)"
            return
        }
        let ok = await tunnel.reload(config: config, runtime: runtime)
        if !ok {
            // fallback: full restart
            await tunnel.stop()
            try? await Task.sleep(nanoseconds: 800 * NSEC_PER_MSEC)
            await tunnel.start(config: config, runtime: runtime)
        } else {
            statusClient.disconnect()
            groupClient.disconnect()
            try? await Task.sleep(nanoseconds: 300 * NSEC_PER_MSEC)
            statusClient.connect()
            groupClient.connect()
        }
    }

    // MARK: - Selection & mode

    func select(_ tag: String) {
        selectedServer = tag
        if tunnel.isConnected {
            do {
                try TunnelCommands.selectOutbound(group: ConfigBuilder.selectorTag, outbound: tag)
            } catch {
                show("Не удалось переключить: \(error.localizedDescription)")
            }
        }
    }

    func setMode(_ mode: RoutingMode) {
        guard settings.routingMode != mode else { return }
        // mode switches are live through the clash API, no reload needed
        loading = true
        settings.routingMode = mode
        loading = false
        save()
        if tunnel.isConnected {
            try? TunnelCommands.setClashMode(mode.rawValue)
        }
    }

    // MARK: - Latency

    func testLatency() async {
        guard !testingLatency else { return }
        testingLatency = true
        defer { testingLatency = false }
        if tunnel.isConnected {
            try? TunnelCommands.urlTest(group: ConfigBuilder.selectorTag)
            try? await Task.sleep(nanoseconds: 1500 * NSEC_PER_MSEC)
            return
        }
        let targets = servers
        for start in stride(from: 0, to: targets.count, by: 12) {
            let slice = Array(targets[start ..< min(start + 12, targets.count)])
            await withTaskGroup(of: (String, Int).self) { group in
                for node in slice {
                    let host = node.host
                    let port = node.port
                    let tag = node.name
                    group.addTask { (tag, await TCPPing.measure(host: host, port: port)) }
                }
                for await (tag, value) in group {
                    tcpLatency[tag] = value
                }
            }
        }
    }

    // MARK: - Subscriptions

    @discardableResult
    func addSubscription(url: String, name: String?) async -> Bool {
        do {
            let fetched = try await SubscriptionFetcher.fetch(url: url, userAgent: settings.subscriptionUserAgent)
            let host = URL(string: url)?.host ?? "Подписка"
            var subscription = Subscription(
                name: (name?.isEmpty == false ? name! : nil) ?? fetched.title ?? host,
                kind: .remote,
                url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                servers: fetched.servers
            )
            apply(fetched, to: &subscription)
            subscriptions.append(subscription)
            if subscriptions.count == 1 || activeSubscriptionID == nil {
                activeSubscriptionID = subscription.id
            }
            show("Добавлено серверов: \(fetched.servers.count)")
            return true
        } catch {
            show(error.localizedDescription)
            return false
        }
    }

    @discardableResult
    func addLocal(text: String, name: String?) -> Bool {
        let servers = SubscriptionParser.parse(text)
        guard !servers.isEmpty else {
            show("Не нашёл поддерживаемых ссылок или конфигурации")
            return false
        }
        let subscription = Subscription(
            name: (name?.isEmpty == false ? name! : nil) ?? (servers.count == 1 ? servers[0].cleanName : "Мои серверы"),
            kind: .local,
            content: text,
            servers: servers
        )
        subscriptions.append(subscription)
        if subscriptions.count == 1 || activeSubscriptionID == nil {
            activeSubscriptionID = subscription.id
        }
        show("Добавлено серверов: \(servers.count)")
        return true
    }

    private func apply(_ fetched: FetchedSubscription, to subscription: inout Subscription) {
        subscription.servers = fetched.servers
        subscription.traffic = fetched.traffic
        subscription.updatedAt = .now
        subscription.updateInterval = fetched.updateInterval
        subscription.supportURL = fetched.supportURL
    }

    func update(_ id: UUID, silent: Bool = false) async {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }),
              subscriptions[index].kind == .remote, let url = subscriptions[index].url
        else { return }
        updatingIDs.insert(id)
        defer { updatingIDs.remove(id) }
        do {
            let fetched = try await SubscriptionFetcher.fetch(url: url, userAgent: settings.subscriptionUserAgent)
            guard let index = subscriptions.firstIndex(where: { $0.id == id }) else { return }
            var subscription = subscriptions[index]
            apply(fetched, to: &subscription)
            subscriptions[index] = subscription
            if !silent { show("Обновлено: \(fetched.servers.count) серверов") }
            if id == activeSubscription?.id { scheduleReload() }
        } catch {
            if !silent { show(error.localizedDescription) }
        }
    }

    func updateAll(silent: Bool = false) async {
        for subscription in subscriptions where subscription.kind == .remote {
            await update(subscription.id, silent: silent)
        }
    }

    func autoUpdateIfNeeded() async {
        guard settings.autoUpdateSubscriptions else { return }
        for subscription in subscriptions where subscription.kind == .remote {
            let interval = subscription.updateInterval ?? 12 * 3600
            if let updatedAt = subscription.updatedAt, Date.now.timeIntervalSince(updatedAt) < interval {
                continue
            }
            await update(subscription.id, silent: true)
        }
    }

    func activate(_ id: UUID) {
        guard activeSubscriptionID != id else { return }
        activeSubscriptionID = id
        selectedServer = nil
        tcpLatency = [:]
        scheduleReload()
    }

    func delete(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        if activeSubscriptionID == id {
            activeSubscriptionID = subscriptions.first?.id
            selectedServer = nil
            scheduleReload()
        }
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = subscriptions.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        subscriptions[index].name = name
    }

    func handle(url: URL) async {
        // breeze://import?url=<encoded>&name=<name>, sing-box://import-remote-profile?url=...
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        if let link = items.first(where: { $0.name == "url" })?.value {
            await addSubscription(url: link, name: items.first(where: { $0.name == "name" })?.value)
        } else if LinkParser.supportedSchemes.contains(url.scheme?.lowercased() ?? "") {
            addLocal(text: url.absoluteString, name: nil)
        }
    }

    func show(_ message: String) {
        withAnimation(.snappy) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2800 * NSEC_PER_MSEC)
            if toast == message {
                withAnimation(.snappy) { toast = nil }
            }
        }
    }
}

/// TCP handshake time to a server, used when the tunnel is down.
enum TCPPing {
    static func measure(host: String, port: Int, timeout: TimeInterval = 3) async -> Int {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return -1 }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = Date()
        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedFlag()
            func finish(_ value: Int) {
                guard finished.set() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(Int(Date().timeIntervalSince(start) * 1000))
                case .failed, .cancelled:
                    finish(-1)
                case .waiting:
                    finish(-1)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(-1)
            }
        }
    }
}

/// Thread-safe "only once" flag.
final class OSAllocatedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Returns true the first time only.
    func set() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
