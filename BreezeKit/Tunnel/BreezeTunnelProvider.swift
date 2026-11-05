import Foundation
import Libbox
import NetworkExtension

public struct TunnelRuntimeOptions: Codable {
    public var excludeAPNs: Bool = true
    public var systemProxyEnabled: Bool = false

    public init(excludeAPNs: Bool = true, systemProxyEnabled: Bool = false) {
        self.excludeAPNs = excludeAPNs
        self.systemProxyEnabled = systemProxyEnabled
    }
}

/// Keys and message format shared by the app and the extension.
public enum TunnelProtocol {
    public static let configKey = "config"
    public static let runtimeKey = "runtime"

    public struct Message: Codable {
        public var command: String
        public var config: String?
        public var runtime: TunnelRuntimeOptions?

        public init(command: String, config: String? = nil, runtime: TunnelRuntimeOptions? = nil) {
            self.command = command
            self.config = config
            self.runtime = runtime
        }
    }

    public struct Reply: Codable {
        public var ok: Bool
        public var error: String?
    }
}

/// The extension persists the last config so that on-demand / system restarts work
/// without the app being involved.
enum TunnelStore {
    static var configURL: URL { BreezePaths.base.appendingPathComponent("tunnel-config.json") }
    static var runtimeURL: URL { BreezePaths.base.appendingPathComponent("tunnel-runtime.json") }
    static var groupURL: URL { BreezePaths.base.appendingPathComponent("tunnel-group.txt") }

    static func save(group: String) {
        try? group.data(using: .utf8)?.write(to: groupURL, options: .atomic)
    }

