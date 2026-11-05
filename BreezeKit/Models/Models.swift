import Foundation

/// One proxy server: display name plus a ready sing-box outbound object (without tag).
public struct ServerNode: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var type: String
    public var host: String
    public var port: Int
    public var outbound: [String: JSONValue]

    public init(name: String, type: String, host: String, port: Int, outbound: [String: JSONValue]) {
        self.name = name
        self.type = type
        self.host = host
        self.port = port
        self.outbound = outbound
        id = "\(type)|\(host)|\(port)|\(name)"
    }

    public var displayType: String {
        switch type {
        case "vless": return "VLESS"
        case "vmess": return "VMess"
        case "trojan": return "Trojan"
        case "shadowsocks": return "Shadowsocks"
        case "hysteria2": return "Hysteria2"
        case "hysteria": return "Hysteria"
        case "tuic": return "TUIC"
        case "anytls": return "AnyTLS"
        case "wireguard": return "WireGuard"
        case "socks": return "SOCKS"
        case "http": return "HTTP"
        case "shadowtls": return "ShadowTLS"
        case "ssh": return "SSH"
        default: return type.uppercased()
        }
    }

    public var transportLabel: String? {
        var parts: [String] = []
        if let transport = outbound["transport"]?["type"]?.stringValue {
            parts.append(transport.uppercased())
        }
        if outbound["tls"]?["reality"]?["enabled"]?.boolValue == true {
            parts.append("Reality")
        } else if outbound["tls"]?["enabled"]?.boolValue == true, !["hysteria2", "tuic", "anytls", "hysteria"].contains(type) {
            parts.append("TLS")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// First regional-indicator flag found near the start of the name, if any.
    public var flag: String? {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count >= 2 else { return nil }
        func isIndicator(_ scalar: Unicode.Scalar) -> Bool {
            (0x1F1E6 ... 0x1F1FF).contains(scalar.value)
        }
        for index in 0 ..< min(scalars.count - 1, 8) where isIndicator(scalars[index]) && isIndicator(scalars[index + 1]) {
            var view = String.UnicodeScalarView()
            view.append(scalars[index])
            view.append(scalars[index + 1])
            return String(view)
        }
        return nil
    }

    /// Name without the leading flag.
    public var cleanName: String {
        guard let flag else { return name }
        let trimmed = name.replacingOccurrences(of: flag, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "|-_·")))
        return trimmed.isEmpty ? name : trimmed
    }
}

public struct SubscriptionTraffic: Codable, Hashable {
    public var upload: Int64
    public var download: Int64
    public var total: Int64
    public var expire: Date?

    public var used: Int64 { upload + download }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1, Double(used) / Double(total))
    }
}

public struct Subscription: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable {
        case remote
        case local
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    public var url: String?
    public var content: String?
    public var servers: [ServerNode]
    public var traffic: SubscriptionTraffic?
    public var updatedAt: Date?
    public var updateInterval: TimeInterval?
    public var supportURL: String?

    public init(name: String, kind: Kind, url: String? = nil, content: String? = nil, servers: [ServerNode] = []) {
        id = UUID()
        self.name = name
        self.kind = kind
        self.url = url
        self.content = content
        self.servers = servers
    }
}

public enum RoutingMode: String, Codable, CaseIterable, Identifiable {
    case rule = "Rule"
    case global = "Global"
    case direct = "Direct"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .rule: return "Умный"
        case .global: return "Всё через VPN"
        case .direct: return "Напрямую"
        }
    }

    public var subtitle: String {
        switch self {
        case .rule: return "Российские сайты напрямую, остальное через VPN"
        case .global: return "Весь трафик идёт через сервер"
        case .direct: return "VPN включён, но трафик идёт напрямую"
        }
    }
}

public enum DNSPreset: String, Codable, CaseIterable, Identifiable {
    case cloudflare
    case google
    case quad9
    case adguard

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .google: return "Google"
        case .quad9: return "Quad9"
        case .adguard: return "AdGuard"
        }
    }

    public var server: String {
        switch self {
        case .cloudflare: return "1.1.1.1"
        case .google: return "8.8.8.8"
        case .quad9: return "9.9.9.9"
        case .adguard: return "94.140.14.14"
        }
    }
}

public struct AppSettings: Codable, Equatable {
    public var routingMode: RoutingMode = .rule
    public var bypassRussia = true
    public var blockAds = false
    public var enableIPv6 = false
    public var dns: DNSPreset = .cloudflare
    public var directDNS = "77.88.8.8"
    public var urlTestURL = "https://www.gstatic.com/generate_204"
    public var subscriptionUserAgent = "v2rayN/7.10"
    public var autoUpdateSubscriptions = true
    public var logLevel = "warn"
    public var excludeAPNs = true

    public init() {}

    public init(from decoder: Decoder) throws {
        // tolerant decoding: new fields fall back to defaults
        let defaults = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        routingMode = (try? c.decode(RoutingMode.self, forKey: .routingMode)) ?? defaults.routingMode
        bypassRussia = (try? c.decode(Bool.self, forKey: .bypassRussia)) ?? defaults.bypassRussia
        blockAds = (try? c.decode(Bool.self, forKey: .blockAds)) ?? defaults.blockAds
        enableIPv6 = (try? c.decode(Bool.self, forKey: .enableIPv6)) ?? defaults.enableIPv6
        dns = (try? c.decode(DNSPreset.self, forKey: .dns)) ?? defaults.dns
        directDNS = (try? c.decode(String.self, forKey: .directDNS)) ?? defaults.directDNS
        urlTestURL = (try? c.decode(String.self, forKey: .urlTestURL)) ?? defaults.urlTestURL
        subscriptionUserAgent = (try? c.decode(String.self, forKey: .subscriptionUserAgent)) ?? defaults.subscriptionUserAgent
        autoUpdateSubscriptions = (try? c.decode(Bool.self, forKey: .autoUpdateSubscriptions)) ?? defaults.autoUpdateSubscriptions
        logLevel = (try? c.decode(String.self, forKey: .logLevel)) ?? defaults.logLevel
        excludeAPNs = (try? c.decode(Bool.self, forKey: .excludeAPNs)) ?? defaults.excludeAPNs
    }
}
