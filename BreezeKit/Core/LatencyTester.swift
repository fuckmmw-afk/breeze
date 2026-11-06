import Foundation
import Libbox
import Network

/// Real "GET through the proxy" latency test while the VPN is off: spins up a
/// throwaway sing-box instance inside the app (no TUN, only outbounds and the
/// Clash API on localhost) and asks it for /proxies/{name}/delay.
public enum ProxyLatencyTester {
    public static func test(
        servers: [ServerNode],
        url: String,
        timeoutMs: Int,
        concurrency: Int = 12,
        onResult: @escaping @Sendable (String, Int) async -> Void
    ) async throws {
        guard !servers.isEmpty else { return }
        if let error = LibboxBootstrap.setup() {
            throw error
        }
        let port = Int.random(in: 41000 ... 48999)
        let config = testerConfig(servers: servers, port: port)
        var error: NSError?
        let platform = AppPlatformInterface()
        guard let service = LibboxNewService(config, platform, &error) else {
            throw BreezeError("Не удалось запустить тест: \(error?.localizedDescription ?? "?")")
        }
        try service.start()
        defer {
            try? service.close()
            platform.close()
        }
        // let the controller start listening
        try? await Task.sleep(nanoseconds: 150 * NSEC_PER_MSEC)

        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = Double(timeoutMs) / 1000 + 3
            configuration.httpMaximumConnectionsPerHost = concurrency
            return configuration
        }())
        defer { session.invalidateAndCancel() }

        let names = servers.map(\.name)
        for start in stride(from: 0, to: names.count, by: concurrency) {
            try Task.checkCancellation()
            let slice = Array(names[start ..< min(start + concurrency, names.count)])
            await withTaskGroup(of: (String, Int).self) { group in
                for name in slice {
                    group.addTask {
                        (name, await delay(session: session, port: port, name: name, url: url, timeoutMs: timeoutMs))
                    }
                }
                for await (name, value) in group {
                    await onResult(name, value)
                }
            }
        }
    }

    private static func delay(session: URLSession, port: Int, name: String, url: String, timeoutMs: Int) async -> Int {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let escapedName = name.addingPercentEncoding(withAllowedCharacters: allowed),
              let escapedURL = url.addingPercentEncoding(withAllowedCharacters: allowed),
              let requestURL = URL(string: "http://127.0.0.1:\(port)/proxies/\(escapedName)/delay?timeout=\(min(timeoutMs, 30000))&url=\(escapedURL)")
        else { return -1 }
        do {
            let (data, response) = try await session.data(from: requestURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let delay = (json["delay"] as? NSNumber)?.intValue
            else { return -1 }
            return delay
        } catch {
            return -1
        }
    }

    static func testerConfig(servers: [ServerNode], port: Int) -> String {
        var outbounds: [JSONValue] = servers.map { server in
            var outbound = server.outbound
            outbound["tag"] = .string(server.name)
            return .object(outbound)
        }
        outbounds.append(["type": "direct", "tag": "direct"])
        let config: JSONValue = [
            "log": ["level": "error"],
            "dns": [
                "servers": [["type": "local", "tag": "local"]],
            ],
            "outbounds": .array(outbounds),
            "route": [
                "final": "direct",
                "default_domain_resolver": ["server": "local"],
            ],
            "experimental": [
                "clash_api": ["external_controller": .string("127.0.0.1:\(port)")],
            ],
        ]
        return JSONOutput.string(config)
    }
}

/// Minimal platform bridge for running sing-box inside the app process (no TUN).
final class AppPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol {
    private var monitor: NWPathMonitor?

    func close() {
        monitor?.cancel()
        monitor = nil
    }

    func openTun(_: LibboxTunOptionsProtocol?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "tun is not available in the app", code: 0)
    }

    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    func autoDetectControl(_: Int32) throws {}

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32, ret0_ _: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "not implemented", code: 0)
    }

    func packageName(byUid _: Int32, error _: NSErrorPointer) -> String {
        ""
    }

    func uid(byPackageName _: String?, ret0_ _: UnsafeMutablePointer<Int32>?) throws {
        throw NSError(domain: "not implemented", code: 0)
    }

    func useProcFS() -> Bool {
        false
    }

    func writeLog(_: String?) {}

    func startDefaultInterfaceMonitor(_ listener: LibboxInterfaceUpdateListenerProtocol?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { path in
            Self.update(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { path in
                Self.update(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue.global())
        _ = semaphore.wait(timeout: .now() + 2)
    }

    private static func update(_ listener: LibboxInterfaceUpdateListenerProtocol, _ path: NWPath) {
        if path.status == .unsatisfied || path.availableInterfaces.isEmpty {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
        } else {
            let interface = path.availableInterfaces[0]
            listener.updateDefaultInterface(interface.name, interfaceIndex: Int32(interface.index), isExpensive: path.isExpensive, isConstrained: path.isConstrained)
        }
    }

    func closeDefaultInterfaceMonitor(_: LibboxInterfaceUpdateListenerProtocol?) throws {
        close()
    }

    func getInterfaces() throws -> LibboxNetworkInterfaceIteratorProtocol {
        var interfaces: [LibboxNetworkInterface] = []
        if let path = monitor?.currentPath, path.status != .unsatisfied {
            for item in path.availableInterfaces {
                let interface = LibboxNetworkInterface()
                interface.name = item.name
                interface.index = Int32(item.index)
                switch item.type {
                case .wifi: interface.type = LibboxInterfaceTypeWIFI
                case .cellular: interface.type = LibboxInterfaceTypeCellular
                case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
                default: interface.type = LibboxInterfaceTypeOther
                }
                interfaces.append(interface)
            }
        }
        return InterfaceArray(interfaces)
    }

    private final class InterfaceArray: NSObject, LibboxNetworkInterfaceIteratorProtocol {
        private var iterator: IndexingIterator<[LibboxNetworkInterface]>
        private var nextValue: LibboxNetworkInterface?

        init(_ array: [LibboxNetworkInterface]) {
            iterator = array.makeIterator()
        }

        func hasNext() -> Bool {
            nextValue = iterator.next()
            return nextValue != nil
        }

        func next() -> LibboxNetworkInterface? {
            nextValue
        }
    }

    func underNetworkExtension() -> Bool {
        false
    }

    func includeAllNetworks() -> Bool {
        false
    }

    func clearDNSCache() {}

    func readWIFIState() -> LibboxWIFIState? {
        nil
    }

    func send(_: LibboxNotification?) throws {}

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    func systemCertificates() -> (any LibboxStringIteratorProtocol)? {
        nil
    }
}