    static func loadGroup() -> String? {
        guard let data = try? Data(contentsOf: groupURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(config: String) {
        try? config.data(using: .utf8)?.write(to: configURL, options: .atomic)
    }

    static func loadConfig() -> String? {
        guard let data = try? Data(contentsOf: configURL) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func save(runtime: TunnelRuntimeOptions) {
        if let data = try? JSONEncoder().encode(runtime) {
            try? data.write(to: runtimeURL, options: .atomic)
        }
    }

    static func loadRuntime() -> TunnelRuntimeOptions {
        guard let data = try? Data(contentsOf: runtimeURL),
              let value = try? JSONDecoder().decode(TunnelRuntimeOptions.self, from: data)
        else {
            return TunnelRuntimeOptions()
        }
        return value
    }
}

open class BreezeTunnelProvider: NEPacketTunnelProvider {
    private var commandServer: LibboxCommandServer?
    private var boxService: LibboxBoxService?
    private var platformInterface: ExtensionPlatformInterface?
    public private(set) var runtimeOptions = TunnelRuntimeOptions()
    private var diag = DiagnosticLog(directory: nil)
    private var sharedDirectory: URL?

    override open func startTunnel(options: [String: NSObject]?) async throws {
        if let group = options?[SharedGroup.optionKey] as? String, !group.isEmpty {
            BreezePaths.prepare()
            TunnelStore.save(group: group)
        }
        sharedDirectory = SharedGroup.container(TunnelStore.loadGroup())
        diag = DiagnosticLog(directory: sharedDirectory)
        diag.reset()
        diag.write("startTunnel: options=\(options?.keys.sorted().joined(separator: ",") ?? "nil") shared=\(sharedDirectory?.path ?? "none")")
        do {
            try await startTunnel0(options)
            diag.write("startTunnel: ok")
        } catch {
            diag.write("startTunnel: FAILED \(error.localizedDescription)")
            throw error
        }
    }

    private func startTunnel0(_ options: [String: NSObject]?) async throws {
        if let error = LibboxBootstrap.setup() {
            throw BreezeError("Не удалось запустить ядро: \(error.localizedDescription)").nsError
        }
        diag.write("libbox setup ok, core \(LibboxBootstrap.coreVersion), base=\(BreezePaths.base.path)")

        if let config = options?[TunnelProtocol.configKey] as? String, !config.isEmpty {
            TunnelStore.save(config: config)
        }
        if let runtimeJSON = options?[TunnelProtocol.runtimeKey] as? String,
           let data = runtimeJSON.data(using: .utf8),
           let runtime = try? JSONDecoder().decode(TunnelRuntimeOptions.self, from: data)
        {
            TunnelStore.save(runtime: runtime)
        }
        runtimeOptions = TunnelStore.loadRuntime()

        guard let config = TunnelStore.loadConfig() else {
            throw BreezeError("Нет конфигурации. Откройте Breeze и подключитесь из приложения.").nsError
        }
        diag.write("config loaded: \(config.count) bytes")

        var error: NSError?
        let stderrDir = sharedDirectory ?? BreezePaths.temp
        LibboxRedirectStderr(stderrDir.appendingPathComponent(DiagnosticLog.stderrName).path, &error)
        if let error {
            diag.write("redirect stderr: \(error.localizedDescription)")
        }
        LibboxSetMemoryLimit(true)

        if platformInterface == nil {
            platformInterface = ExtensionPlatformInterface(self)
        }
        let server = LibboxNewCommandServer(platformInterface, 500)
        guard let server else {
            throw BreezeError("Не удалось создать командный сервер").nsError
        }
        do {
            try server.start()
        } catch {
            throw BreezeError("Командный сервер: \(error.localizedDescription)").nsError
        }
        commandServer = server
        diag.write("command server started")
        writeMessage("(breeze) tunnel starting")

        try startService(withLogFile(config))
    }

    /// Mirrors sing-box logs into the shared container so the app can show them after a failure.
    private func withLogFile(_ config: String) -> String {
        guard let sharedDirectory,
              let data = config.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return config }
        let logURL = sharedDirectory.appendingPathComponent(DiagnosticLog.boxLogName)
        try? Data().write(to: logURL)
        var log = root["log"] as? [String: Any] ?? [:]
        log["output"] = logURL.path
        root["log"] = log
        guard let patched = try? JSONSerialization.data(withJSONObject: root),
              let string = String(data: patched, encoding: .utf8)
        else { return config }
        return string
    }

    private func startService(_ config: String) throws {
        diag.write("creating service")
        var error: NSError?
        let service = LibboxNewService(config, platformInterface, &error)
        if let error {
            writeMessage("(breeze) create service: \(error.localizedDescription)")
            throw BreezeError("Ошибка конфигурации: \(error.localizedDescription)").nsError
        }
        guard let service else {
            throw BreezeError("Ядро не создало сервис").nsError
        }
        do {
            try service.start()
        } catch {
            writeMessage("(breeze) start service: \(error.localizedDescription)")
            throw BreezeError("Не удалось запустить: \(error.localizedDescription)").nsError
        }
        commandServer?.setService(service)
        boxService = service
        diag.write("service started")
    }

    func writeMessage(_ message: String) {
        commandServer?.writeMessage(message)
    }

    private func stopService() {
        if let service = boxService {
            do {
                try service.close()
            } catch {
                writeMessage("(breeze) stop service: \(error.localizedDescription)")
            }
            boxService = nil
            commandServer?.setService(nil)
        }
        platformInterface?.reset()
    }

    func reloadService() async {
        writeMessage("(breeze) reloading service")
        reasserting = true
        defer {
            reasserting = false
        }
        stopService()
        commandServer?.resetLog()
        guard let config = TunnelStore.loadConfig() else {
            cancelTunnelWithError(BreezeError("Нет конфигурации").nsError)
            return
        }
        do {
            try startService(withLogFile(config))
        } catch {
            diag.write("reload FAILED \(error.localizedDescription)")
            cancelTunnelWithError(error)
        }
    }

    func postServiceClose() {
        boxService = nil
    }

    override open func stopTunnel(with reason: NEProviderStopReason) async {
        writeMessage("(breeze) stopping, reason: \(reason.rawValue)")
        diag.write("stopTunnel: reason \(reason.rawValue)")
        stopService()
        if let server = commandServer {
            try? await Task.sleep(nanoseconds: 100 * NSEC_PER_MSEC)
            try? server.close()
            commandServer = nil
        }
    }

    override open func handleAppMessage(_ messageData: Data) async -> Data? {
        guard let message = try? JSONDecoder().decode(TunnelProtocol.Message.self, from: messageData) else {
            return reply(ok: false, error: "bad message")
        }
        switch message.command {
        case "reload":
            if let config = message.config, !config.isEmpty {
                TunnelStore.save(config: config)
            }
            if let runtime = message.runtime {
                TunnelStore.save(runtime: runtime)
                runtimeOptions = runtime
            }
            await reloadService()
            return reply(ok: boxService != nil, error: boxService == nil ? "reload failed" : nil)
        case "ping":
            return reply(ok: boxService != nil, error: nil)
        default:
            return reply(ok: false, error: "unknown command")
        }
    }

    private func reply(ok: Bool, error: String?) -> Data? {
        try? JSONEncoder().encode(TunnelProtocol.Reply(ok: ok, error: error))
    }

    override open func sleep() async {
        boxService?.pause()
    }

    override open func wake() {
        boxService?.wake()
    }
}
