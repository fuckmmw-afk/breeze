import Foundation
import NetworkExtension

/// App-side controller of the packet tunnel (NETunnelProviderManager).
@MainActor
public final class TunnelManager: ObservableObject {
    public static let shared = TunnelManager()

    @Published public private(set) var status: NEVPNStatus = .invalid
    @Published public private(set) var connectedDate: Date?
    @Published public var lastError: String?
    @Published public private(set) var isBusy = false

    private var manager: NETunnelProviderManager?
    private var currentGroup: String?
    private var reachedConnected = false
    private var observer: NSObjectProtocol?

    public var isConnected: Bool { status == .connected }
    public var isTransitioning: Bool {
        status == .connecting || status == .disconnecting || status == .reasserting
    }

    private init() {}

    /// Bundle id of the embedded packet-tunnel extension, read at runtime so that
    /// re-signing tools that rewrite bundle ids keep working.
    public static var tunnelBundleIdentifier: String {
        if let plugins = Bundle.main.builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        {
            for url in items where url.pathExtension == "appex" {
                guard let bundle = Bundle(url: url),
                      let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                      let point = ext["NSExtensionPointIdentifier"] as? String,
                      point == "com.apple.networkextension.packet-tunnel",
                      let identifier = bundle.bundleIdentifier
                else {
                    continue
                }
                return identifier
            }
        }
        return (Bundle.main.bundleIdentifier ?? "com.fuckmmw.breeze") + ".tunnel"
    }

    private var loadTask: Task<Void, Never>?

