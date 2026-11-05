import Foundation
import Yams

public enum SubscriptionParser {
    static let proxyTypes: Set<String> = [
        "vless", "vmess", "trojan", "shadowsocks", "hysteria2", "hysteria", "tuic", "anytls",
        "socks", "http", "shadowtls", "ssh", "naive",
    ]

    /// Accepts base64 lists, plain link lists, Clash YAML and sing-box JSON.
    public static func parse(_ text: String) -> [ServerNode] {
        uniquify(parse0(text, depth: 0))
    }

    private static func parse0(_ text: String, depth: Int) -> [ServerNode] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            let nodes = parseSingBox(trimmed)
            if !nodes.isEmpty { return nodes }
        }
        if trimmed.contains("proxies:") {
            let nodes = parseClash(trimmed)
            if !nodes.isEmpty { return nodes }
        }
        if !trimmed.contains("://"), depth < 2, let decoded = Base64.decodeString(trimmed) {
            return parse0(decoded, depth: depth + 1)
        }
        var nodes: [ServerNode] = []
        for line in trimmed.components(separatedBy: .newlines) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let node = LinkParser.parse(line) {
                nodes.append(node)
            } else if !line.contains("://"), depth < 2, let decoded = Base64.decodeString(line), decoded.contains("://") {
                nodes.append(contentsOf: parse0(decoded, depth: depth + 1))
            }
        }
        return nodes
    }

    private static func uniquify(_ nodes: [ServerNode]) -> [ServerNode] {
        var used = Set<String>(["proxy", "auto", "direct", "block", "dns-out"])
        return nodes.map { node in
            var node = node
            var base = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if base.isEmpty { base = "\(node.displayType) \(node.host)" }
            var name = base
            var counter = 1
            while used.contains(name.lowercased()) {
                counter += 1
                name = "\(base) \(counter)"
            }
            used.insert(name.lowercased())
            node.name = name
            node.id = "\(node.type)|\(node.host)|\(node.port)|\(name)"
            return node
        }
    }

    // MARK: - sing-box JSON

    static func parseSingBox(_ text: String) -> [ServerNode] {
        guard let data = text.data(using: .utf8), let root = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return []
        }
        let outbounds: [JSONValue]
        if let array = root.arrayValue {
            outbounds = array
        } else if let array = root["outbounds"]?.arrayValue {
            outbounds = array
        } else {
            return []
        }
        var nodes: [ServerNode] = []
        for item in outbounds {
            guard var object = item.objectValue,
                  let type = object["type"]?.stringValue, proxyTypes.contains(type),
                  let server = object["server"]?.stringValue
            else { continue }
            let tag = object["tag"]?.stringValue ?? "\(type) \(server)"
            object.removeValue(forKey: "tag")
            // detours to other outbounds are not carried over
            object.removeValue(forKey: "detour")
            let port = object["server_port"]?.intValue ?? 443
            nodes.append(ServerNode(name: tag, type: type, host: server, port: port, outbound: object))
        }
        return nodes
    }

    // MARK: - Clash

    static func parseClash(_ text: String) -> [ServerNode] {
        guard let root = (try? Yams.load(yaml: text)) as? [String: Any],
              let proxies = root["proxies"] as? [Any]
        else { return [] }
        return proxies.compactMap { item in
            guard let dict = item as? [String: Any] else { return nil }
            return ClashProxy(dict).node()
        }
    }
}

/// Converts one Clash/Mihomo proxy entry into a sing-box outbound.
struct ClashProxy {
    let values: [String: Any]

    init(_ values: [String: Any]) {
        self.values = values
    }

    func string(_ key: String) -> String? {
        guard let value = values[key] else { return nil }
        let string = "\(value)"
        return string.isEmpty ? nil : string
    }

    func bool(_ key: String) -> Bool {
        if let value = values[key] as? Bool { return value }
        return OutboundBuilder.flag(string(key))
    }

    func dict(_ key: String) -> [String: Any]? {
        values[key] as? [String: Any]
    }

