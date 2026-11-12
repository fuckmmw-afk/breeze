import Foundation

/// Builds a complete sing-box 1.12 configuration from servers and app settings.
public enum ConfigBuilder {
    public static let selectorTag = "proxy"
    public static let autoTag = "auto"
    public static let directTag = "direct"

    /// Rule-set files shipped inside BreezeKit.framework (downloaded at build time),
    /// so the tunnel never has to fetch anything before it starts.
    public static var bundledRuleSets: URL? {
        Bundle(for: BundleToken.self).url(forResource: "rules", withExtension: nil)
    }

    public static func build(servers: [ServerNode], selected: String?, settings: AppSettings, ruleSetDirectory: URL? = bundledRuleSets) -> String {
        var outbounds: [JSONValue] = []
        let tags = servers.map(\.name)

        let defaultTag: String
        if let selected, selected == autoTag, tags.count > 1 {
            defaultTag = autoTag
        } else if let selected, tags.contains(selected) {
            defaultTag = selected
        } else {
            defaultTag = tags.count > 1 ? autoTag : (tags.first ?? directTag)
        }
        // the urltest group probes every server periodically; only run it when it is actually used,
        // the tunnel extension has a tight memory budget
        let useAuto = defaultTag == autoTag

        var selectorItems = tags
        if useAuto {
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
        if useAuto {
            outbounds.append(.object([
                "type": .string("urltest"),
                "tag": .string(autoTag),
                "outbounds": .array(tags.map { .string($0) }),
                "url": .string(settings.urlTestURL),
                "interval": .string("10m"),
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
            "dns": dns(settings, ruleSets: availableRuleSets(ruleSetDirectory)),
            "inbounds": .array([tun(settings)]),
            "outbounds": .array(outbounds),
            "route": route(settings, ruleSets: availableRuleSets(ruleSetDirectory)),
            // no cache_file: it would restore an old selector choice over the one picked in the app
            "experimental": .object([
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

    private static func availableRuleSets(_ directory: URL?) -> [String: String] {
        guard let directory else { return [:] }
        var result: [String: String] = [:]
        let names = ["geosite-category-ads-all", "geosite-category-ru", "geosite-yandex", "geosite-vk", "geoip-ru"]
        for name in names {
            let url = directory.appendingPathComponent("\(name).srs")
            if FileManager.default.fileExists(atPath: url.path) {
                result[name] = url.path
            }
        }
        return result
    }

    private static func dns(_ settings: AppSettings, ruleSets: [String: String]) -> JSONValue {
        var rules: [JSONValue] = [
            .object(["clash_mode": .string(RoutingMode.direct.rawValue), "server": .string("dns-direct")]),
            .object(["clash_mode": .string(RoutingMode.global.rawValue), "server": .string("dns-remote")]),
        ]
        if settings.blockAds, ruleSets["geosite-category-ads-all"] != nil {
            rules.append(.object([
                "rule_set": .array([.string("geosite-category-ads-all")]),
                "action": .string("reject"),
            ]))
        }
        if settings.bypassRussia {
            let sites = ["geosite-category-ru", "geosite-yandex", "geosite-vk"].filter { ruleSets[$0] != nil }
            if !sites.isEmpty {
                rules.append(.object([
                    "rule_set": .array(sites.map { .string($0) }),
                    "server": .string("dns-direct"),
                ]))
            }
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
                // system resolver, like other clients: operators may answer differently than public DNS
                .object([
                    "type": .string("local"),
                    "tag": .string("dns-direct"),
                ]),
            ]),
            "rules": .array(rules),
            "final": .string("dns-remote"),
            "strategy": .string(settings.enableIPv6 ? "prefer_ipv4" : "ipv4_only"),
            "independent_cache": .bool(true),
        ])
    }

    private static func route(_ settings: AppSettings, ruleSets available: [String: String]) -> JSONValue {
        var rules: [JSONValue] = [
            .object(["action": .string("sniff")]),
            .object(["protocol": .string("dns"), "action": .string("hijack-dns")]),
            .object(["ip_is_private": .bool(true), "outbound": .string(directTag)]),
            .object(["clash_mode": .string(RoutingMode.direct.rawValue), "outbound": .string(directTag)]),
            .object(["clash_mode": .string(RoutingMode.global.rawValue), "outbound": .string(selectorTag)]),
        ]
        var used: [String] = []
        if settings.blockAds, available["geosite-category-ads-all"] != nil {
            rules.append(.object([
                "rule_set": .array([.string("geosite-category-ads-all")]),
                "action": .string("reject"),
            ]))
            used.append("geosite-category-ads-all")
        }
        if settings.bypassRussia {
            rules.append(.object([
                "domain_suffix": .array([".ru", ".su", ".xn--p1ai", ".by"]),
                "outbound": .string(directTag),
            ]))
            let russian = ["geosite-category-ru", "geosite-yandex", "geosite-vk", "geoip-ru"].filter { available[$0] != nil }
            if !russian.isEmpty {
                rules.append(.object([
                    "rule_set": .array(russian.map { .string($0) }),
                    "outbound": .string(directTag),
                ]))
                used.append(contentsOf: russian)
            }
        }
        let ruleSets: [JSONValue] = used.compactMap { tag in
            guard let path = available[tag] else { return nil }
            return .object([
                "type": .string("local"),
                "tag": .string(tag),
                "format": .string("binary"),
                "path": .string(path),
            ])
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

}

private final class BundleToken {}