    /// Loads the VPN profile. Concurrent calls share one load, so a tap on "connect"
    /// during launch can't create a duplicate profile.
    public func load() async {
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { await load0() }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private static func isActive(_ status: NEVPNStatus) -> Bool {
        status == .connected || status == .connecting || status == .reasserting || status == .disconnecting
    }

    private func load0() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let identifier = Self.tunnelBundleIdentifier
            EventLog.shared.add("load: \(managers.count) VPN profiles, tunnel id \(identifier)")
            let ours = managers.filter {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
            }
            // prefer the running profile, never pick one at random
            let match = ours.first { Self.isActive($0.connection.status) } ?? ours.first
            // remove duplicates and leftovers from older bundle ids, but never a running one
            for stale in managers where stale !== match && !Self.isActive(stale.connection.status) {
                EventLog.shared.add("removing stale VPN profile \((stale.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier ?? "?")")
                try? await stale.removeFromPreferences()
            }
            if let match {
                attach(match)
            }
        } catch {
            EventLog.shared.add("load FAILED: \(Self.describe(error))")
            lastError = error.localizedDescription
        }
    }

    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var text = "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " ← \(underlying.localizedDescription) [\(underlying.domain) \(underlying.code)]"
        }
        return text
    }

    private func attach(_ manager: NETunnelProviderManager) {
        self.manager = manager
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStatus()
            }
        }
        refreshStatus()
    }

    private func refreshStatus() {
        guard let manager else {
            status = .invalid
            connectedDate = nil
            return
        }
        let newStatus = manager.connection.status
        let previous = status
        if newStatus != previous {
            EventLog.shared.add("status: \(Self.name(previous)) → \(Self.name(newStatus))")
        }
        status = newStatus
        connectedDate = newStatus == .connected ? manager.connection.connectedDate : nil
        if newStatus == .connected {
            reachedConnected = true
        }
        if newStatus == .disconnected, previous != .disconnected, previous != .invalid {
            let failedStart = !reachedConnected
            reachedConnected = false
            Task { await fetchDisconnectError(failedStart: failedStart) }
        }
    }

    /// Last "FAILED" line the extension left in the shared diagnostics log.
    private func extensionFailure() -> String? {
        guard let text = DiagnosticLog.read(DiagnosticLog.fileName, group: currentGroup ?? SharedGroup.discover()) else { return nil }
        guard let line = text.split(separator: "\n").last(where: { $0.contains("FAILED") }),
              let range = line.range(of: "FAILED ")
        else { return nil }
        var message = String(line[range.upperBound...])
        if message.count > 500 { message = String(message.prefix(500)) + "…" }
        if message.contains("i/o timeout") || message.contains("timed out") {
            return "Сервер не отвечает. Выберите другой сервер.\n\n" + message
        }
        return message
    }

    private func fetchDisconnectError(failedStart: Bool) async {
        if failedStart, let failure = extensionFailure() {
            EventLog.shared.add("extension failure: \(failure)")
            lastError = failure
            return
        }
        guard let connection = manager?.connection else { return }
        do {
            try await connection.fetchLastDisconnectError()
            EventLog.shared.add("last disconnect error: none")
            if failedStart {
                lastError = "Туннель не запустился. Подробности: Настройки → Журнал."
            }
        } catch {
            let nsError = error as NSError
            EventLog.shared.add("last disconnect error: \(Self.describe(error))")
            if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                lastError = "\(nsError.localizedDescription) (\(underlying.localizedDescription))"
            } else if nsError.domain == NEVPNConnectionErrorDomain,
                      nsError.code == NEVPNConnectionError.noNetworkAvailable.rawValue
            {
                lastError = "Нет сети"
            } else {
                lastError = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
            }
        }
    }

    private func ensureManager() async throws -> NETunnelProviderManager {
        if manager == nil {
            await load()
        }
        if let manager {
            return manager
        }
        let manager = NETunnelProviderManager()
        manager.localizedDescription = "Breeze"
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = Self.tunnelBundleIdentifier
        proto.serverAddress = "Breeze"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.isEnabled = true
        EventLog.shared.add("installing VPN profile for \(proto.providerBundleIdentifier ?? "?")")
        try await manager.saveToPreferences()
        EventLog.shared.add("VPN profile saved")
        try await manager.loadFromPreferences()
        attach(manager)
        return manager
    }

    public func start(config: String, runtime: TunnelRuntimeOptions, group: String? = nil) async {
        lastError = nil
        currentGroup = group
        reachedConnected = false
        isBusy = true
        defer { isBusy = false }
        do {
            let manager = try await ensureManager()
            if !manager.isEnabled {
                manager.isEnabled = true
                try await manager.saveToPreferences()
                try await manager.loadFromPreferences()
            }
            let runtimeJSON = String(data: try JSONEncoder().encode(runtime), encoding: .utf8) ?? "{}"
            var options: [String: NSObject] = [
                TunnelProtocol.configKey: config as NSString,
                TunnelProtocol.runtimeKey: runtimeJSON as NSString,
            ]
            if let group {
                options[SharedGroup.optionKey] = group as NSString
            }
            options[TunnelProtocol.portKey] = NSNumber(value: LibboxBootstrap.commandPort)
            EventLog.shared.add("startVPNTunnel: config \(config.count) bytes, group \(group ?? "none")")
            try manager.connection.startVPNTunnel(options: options)
        } catch {
            EventLog.shared.add("start FAILED: \(Self.describe(error))")
            lastError = error.localizedDescription
        }
    }

    static func name(_ status: NEVPNStatus) -> String {
        switch status {
        case .invalid: return "invalid"
        case .disconnected: return "disconnected"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .reasserting: return "reasserting"
        case .disconnecting: return "disconnecting"
        @unknown default: return "unknown"
        }
    }

    public func stop() async {
        EventLog.shared.add("stop requested")
        guard let manager else { return }
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try? await manager.saveToPreferences()
        }
        manager.connection.stopVPNTunnel()
    }

    /// Pushes a fresh config into the running tunnel without dropping the VPN.
    public func reload(config: String, runtime: TunnelRuntimeOptions) async -> Bool {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else {
            return false
        }
        let message = TunnelProtocol.Message(command: "reload", config: config, runtime: runtime)
        guard let data = try? JSONEncoder().encode(message) else { return false }
        return await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    var ok = false
                    if let response, let reply = try? JSONDecoder().decode(TunnelProtocol.Reply.self, from: response) {
                        ok = reply.ok
                    }
                    continuation.resume(returning: ok)
                }
            } catch {
                continuation.resume(returning: false)
            }
        }
    }

    public func setAlwaysOn(_ enabled: Bool) async {
        guard let manager = try? await ensureManager() else { return }
        manager.isOnDemandEnabled = enabled
        if enabled {
            let rule = NEOnDemandRuleConnect()
            rule.interfaceTypeMatch = .any
            manager.onDemandRules = [rule]
        } else {
            manager.onDemandRules = []
        }
        try? await manager.saveToPreferences()
    }
}
