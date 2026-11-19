import BreezeKit
import Combine
import Foundation
import Network
import NetworkExtension
import SwiftUI

private struct PersistedState: Codable {
    var subscriptions: [ProxySubscription] = []
    var activeSubscriptionID: UUID?
    var selectedServer: String?
    var settings = AppSettings()
    /// Network on which a server was picked by hand while automation is on.
    var manualPick: NetworkKind?
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var subscriptions: [ProxySubscription] = [] { didSet { save() } }
    @Published var activeSubscriptionID: UUID? { didSet { save() } }
    @Published var selectedServer: String? { didSet { save() } }
    @Published var settings = AppSettings() {
        didSet {
            guard settings != oldValue else { return }
            save()
            if settings.connectOnDemand != oldValue.connectOnDemand {
                let enabled = settings.connectOnDemand
                Task { await tunnel.setAlwaysOn(enabled) }
            }
            if settings.liveActivity != oldValue.liveActivity {
                publishIntegrations()
            }
            if settings.needsReload(comparedTo: oldValue) {
                scheduleReload()
            }
        }
    }

    @Published var pingResults: [String: Int] = [:]
    /// Servers whose probe is in flight (spinner instead of a number).
    @Published var pingPending: Set<String> = []
    @Published var testingLatency = false
    @Published private(set) var network: NetworkKind?
    /// Set when a server is picked by hand while automation is on; valid until the network changes.
    @Published private(set) var manualPick: NetworkKind? { didSet { save() } }
    @Published var updatingIDs: Set<UUID> = []
    @Published var toast: String?

    let tunnel = TunnelManager.shared
    let sharedGroup = SharedGroup.discover()
    let statusClient = CommandClient(.status)
    let groupClient = CommandClient(.groups)

    private var cancellables = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    private var desiredConfigTask: Task<Void, Never>?
    private var needsSelectionSync = false
    private var loading = true
    private let pathMonitor = NWPathMonitor()

