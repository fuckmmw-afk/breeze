import Foundation

/// Parses share links (vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, anytls://, socks://)
/// into sing-box outbound objects.
public enum LinkParser {
    public static let supportedSchemes = ["vless", "vmess", "trojan", "ss", "hysteria2", "hy2", "tuic", "anytls", "socks", "socks5"]

    public static func parse(_ raw: String) -> ServerNode? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = line.range(of: "://") else { return nil }
        let scheme = line[..<schemeEnd.lowerBound].lowercased()
        switch scheme {
        case "vmess":
            return parseVMess(line)
        case "ss":
            return parseShadowsocks(line)
        default:
            guard let uri = URIParts(line) else { return nil }
            switch scheme {
            case "vless": return parseVLESS(uri)
            case "trojan": return parseTrojan(uri)
            case "hysteria2", "hy2": return parseHysteria2(uri)
            case "tuic": return parseTUIC(uri)
            case "anytls": return parseAnyTLS(uri)
            case "socks", "socks5": return parseSocks(uri)
            default: return nil
            }
        }
    }

    // MARK: - VLESS

    static func parseVLESS(_ uri: URIParts) -> ServerNode? {
        guard let uuid = uri.user, !uuid.isEmpty, let port = uri.port else { return nil }
        let q = uri.query
        let params = TransportParams(
            network: q["type"] ?? "tcp",
            path: q["path"],
            host: q["host"],
            serviceName: q["serviceName"] ?? q["servicename"],
            headerType: q["headerType"]
        )
        guard let transport = OutboundBuilder.transport(params) else { return nil }
        var outbound: [String: JSONValue] = [
            "type": .string("vless"),
            "server": .string(uri.host),
            "server_port": .int(port),
            "uuid": .string(uuid),
        ]
        if let flow = q["flow"], !flow.isEmpty, transport.isEmpty {
            outbound["flow"] = .string(flow.replacingOccurrences(of: "-udp443", with: ""))
        }
        outbound["packet_encoding"] = .string(q["packetEncoding"] ?? "xudp")
        let tlsParams = TLSParams(
            security: q["security"] ?? "none",
            sni: q["sni"] ?? q["peer"],
            fingerprint: q["fp"],
            alpn: q["alpn"],
            insecure: OutboundBuilder.flag(q["allowInsecure"] ?? q["insecure"] ?? q["allow_insecure"]),
            publicKey: q["pbk"],
            shortID: q["sid"]
        )
        if let tls = OutboundBuilder.tls(tlsParams, host: uri.host, transportHost: q["host"]) {
            outbound["tls"] = .object(tls)
        }
        if !transport.isEmpty {
            outbound["transport"] = .object(transport)
        }
        return ServerNode(name: uri.name(default: "VLESS \(uri.host)"), type: "vless", host: uri.host, port: port, outbound: outbound)
    }

    // MARK: - VMess

    static func parseVMess(_ line: String) -> ServerNode? {
        let body = String(line.dropFirst("vmess://".count))
        let payload = body.split(separator: "#", maxSplits: 1).first.map(String.init) ?? body
        if let decoded = Base64.decodeString(payload),
           let data = decoded.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            return parseVMessJSON(json)
        }
        // xray-style vmess://uuid@host:port?...
        guard let uri = URIParts(line), let uuid = uri.user, let port = uri.port else { return nil }
        let q = uri.query
        let transport = OutboundBuilder.transport(TransportParams(
            network: q["type"] ?? "tcp", path: q["path"], host: q["host"],
            serviceName: q["serviceName"], headerType: q["headerType"]
        ))
        guard let transport else { return nil }
        var outbound: [String: JSONValue] = [
            "type": .string("vmess"),
            "server": .string(uri.host),
            "server_port": .int(port),
            "uuid": .string(uuid),
            "security": .string(q["encryption"] ?? "auto"),
            "alter_id": .int(0),
        ]
        if let tls = OutboundBuilder.tls(TLSParams(
            security: q["security"] ?? "none", sni: q["sni"], fingerprint: q["fp"], alpn: q["alpn"],
            insecure: OutboundBuilder.flag(q["allowInsecure"]), publicKey: nil, shortID: nil
        ), host: uri.host, transportHost: q["host"]) {
            outbound["tls"] = .object(tls)
        }
        if !transport.isEmpty {
            outbound["transport"] = .object(transport)
        }
        return ServerNode(name: uri.name(default: "VMess \(uri.host)"), type: "vmess", host: uri.host, port: port, outbound: outbound)
    }

    static func parseVMessJSON(_ json: [String: Any]) -> ServerNode? {
        func value(_ key: String) -> String? {
            guard let raw = json[key] else { return nil }
            let string = "\(raw)".trimmingCharacters(in: .whitespaces)
            return string.isEmpty ? nil : string
        }
        guard let host = value("add"), let portString = value("port"), let port = Int(portString), let uuid = value("id") else {
            return nil
        }
        let network = value("net") ?? "tcp"
        let transport = OutboundBuilder.transport(TransportParams(
            network: network,
            path: value("path"),
            host: value("host"),
            serviceName: network == "grpc" ? value("path") : nil,
            headerType: value("type")
        ))
        guard let transport else { return nil }
        var security = value("scy") ?? "auto"
        if security.isEmpty { security = "auto" }
        var outbound: [String: JSONValue] = [
            "type": .string("vmess"),
            "server": .string(host),
            "server_port": .int(port),
            "uuid": .string(uuid),
            "security": .string(security),
            "alter_id": .int(Int(value("aid") ?? "0") ?? 0),
            "packet_encoding": .string("xudp"),
        ]
        let tlsMode = value("tls") ?? ""
        if tlsMode == "tls" || tlsMode == "reality" {
            if let tls = OutboundBuilder.tls(TLSParams(
                security: tlsMode, sni: value("sni"), fingerprint: value("fp"), alpn: value("alpn"),
                insecure: OutboundBuilder.flag(value("allowInsecure") ?? value("skip-cert-verify")),
                publicKey: value("pbk"), shortID: value("sid")
            ), host: host, transportHost: value("host")) {
                outbound["tls"] = .object(tls)
            }
        }
        if !transport.isEmpty {
            outbound["transport"] = .object(transport)
        }
        let name = value("ps") ?? "VMess \(host)"
        return ServerNode(name: name, type: "vmess", host: host, port: port, outbound: outbound)
    }

    // MARK: - Trojan

    static func parseTrojan(_ uri: URIParts) -> ServerNode? {
        guard let password = uri.userInfo, let port = uri.port else { return nil }
        let q = uri.query
        let transport = OutboundBuilder.transport(TransportParams(
            network: q["type"] ?? "tcp", path: q["path"], host: q["host"],
            serviceName: q["serviceName"], headerType: q["headerType"]
        ))
        guard let transport else { return nil }
        var outbound: [String: JSONValue] = [
            "type": .string("trojan"),
            "server": .string(uri.host),
            "server_port": .int(port),
            "password": .string(password),
        ]
        let security = q["security"] ?? "tls"
        if let tls = OutboundBuilder.tls(TLSParams(
            security: security.isEmpty ? "tls" : security, sni: q["sni"] ?? q["peer"], fingerprint: q["fp"], alpn: q["alpn"],
            insecure: OutboundBuilder.flag(q["allowInsecure"] ?? q["insecure"]),
            publicKey: q["pbk"], shortID: q["sid"]
        ), host: uri.host, transportHost: q["host"]) {
            outbound["tls"] = .object(tls)
        }
        if !transport.isEmpty {
            outbound["transport"] = .object(transport)
        }
        return ServerNode(name: uri.name(default: "Trojan \(uri.host)"), type: "trojan", host: uri.host, port: port, outbound: outbound)
    }

    // MARK: - Shadowsocks

    static func parseShadowsocks(_ line: String) -> ServerNode? {
        var body = String(line.dropFirst("ss://".count))
        var name: String?
        if let hash = body.firstIndex(of: "#") {
            name = String(body[body.index(after: hash)...]).removingPercentEncoding
            body = String(body[..<hash])
        }
        var query: [String: String] = [:]
        if let question = body.firstIndex(of: "?") {
            query = URIParts.parseQuery(String(body[body.index(after: question)...]))
            body = String(body[..<question])
        }
        if body.hasSuffix("/") { body.removeLast() }

        var method: String
        var password: String
        var hostPort: String
        if let at = body.lastIndex(of: "@") {
            let userInfo = String(body[..<at])
            hostPort = String(body[body.index(after: at)...])
            let decodedUser: String
            if let decoded = Base64.decodeString(userInfo), decoded.contains(":") {
                decodedUser = decoded
            } else {
                decodedUser = userInfo.removingPercentEncoding ?? userInfo
            }
            guard let colon = decodedUser.firstIndex(of: ":") else { return nil }
            method = String(decodedUser[..<colon])
            password = String(decodedUser[decodedUser.index(after: colon)...])
        } else {
            // legacy: ss://base64(method:password@host:port)
            guard let decoded = Base64.decodeString(body), let at = decoded.lastIndex(of: "@") else { return nil }
            let userInfo = String(decoded[..<at])
            hostPort = String(decoded[decoded.index(after: at)...])
            guard let colon = userInfo.firstIndex(of: ":") else { return nil }
            method = String(userInfo[..<colon])
            password = String(userInfo[userInfo.index(after: colon)...])
        }
        guard let hostAndPort = URIParts.splitHostPort(hostPort), let port = hostAndPort.1 else { return nil }
        let host = hostAndPort.0
        method = method.lowercased()
        var outbound: [String: JSONValue] = [
            "type": .string("shadowsocks"),
            "server": .string(host),
            "server_port": .int(port),
            "method": .string(method),
            "password": .string(password),
        ]
        if let plugin = query["plugin"], !plugin.isEmpty {
            let parts = plugin.split(separator: ";", maxSplits: 1).map(String.init)
            var pluginName = parts[0]
            if pluginName == "simple-obfs" { pluginName = "obfs-local" }
            guard ["obfs-local", "v2ray-plugin"].contains(pluginName) else { return nil }
            outbound["plugin"] = .string(pluginName)
            if parts.count > 1 {
                outbound["plugin_opts"] = .string(parts[1])
            }
        }
        return ServerNode(name: name ?? "SS \(host)", type: "shadowsocks", host: host, port: port, outbound: outbound)
    }

    // MARK: - Hysteria2

    static func parseHysteria2(_ uri: URIParts) -> ServerNode? {
        let q = uri.query
        let password = uri.userInfo ?? q["auth"] ?? ""
        let ports = uri.portSpec
        guard let firstPort = uri.port ?? ports.flatMap(OutboundBuilder.firstPort) else { return nil }
        var outbound: [String: JSONValue] = [
            "type": .string("hysteria2"),
            "server": .string(uri.host),
            "server_port": .int(firstPort),
            "password": .string(password),
        ]
        let hopping = q["mport"] ?? (uri.port == nil ? ports : nil)
        if let hopping, let ranges = OutboundBuilder.portRanges(hopping), !ranges.isEmpty {
            outbound["server_ports"] = .array(ranges.map { .string($0) })
        }
        if let obfs = q["obfs"], !obfs.isEmpty, obfs != "none" {
            outbound["obfs"] = .object([
                "type": .string(obfs),
                "password": .string(q["obfs-password"] ?? q["obfs_password"] ?? ""),
            ])
        }
        var tls: [String: JSONValue] = ["enabled": .bool(true)]
        tls.put("server_name", q["sni"] ?? q["peer"] ?? (OutboundBuilder.isIP(uri.host) ? nil : uri.host))
        if OutboundBuilder.flag(q["insecure"] ?? q["allowInsecure"]) {
            tls["insecure"] = .bool(true)
        }
        let alpn = OutboundBuilder.list(q["alpn"])
        tls["alpn"] = .array((alpn.isEmpty ? ["h3"] : alpn).map { .string($0) })
        outbound["tls"] = .object(tls)
        return ServerNode(name: uri.name(default: "Hysteria2 \(uri.host)"), type: "hysteria2", host: uri.host, port: firstPort, outbound: outbound)
    }

    // MARK: - TUIC

    static func parseTUIC(_ uri: URIParts) -> ServerNode? {
        guard let port = uri.port, let user = uri.user else { return nil }
        let q = uri.query
        let password = uri.password ?? q["password"] ?? ""
        var outbound: [String: JSONValue] = [
            "type": .string("tuic"),
            "server": .string(uri.host),
            "server_port": .int(port),
            "uuid": .string(user),
            "password": .string(password),
        ]
        outbound.put("congestion_control", q["congestion_control"] ?? q["congestion-control"])
        outbound.put("udp_relay_mode", q["udp_relay_mode"] ?? q["udp-relay-mode"])
        var tls: [String: JSONValue] = ["enabled": .bool(true)]
        if !OutboundBuilder.flag(q["disable_sni"]) {
            tls.put("server_name", q["sni"] ?? (OutboundBuilder.isIP(uri.host) ? nil : uri.host))
        }
        if OutboundBuilder.flag(q["allow_insecure"] ?? q["insecure"] ?? q["allowInsecure"]) {
            tls["insecure"] = .bool(true)
        }
        let alpn = OutboundBuilder.list(q["alpn"])
        tls["alpn"] = .array((alpn.isEmpty ? ["h3"] : alpn).map { .string($0) })
        outbound["tls"] = .object(tls)
        return ServerNode(name: uri.name(default: "TUIC \(uri.host)"), type: "tuic", host: uri.host, port: port, outbound: outbound)
    }

    // MARK: - AnyTLS

    static func parseAnyTLS(_ uri: URIParts) -> ServerNode? {
        guard let port = uri.port else { return nil }
        let q = uri.query
        var outbound: [String: JSONValue] = [
            "type": .string("anytls"),
            "server": .string(uri.host),
            "server_port": .int(port),
            "password": .string(uri.userInfo ?? ""),
        ]
        if let tls = OutboundBuilder.tls(TLSParams(
            security: q["security"] == "reality" ? "reality" : "tls", sni: q["sni"], fingerprint: q["fp"], alpn: q["alpn"],
            insecure: OutboundBuilder.flag(q["insecure"] ?? q["allowInsecure"]), publicKey: q["pbk"], shortID: q["sid"]
        ), host: uri.host, transportHost: nil) {
            outbound["tls"] = .object(tls)
        }
        return ServerNode(name: uri.name(default: "AnyTLS \(uri.host)"), type: "anytls", host: uri.host, port: port, outbound: outbound)
    }

    // MARK: - SOCKS

    static func parseSocks(_ uri: URIParts) -> ServerNode? {
        guard let port = uri.port else { return nil }
        var outbound: [String: JSONValue] = [
            "type": .string("socks"),
            "server": .string(uri.host),
            "server_port": .int(port),
            "version": .string("5"),
        ]
        var user = uri.user
        var password = uri.password
        if let raw = uri.userInfoRaw, password == nil, let decoded = Base64.decodeString(raw), decoded.contains(":") {
            let parts = decoded.split(separator: ":", maxSplits: 1).map(String.init)
            user = parts[0]
            password = parts.count > 1 ? parts[1] : nil
        }
        outbound.put("username", user)
        outbound.put("password", password)
        return ServerNode(name: uri.name(default: "SOCKS \(uri.host)"), type: "socks", host: uri.host, port: port, outbound: outbound)
    }
}

