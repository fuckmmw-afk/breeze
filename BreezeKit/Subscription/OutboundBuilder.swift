import Foundation

struct TLSParams {
    var security: String
    var sni: String?
    var fingerprint: String?
    var alpn: String?
    var insecure: Bool
    var publicKey: String?
    var shortID: String?
}

struct TransportParams {
    var network: String
    var path: String?
    var host: String?
    var serviceName: String?
    var headerType: String?
    var maxEarlyData: Int?
    var earlyDataHeader: String?
}

enum OutboundBuilder {
    static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    static func list(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func isIP(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    static func firstPort(_ spec: String) -> Int? {
        let digits = spec.prefix { $0.isNumber }
        return Int(digits)
    }

    /// "443-500,600" -> ["443:500", "600:600"]
    static func portRanges(_ spec: String) -> [String]? {
        var result: [String] = []
        for part in spec.split(separator: ",") {
            let bounds = part.split(whereSeparator: { $0 == "-" || $0 == ":" }).map { $0.trimmingCharacters(in: .whitespaces) }
            if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]) {
                result.append("\(low):\(high)")
            } else if bounds.count == 1, let single = Int(bounds[0]) {
                result.append("\(single):\(single)")
            }
        }
        return result
    }

    /// Returns nil when security is none.
    static func tls(_ params: TLSParams, host: String, transportHost: String?) -> [String: JSONValue]? {
        let security = params.security.lowercased()
        guard security == "tls" || security == "reality" || security == "xtls" else {
            return nil
        }
        var tls: [String: JSONValue] = ["enabled": .bool(true)]
        var serverName = params.sni
        if serverName == nil || serverName!.isEmpty {
            if let transportHost, !transportHost.isEmpty {
                serverName = transportHost.split(separator: ",").first.map(String.init)
            } else if !isIP(host) {
                serverName = host
            }
        }
        tls.put("server_name", serverName)
        if params.insecure {
            tls["insecure"] = .bool(true)
        }
        let alpn = list(params.alpn)
        if !alpn.isEmpty {
            tls["alpn"] = .array(alpn.map { .string($0) })
        }
        var fingerprint = params.fingerprint?.lowercased()
        if fingerprint == "random" || fingerprint == "randomized" { fingerprint = "randomized" }
        if security == "reality" {
            guard let publicKey = params.publicKey, !publicKey.isEmpty else { return nil }
            var reality: [String: JSONValue] = ["enabled": .bool(true), "public_key": .string(publicKey)]
            reality.put("short_id", params.shortID)
            tls["reality"] = .object(reality)
            // reality needs a uTLS client hello
            tls["utls"] = .object(["enabled": .bool(true), "fingerprint": .string(fingerprint?.isEmpty == false ? fingerprint! : "chrome")])
        } else if let fingerprint, !fingerprint.isEmpty, fingerprint != "none" {
            tls["utls"] = .object(["enabled": .bool(true), "fingerprint": .string(fingerprint)])
        }
        return tls
    }

    /// Returns an empty dictionary for plain TCP and nil for transports sing-box can't speak.
    static func transport(_ params: TransportParams) -> [String: JSONValue]? {
        let network = params.network.lowercased()
        switch network {
        case "", "tcp", "raw", "none":
            if params.headerType?.lowercased() == "http" {
                var http: [String: JSONValue] = ["type": .string("http")]
                let hosts = list(params.host)
                if !hosts.isEmpty { http["host"] = .array(hosts.map { .string($0) }) }
                http.put("path", params.path)
                http["method"] = .string("GET")
                return http
            }
            return [:]
        case "ws", "websocket":
            var ws: [String: JSONValue] = ["type": .string("ws")]
            var path = params.path ?? "/"
            var earlyData = params.maxEarlyData
            var earlyHeader = params.earlyDataHeader
            // xray style early data: /path?ed=2048
            if let range = path.range(of: "?ed=") {
                let value = path[range.upperBound...].prefix { $0.isNumber }
                earlyData = Int(value)
                earlyHeader = earlyHeader ?? "Sec-WebSocket-Protocol"
                path = String(path[..<range.lowerBound])
            }
            ws["path"] = .string(path.isEmpty ? "/" : path)
            if let host = params.host, !host.isEmpty {
                ws["headers"] = .object(["Host": .string(host)])
            }
            if let earlyData, earlyData > 0 {
                ws["max_early_data"] = .int(earlyData)
                ws["early_data_header_name"] = .string(earlyHeader ?? "Sec-WebSocket-Protocol")
            }
            return ws
        case "grpc", "gun":
            var grpc: [String: JSONValue] = ["type": .string("grpc")]
            grpc.put("service_name", params.serviceName ?? params.path)
            return grpc
        case "http", "h2":
            var http: [String: JSONValue] = ["type": .string("http")]
            let hosts = list(params.host)
            if !hosts.isEmpty { http["host"] = .array(hosts.map { .string($0) }) }
            http.put("path", params.path)
            return http
        case "httpupgrade":
            var upgrade: [String: JSONValue] = ["type": .string("httpupgrade")]
            upgrade.put("host", params.host)
            upgrade.put("path", params.path ?? "/")
            return upgrade
        case "quic":
            return ["type": .string("quic")]
        default:
            // xhttp / splithttp / kcp are not implemented by sing-box
            return nil
        }
    }
}