    /// Loopback Clash API of the tunnel core (next to the command port) for single-server probes.
    var controller: ConfigBuilder.Controller {
        let key = "clashSecret"
        let secret = UserDefaults.standard.string(forKey: key) ?? {
            let value = UUID().uuidString
            UserDefaults.standard.set(value, forKey: key)
            return value
        }()
        return ConfigBuilder.Controller(port: Int(LibboxBootstrap.commandPort) + 1, secret: secret)
    }

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
            manualPick = state.manualPick
        }
        network = NetworkKind(path: pathMonitor.currentPath)
        loading = false
        writeDesiredConfig()
        pathMonitor.pathUpdateHandler = { path in
            let kind = NetworkKind(path: path)
            Task { @MainActor in AppState.shared.networkChanged(kind) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "breeze.app.path"))

        tunnel.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        tunnel.$status
            .removeDuplicates()
            .sink { [weak self] status in self?.tunnelStatusChanged(status) }
            .store(in: &cancellables)
        groupClient.$groups
            .sink { [weak self] groups in self?.syncSelection(groups) }
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
            settings: settings,
            manualPick: manualPick
        )
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.stateURL, options: .atomic)
        }
        scheduleDesiredConfig()
    }

    private func scheduleDesiredConfig() {
        desiredConfigTask?.cancel()
        desiredConfigTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300 * NSEC_PER_MSEC)
            guard !Task.isCancelled else { return }
            self?.writeDesiredConfig()
        }
    }

    /// Starts from Control Center, widgets and On Demand pass no config: the extension reads this copy.
    private func writeDesiredConfig() {
        guard !servers.isEmpty else { return }
        SharedGroup.writeDesiredConfig(buildConfig(), group: sharedGroup)
    }

    // MARK: - Derived

    var activeSubscription: ProxySubscription? {
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

    /// Automation groups present in the config: Wi‑Fi / cellular -> member servers.
    var automationGroups: [ConfigBuilder.AutomationGroup] {
        ConfigBuilder.automationGroups(servers: servers, settings: settings)
    }

    /// Automation tag for the current network, unless a server was picked by hand on it.
    private var automationSelection: String? {
        guard let network, manualPick != network else { return nil }
        let tag = ConfigBuilder.automationTag(for: network)
        return automationGroups.contains { $0.tag == tag } ? tag : nil
    }

    /// What the config's selector starts with.
    var desiredSelection: String? {
        automationSelection ?? selectedServer
    }

    /// Tag currently selected in the selector (live from the core when connected).
    var currentSelection: String {
        if tunnel.isConnected, let group = proxyGroup, !group.selected.isEmpty {
            return group.selected
        }
        if let automationSelection {
            return automationSelection
        }
        if let selectedServer, selectedServer == ConfigBuilder.autoTag || servers.contains(where: { $0.name == selectedServer }) {
            return selectedServer
        }
        return servers.count > 1 ? ConfigBuilder.autoTag : (servers.first?.name ?? "")
    }

    /// Real server behind the selection (resolves "auto" and the automation groups).
    var effectiveServer: ServerNode? {
        server(behind: currentSelection)
    }

    func server(behind tag: String) -> ServerNode? {
        var tag = tag
        for _ in 0 ..< 3 {
            if let node = servers.first(where: { $0.name == tag }) { return node }
            if let group = groupClient.groups.first(where: { $0.tag == tag }), !group.selected.isEmpty {
                tag = group.selected
                continue
            }
            // offline: a one-server rule is known, a group is decided by the core
            if let members = automationGroups.first(where: { $0.tag == tag })?.members {
                if members.count == 1 { tag = members[0]; continue }
                let measured = members.compactMap { name in pingResults[name].flatMap { $0 > 0 ? (name, $0) : nil } }
                if let best = measured.min(by: { $0.1 < $1.1 }) { tag = best.0; continue }
            }
            return nil
        }
        return nil
    }

    /// Human title of a selector item.
    func title(for tag: String) -> String {
        if tag == ConfigBuilder.autoTag { return "Самый быстрый" }
        if let kind = ConfigBuilder.networkKind(ofTag: tag) { return "Автоматизация · \(kind.title)" }
        return servers.first { $0.name == tag }?.cleanName ?? tag
    }

    func latency(for tag: String) -> Int? {
        if tunnel.isConnected {
            if let value = pingResults[tag] { return value }
            // only results measured by the running core; offline results would be misleading
            for group in [proxyGroup, autoGroup].compactMap({ $0 }) {
                if let item = group.items.first(where: { $0.tag == tag }), item.urlTestDelay != 0 {
                    return Int(item.urlTestDelay)
                }
            }
            return nil
        }
        return pingResults[tag]
    }

    // MARK: - Tunnel

    private func networkChanged(_ kind: NetworkKind?) {
        guard kind != network else { return }
        EventLog.shared.add("network: \(kind?.rawValue ?? "none")")
        network = kind
        // a hand-picked server only holds on the network it was picked on
        if let manualPick, manualPick != kind { self.manualPick = nil }
        // the tunnel switches by itself; the app only refreshes what the next start uses
        scheduleDesiredConfig()
        if settings.automation.enabled { publishIntegrations() }
    }

    private func tunnelStatusChanged(_ status: NEVPNStatus) {
        if status == .connected {
            pingResults = [:]
            needsSelectionSync = true
            statusClient.connect()
            groupClient.connect()
        } else if status == .disconnected || status == .invalid {
            statusClient.disconnect()
            groupClient.disconnect()
            AppStateLogClient.shared.disconnect()
        }
        publishIntegrations()
    }

    /// First selector state after connecting: if the core runs another server than the one
    /// picked in the app (tunnel started with an older config), switch it to the picked one.
    private func syncSelection(_ groups: [OutboundGroupInfo]) {
        guard needsSelectionSync, tunnel.isConnected,
              let group = groups.first(where: { $0.tag == ConfigBuilder.selectorTag })
        else { return }
        needsSelectionSync = false
        // the tunnel applies the automation itself on start
        if settings.automation.enabled, ConfigBuilder.networkKind(ofTag: group.selected) != nil { return }
        guard let wanted = desiredSelection, wanted != group.selected,
              wanted == ConfigBuilder.autoTag || servers.contains(where: { $0.name == wanted })
              || automationGroups.contains(where: { $0.tag == wanted })
        else { return }
        EventLog.shared.add("selector runs \(group.selected), app picked \(wanted): syncing")
        if group.items.contains(where: { $0.tag == wanted }) {
            try? TunnelCommands.selectOutbound(group: ConfigBuilder.selectorTag, outbound: wanted)
        } else {
            scheduleReload()
        }
    }

    /// Feeds widgets, the Control Center toggle and the Live Activity.
    func publishIntegrations() {
        let selection = currentSelection
        let node = effectiveServer ?? servers.first { $0.name == selection }
        let serverName = node?.cleanName ?? title(for: selection)
        WidgetStore.save(WidgetSnapshot(
            serverName: serverName,
            flag: node?.flag,
            mode: settings.routingMode.title,
            subscription: activeSubscription?.name,
            updatedAt: .now
        ))
        WidgetStore.reloadAll()
        LiveActivityController.update(
            connected: tunnel.isConnected,
            enabled: settings.liveActivity,
            server: serverName,
            flag: node?.flag,
            mode: settings.routingMode.title,
            since: tunnel.connectedDate
        )
    }

    func buildConfig() -> String {
        ConfigBuilder.build(servers: servers, selected: desiredSelection, settings: settings, controller: controller)
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
        EventLog.shared.add("connect: \(servers.count) servers, selected \(currentSelection)")
        if let error = TunnelCommands.checkConfig(config) {
            EventLog.shared.add("config check FAILED: \(error)")
            tunnel.lastError = "Ошибка конфигурации: \(error)"
            return
        }
        EventLog.shared.add("config check ok")
        await tunnel.start(config: config, runtime: runtime, group: sharedGroup, onDemand: settings.connectOnDemand)
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
            await tunnel.start(config: config, runtime: runtime, group: sharedGroup, onDemand: settings.connectOnDemand)
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
        if settings.automation.enabled {
            // picking the current network's own rule hands control back to the automation
            let followsAutomation = network.map { ConfigBuilder.automationTag(for: $0) == tag } ?? false
            manualPick = followsAutomation ? nil : network
        }
        if ConfigBuilder.networkKind(ofTag: tag) == nil {
            selectedServer = tag
        } else {
            save()
        }
        if tunnel.isConnected {
            let selectorHasTag = proxyGroup?.items.contains { $0.tag == tag } ?? false
            if !selectorHasTag {
                // e.g. "auto" is only in the config while it is selected: rebuild
                scheduleReload()
                publishIntegrations()
                return
            }
            do {
                try TunnelCommands.selectOutbound(group: ConfigBuilder.selectorTag, outbound: tag)
            } catch {
                show("Не удалось переключить: \(error.localizedDescription)")
            }
        }
        publishIntegrations()
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
        publishIntegrations()
    }

    // MARK: - Latency

    func testLatency() async {
        guard !testingLatency, !servers.isEmpty else { return }
        testingLatency = true
        let targets = servers
        pingResults = [:]
        pingPending = Set(targets.map(\.name))
        defer {
            testingLatency = false
            pingPending = []
        }
        if tunnel.isConnected {
            let measured = await measureThroughCore(targets)
            if !measured {
                // tunnel started with a config without the controller: the core tests the whole selector
                await Task.detached { try? TunnelCommands.urlTest(group: ConfigBuilder.selectorTag) }.value
                try? await Task.sleep(nanoseconds: 1500 * NSEC_PER_MSEC)
            }
            return
        }
        await measureOffline(targets)
    }

    /// Probes one server (swipe on a row).
    func ping(_ tag: String) async {
        guard let node = servers.first(where: { $0.name == tag }), !pingPending.contains(tag) else { return }
        pingPending.insert(tag)
        pingResults[tag] = nil
        defer { pingPending.remove(tag) }
        if tunnel.isConnected {
            let measured = await measureThroughCore([node])
            if !measured {
                show("Переподключите VPN, чтобы проверять отдельные серверы")
            }
            return
        }
        await measureOffline([node])
    }

    private func record(_ tag: String, _ value: Int) {
        pingResults[tag] = value
        pingPending.remove(tag)
    }

    /// Through the running core's Clash API, so the numbers match what the tunnel sees.
    /// The tunnel lives in a tight memory budget, hence the lower cap.
    private func measureThroughCore(_ nodes: [ServerNode]) async -> Bool {
        let controller = self.controller
        let api = ClashDelay(port: controller.port, secret: controller.secret, concurrency: 16, timeoutMs: settings.pingTimeout)
        defer { api.invalidate() }
        guard await api.reachable() else { return false }
        let url = settings.urlTestURL
        await Concurrent.forEach(nodes.map(\.name), limit: min(settings.pingConcurrency, 16)) { name in
            await api.delay(name: name, url: url) ?? -1
        } onResult: { name, value in
            record(name, value)
        }
        return true
    }

    private func measureOffline(_ nodes: [ServerNode]) async {
        switch settings.pingMethod {
        case .url:
            do {
                try await ProxyLatencyTester.test(
                    servers: nodes,
                    url: settings.urlTestURL,
                    timeoutMs: settings.pingTimeout,
                    concurrency: settings.pingConcurrency
                ) { tag, value in
                    await AppState.shared.record(tag, value)
                }
            } catch {
                show("Тест задержки: \(error.localizedDescription)")
            }
        case .tcp:
            let timeout = TimeInterval(settings.pingTimeout) / 1000
            let endpoints = nodes.map { TCPPing.Endpoint(tag: $0.name, host: $0.host, port: $0.port) }
            await Concurrent.forEach(endpoints, limit: settings.pingConcurrency) { endpoint in
                await TCPPing.measure(host: endpoint.host, port: endpoint.port, timeout: timeout)
            } onResult: { endpoint, value in
                record(endpoint.tag, value)
            }
        }
    }

    /// Sorts servers by the last measured latency (failures last).
    func sortedByLatency(_ nodes: [ServerNode]) -> [ServerNode] {
        nodes.sorted { a, b in
            let la = latency(for: a.name).flatMap { $0 > 0 ? $0 : nil } ?? Int.max
            let lb = latency(for: b.name).flatMap { $0 > 0 ? $0 : nil } ?? Int.max
            return la < lb
        }
    }

    // MARK: - Subscriptions

    @discardableResult
    func addSubscription(url: String, name: String?) async -> Bool {
        do {
            let fetched = try await SubscriptionFetcher.fetch(url: url, userAgent: settings.subscriptionUserAgent)
            let host = URL(string: url)?.host ?? "Подписка"
            var subscription = ProxySubscription(
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
        let subscription = ProxySubscription(
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

    private func apply(_ fetched: FetchedSubscription, to subscription: inout ProxySubscription) {
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
            if !silent {
                show("Обновлено: \(fetched.servers.count) серверов")
                // background refreshes apply on the next connect instead of dropping the tunnel
                if id == activeSubscription?.id { scheduleReload() }
            }
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
        pingResults = [:]
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
        // breeze://connect | disconnect | toggle — handy for Shortcuts automations
        if url.scheme?.lowercased() == "breeze" {
            switch url.host?.lowercased() {
            case "connect", "on":
                if !tunnel.isConnected { await connect() }
                return
            case "disconnect", "off":
                await tunnel.stop()
                return
            case "toggle":
                await toggle()
                return
            default:
                break
            }
        }
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
    struct Endpoint: Sendable {
        var tag: String
        var host: String
        var port: Int
    }

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
