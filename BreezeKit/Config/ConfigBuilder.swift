import Foundation

/// Builds a complete sing-box 1.12 configuration from servers and app settings.
public enum ConfigBuilder {
    public static let selectorTag = "proxy"
    public static let autoTag = "auto"
    public static let directTag = "direct"

    private static let ruleSetBase = "https://raw.githubusercontent.com/SagerNet"

    public static func build(servers: [ServerNode], selected: String?, settings: AppSettings) -> String {
        var outbounds: [JSONValue] = []
        let tags = servers.map(\.name)

        let defaultTag: String
        if let selected, selected == autoTag || tags.contains(selected) {
            defaultTag = selected
        } else {
            defaultTag = tags.count > 1 ? autoTag : (tags.first ?? directTag)
        }

        var selectorItems = tags
        if tags.count > 1 {
            selectorItems.insert(autoTag, at: 0)
        }
        if selectorItems.isEmpty {
            selectorItems = [directTag]
        }
        outbounds.append(.object([
            "type": .string("selector"),
            "tag": .string(selectorTag),
            "outbounds": .array(selectorItems.map { .string($0) }),
            "default": .string(defaultTag),
            "interrupt_exist_connections": .bool(true),
        ]))
        if tags.count > 1 {
            outbounds.append(.object([
                "type": .string("urltest"),
                "tag": .string(autoTag),
                "outbounds": .array(tags.map { .string($0) }),
                "url": .string(settings.urlTestURL),
                "interval": .string("5m"),
                "tolerance": .int(80),
                "idle_timeout": .string("30m"),
                "interrupt_exist_connections": .bool(false),
            ]))
        }
        for server in servers {
            var outbound = server.outbound
            outbound["tag"] = .string(server.name)
            outbounds.append(.object(outbound))
        }
        outbounds.append(.object(["type": .string("direct"), "tag": .string(directTag)]))

        let config: [String: JSONValue] = [
            "log": .object([
                "level": .string(settings.logLevel),
                "timestamp": .bool(true),
            ]),
            "dns": dns(settings),
            "inbounds": .array([tun(settings)]),
            "outbounds": .array(outbounds),
            "route": route(settings),
            "experimental": .object([
                "cache_file": .object([
                    "enabled": .bool(true),
                    "store_rdrc": .bool(true),
                ]),
                "clash_api": .object([
                    "default_mode": .string(settings.routingMode.rawValue),
                ]),
            ]),
        ]
        return JSONOutput.string(.object(config), pretty: true)
    }

    private static func tun(_ settings: AppSettings) -> JSONValue {
        var addresses: [JSONValue] = [.string("172.19.0.1/30")]
        if settings.enableIPv6 {
            addresses.append(.string("fdfe:dcba:9876::1/126"))
        }
        return .object([
            "type": .string("tun"),
            "tag": .string("tun-in"),
            "address": .array(addresses),
            "mtu": .int(9000),
            "auto_route": .bool(true),
            "strict_route": .bool(true),
            "stack": .string("mixed"),
        ])
    }

    private static func dns(_ settings: AppSettings) -> JSONValue {
        var rules: [JSONValue] = [
            .object(["clash_mode": .string(RoutingMode.direct.rawValue), "server": .string("dns-direct")]),
            .object(["clash_mode": .string(RoutingMode.global.rawValue), "server": .string("dns-remote")]),
        ]
        if settings.blockAds {
            rules.append(.object([
                "rule_set": .array([.string("geosite-category-ads-all")]),
                "action": .string("reject"),
            ]))
        }
        if settings.bypassRussia {
            rules.append(.object([
                "rule_set": .array([.string("geosite-category-ru"), .string("geosite-yandex"), .string("geosite-vk")]),
                "server": .string("dns-direct"),
            ]))
            rules.append(.object([
                "domain_suffix": .array([".ru", ".su", ".xn--p1ai", ".by"]),
                "server": .string("dns-direct"),
            ]))
        }
        return .object([
            "servers": .array([
                .object([
                    "type": .string("https"),
                    "tag": .string("dns-remote"),
                    "server": .string(settings.dns.server),
                    "detour": .string(selectorTag),
                ]),
                .object([
                    "type": .string("udp"),
                    "tag": .string("dns-direct"),
                    "server": .string(settings.directDNS),
                ]),
            ]),
            "rules": .array(rules),
            "final": .string("dns-remote"),
            "strategy": .string(settings.enableIPv6 ? "prefer_ipv4" : "ipv4_only"),
            "independent_cache": .bool(true),
        ])
    }

    private static func route(_ settings: AppSettings) -> JSONValue {
        var rules: [JSONValue] = [
            .object(["action": .string("sniff")]),
            .object(["protocol": .string("dns"), "action": .string("hijack-dns")]),
            .object(["ip_is_private": .bool(true), "outbound": .string(directTag)]),
            .object(["clash_mode": .string(RoutingMode.direct.rawValue), "outbound": .string(directTag)]),
            .object(["clash_mode": .string(RoutingMode.global.rawValue), "outbound": .string(selectorTag)]),
        ]
        var ruleSets: [JSONValue] = []
        if settings.blockAds {
            rules.append(.object([
                "rule_set": .array([.string("geosite-category-ads-all")]),
                "action": .string("reject"),
            ]))
            ruleSets.append(remoteRuleSet("geosite-category-ads-all", repo: "sing-geosite"))
        }
        if settings.bypassRussia {
            rules.append(.object([
                "domain_suffix": .array([".ru", ".su", ".xn--p1ai", ".by"]),
                "outbound": .string(directTag),
            ]))
            rules.append(.object([
                "rule_set": .array([
                    .string("geosite-category-ru"), .string("geosite-yandex"), .string("geosite-vk"), .string("geoip-ru"),
                ]),
                "outbound": .string(directTag),
            ]))
            ruleSets.append(remoteRuleSet("geosite-category-ru", repo: "sing-geosite"))
            ruleSets.append(remoteRuleSet("geosite-yandex", repo: "sing-geosite"))
            ruleSets.append(remoteRuleSet("geosite-vk", repo: "sing-geosite"))
            ruleSets.append(remoteRuleSet("geoip-ru", repo: "sing-geoip"))
        }
        var route: [String: JSONValue] = [
            "rules": .array(rules),
            "final": .string(selectorTag),
            "auto_detect_interface": .bool(true),
            "default_domain_resolver": .object([
                "server": .string("dns-direct"),
                "strategy": .string("prefer_ipv4"),
            ]),
        ]
        if !ruleSets.isEmpty {
            route["rule_set"] = .array(ruleSets)
        }
        return .object(route)
    }

    private static func remoteRuleSet(_ tag: String, repo: String) -> JSONValue {
        .object([
            "type": .string("remote"),
            "tag": .string(tag),
            "format": .string("binary"),
            "url": .string("\(ruleSetBase)/\(repo)/rule-set/\(tag).srs"),
            // download through the proxy: raw.githubusercontent.com is often throttled
            "download_detour": .string(selectorTag),
            "update_interval": .string("72h"),
        ])
    }
}
