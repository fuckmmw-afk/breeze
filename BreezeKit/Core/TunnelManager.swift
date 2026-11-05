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

    public func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            let identifier = Self.tunnelBundleIdentifier
            EventLog.shared.add("load: \(managers.count) VPN profiles, tunnel id \(identifier)")
            let match = managers.first {
                ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == identifier
            }
            // drop stale profiles left from an older bundle id
            for stale in managers where stale !== match {
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
        if newStatus == .disconnected, previous == .connecting || previous == .connected || previous == .reasserting {
            Task { await fetchDisconnectError(previous: previous) }
        }
    }

    private func fetchDisconnectError(previous: NEVPNStatus) async {
        guard let connection = manager?.connection else { return }
        do {
            try await connection.fetchLastDisconnectError()
            EventLog.shared.add("last disconnect error: none")
            if previous == .connecting {
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