    func node() -> ServerNode? {
        guard let type = string("type")?.lowercased(), let server = string("server") else { return nil }
        let portSpec = string("port") ?? string("ports") ?? ""
        guard let port = Int(portSpec) ?? OutboundBuilder.firstPort(portSpec) else { return nil }
        let name = string("name") ?? "\(type) \(server)"
        var outbound: [String: JSONValue] = [
            "server": .string(server),
            "server_port": .int(port),
        ]
        let singType: String
        switch type {
        case "ss":
            singType = "shadowsocks"
            guard let cipher = string("cipher"), let password = string("password") else { return nil }
            outbound["method"] = .string(cipher)
            outbound["password"] = .string(password)
            if let plugin = string("plugin") {
                let opts = dict("plugin-opts") ?? [:]
                switch plugin {
                case "obfs", "simple-obfs":
                    outbound["plugin"] = .string("obfs-local")
                    var parts = ["obfs=\(opts["mode"] ?? "http")"]
                    if let host = opts["host"] { parts.append("obfs-host=\(host)") }
                    outbound["plugin_opts"] = .string(parts.joined(separator: ";"))
                case "v2ray-plugin":
                    outbound["plugin"] = .string("v2ray-plugin")
                    var parts: [String] = []
                    if let mode = opts["mode"] { parts.append("mode=\(mode)") }
                    if (opts["tls"] as? Bool) == true { parts.append("tls") }
                    if let host = opts["host"] { parts.append("host=\(host)") }
                    if let path = opts["path"] { parts.append("path=\(path)") }
                    outbound["plugin_opts"] = .string(parts.joined(separator: ";"))
                default:
                    return nil
                }
            }
        case "vmess":
            singType = "vmess"
            guard let uuid = string("uuid") else { return nil }
            outbound["uuid"] = .string(uuid)
            outbound["alter_id"] = .int(Int(string("alterId") ?? "0") ?? 0)
            outbound["security"] = .string(string("cipher") ?? "auto")
            outbound["packet_encoding"] = .string("xudp")
        case "vless":
            singType = "vless"
            guard let uuid = string("uuid") else { return nil }
            outbound["uuid"] = .string(uuid)
            outbound["packet_encoding"] = .string("xudp")
            let network = string("network") ?? "tcp"
            if let flow = string("flow"), network == "tcp" {
                outbound["flow"] = .string(flow)
            }
        case "trojan":
            singType = "trojan"
            guard let password = string("password") else { return nil }
            outbound["password"] = .string(password)
        case "hysteria2", "hy2":
            singType = "hysteria2"
            outbound["password"] = .string(string("password") ?? string("auth") ?? "")
            if let ports = string("ports"), let ranges = OutboundBuilder.portRanges(ports), !ranges.isEmpty {
                outbound["server_ports"] = .array(ranges.map { .string($0) })
            }
            if let obfs = string("obfs") {
                outbound["obfs"] = .object(["type": .string(obfs), "password": .string(string("obfs-password") ?? "")])
            }
        case "tuic":
            singType = "tuic"
            guard let uuid = string("uuid") else { return nil }
            outbound["uuid"] = .string(uuid)
            outbound["password"] = .string(string("password") ?? "")
            outbound.put("congestion_control", string("congestion-controller"))
            outbound.put("udp_relay_mode", string("udp-relay-mode"))
        case "anytls":
            singType = "anytls"
            outbound["password"] = .string(string("password") ?? "")
        case "socks5":
            singType = "socks"
            outbound["version"] = .string("5")
            outbound.put("username", string("username"))
            outbound.put("password", string("password"))
        case "http":
            singType = "http"
            outbound.put("username", string("username"))
            outbound.put("password", string("password"))
        default:
            return nil
        }
        outbound["type"] = .string(singType)

        // TLS
        let alwaysTLS = ["hysteria2", "tuic", "anytls"].contains(singType)
        let reality = dict("reality-opts")
        if alwaysTLS || singType == "trojan" || bool("tls") || reality != nil {
            var alpn: String?
            if let list = values["alpn"] as? [Any] {
                alpn = list.map { "\($0)" }.joined(separator: ",")
            } else {
                alpn = string("alpn")
            }
            if alwaysTLS, singType != "anytls", alpn == nil {
                alpn = "h3"
            }
            let params = TLSParams(
                security: reality != nil ? "reality" : "tls",
                sni: string("sni") ?? string("servername"),
                fingerprint: string("client-fingerprint"),
                alpn: alpn,
                insecure: bool("skip-cert-verify"),
                publicKey: reality.flatMap { $0["public-key"].map { "\($0)" } },
                shortID: reality.flatMap { $0["short-id"].map { "\($0)" } }
            )
            if let tls = OutboundBuilder.tls(params, host: server, transportHost: nil) {
                outbound["tls"] = .object(tls)
            }
        }

        // transport
        if let network = string("network"), ["vmess", "vless", "trojan"].contains(singType) {
            var params = TransportParams(network: network)
            switch network {
            case "ws":
                let opts = dict("ws-opts") ?? [:]
                params.path = opts["path"].map { "\($0)" }
                if let headers = opts["headers"] as? [String: Any], let host = headers["Host"] ?? headers["host"] {
                    params.host = "\(host)"
                }
                params.maxEarlyData = (opts["max-early-data"] as? Int)
                params.earlyDataHeader = opts["early-data-header-name"].map { "\($0)" }
            case "grpc":
                let opts = dict("grpc-opts") ?? [:]
                params.serviceName = opts["grpc-service-name"].map { "\($0)" }
            case "h2":
                let opts = dict("h2-opts") ?? [:]
                if let hosts = opts["host"] as? [Any] {
                    params.host = hosts.map { "\($0)" }.joined(separator: ",")
                }
                params.path = opts["path"].map { "\($0)" }
            case "http":
                let opts = dict("http-opts") ?? [:]
                params.headerType = "http"
                params.network = "tcp"
                if let paths = opts["path"] as? [Any], let first = paths.first {
                    params.path = "\(first)"
                }
                if let headers = opts["headers"] as? [String: Any], let hosts = headers["Host"] as? [Any] {
                    params.host = hosts.map { "\($0)" }.joined(separator: ",")
                }
            default:
                break
            }
            guard let transport = OutboundBuilder.transport(params) else { return nil }
            if !transport.isEmpty {
                outbound["transport"] = .object(transport)
            }
        }
        return ServerNode(name: name, type: singType, host: server, port: port, outbound: outbound)
    }
}