// MARK: - URI splitting

/// Tolerant URI splitter: share links often contain characters URLComponents rejects.
struct URIParts {
    var scheme: String
    var userInfoRaw: String?
    var host: String
    var port: Int?
    var portSpec: String?
    var query: [String: String]
    var fragment: String?

    /// Whole user-info, percent-decoded (passwords may legitimately contain ':').
    var userInfo: String? {
        guard let userInfoRaw else { return nil }
        return userInfoRaw.removingPercentEncoding ?? userInfoRaw
    }

    var user: String? {
        guard let userInfoRaw else { return nil }
        let raw = userInfoRaw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? userInfoRaw
        return raw.removingPercentEncoding ?? raw
    }

    var password: String? {
        guard let userInfoRaw, let colon = userInfoRaw.firstIndex(of: ":") else { return nil }
        let raw = String(userInfoRaw[userInfoRaw.index(after: colon)...])
        return raw.removingPercentEncoding ?? raw
    }

    func name(default fallback: String) -> String {
        if let fragment, !fragment.trimmingCharacters(in: .whitespaces).isEmpty {
            return fragment.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return fallback
    }

    init?(_ string: String) {
        guard let schemeEnd = string.range(of: "://") else { return nil }
        scheme = string[..<schemeEnd.lowerBound].lowercased()
        var rest = String(string[schemeEnd.upperBound...])
        if let hash = rest.firstIndex(of: "#") {
            let raw = String(rest[rest.index(after: hash)...])
            fragment = raw.removingPercentEncoding ?? raw
            rest = String(rest[..<hash])
        }
        query = [:]
        if let question = rest.firstIndex(of: "?") {
            query = URIParts.parseQuery(String(rest[rest.index(after: question)...]))
            rest = String(rest[..<question])
        }
        var authority = rest
        if let slash = authority.firstIndex(of: "/") {
            authority = String(authority[..<slash])
        }
        if let at = authority.lastIndex(of: "@") {
            userInfoRaw = String(authority[..<at])
            authority = String(authority[authority.index(after: at)...])
        }
        guard let parts = URIParts.splitHostPortSpec(authority), !parts.0.isEmpty else { return nil }
        host = parts.0
        port = parts.1
        portSpec = parts.2
    }

    static func parseQuery(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = parts.first, !key.isEmpty else { continue }
            let value = parts.count > 1 ? parts[1] : ""
            result[key.removingPercentEncoding ?? key] = value.removingPercentEncoding ?? value
        }
        return result
    }

    static func splitHostPort(_ value: String) -> (String, Int?)? {
        guard let parts = splitHostPortSpec(value) else { return nil }
        return (parts.0, parts.1)
    }

    /// Returns host, numeric port (when plain) and the raw port spec (for ranges like 443-500).
    static func splitHostPortSpec(_ value: String) -> (String, Int?, String?)? {
        var value = value.trimmingCharacters(in: .whitespaces)
        if value.hasSuffix("/") { value.removeLast() }
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            let host = String(value[value.index(after: value.startIndex) ..< close])
            let after = value[value.index(after: close)...]
            if after.hasPrefix(":") {
                let spec = String(after.dropFirst())
                return (host, Int(spec), spec)
            }
            return (host, nil, nil)
        }
        if let colon = value.lastIndex(of: ":") {
            let host = String(value[..<colon])
            let spec = String(value[value.index(after: colon)...])
            return (host, Int(spec), spec)
        }
        return (value, nil, nil)
    }
}

// MARK: - Base64

public enum Base64 {
    public static func decode(_ string: String) -> Data? {
        var normalized = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !normalized.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
        guard normalized.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        normalized = normalized.replacingOccurrences(of: "=", with: "")
        let remainder = normalized.count % 4
        if remainder == 1 { return nil }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }

    public static func decodeString(_ string: String) -> String? {
        guard let data = decode(string) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
