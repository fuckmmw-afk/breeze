import Foundation
import Network

/// Tunnel side of the network automation: when the device moves between Wi‑Fi and
/// cellular, points the main selector at that network's group and re-tests it so the
/// fastest server wins. The rules live in the config itself (the breeze-wifi /
/// breeze-cellular groups), so nothing else has to reach the extension.
final class NetworkAutomationRunner {
    private struct Target {
        var tag: String
        var isURLTest: Bool
    }

    private let queue = DispatchQueue(label: "breeze.automation")
    private var targets: [NetworkKind: Target] = [:]
    /// The config was built for "use the automation on this network" rather than a hand-picked server.
    private var applyOnStart = false
    private var lastKind: NetworkKind?
    private var pending: DispatchWorkItem?
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    /// `fresh`: a new tunnel start (the first network seen may be applied); reloads keep the state
    /// so a server picked by hand survives until the network actually changes.
    func configure(config: String, fresh: Bool) {
        let parsed = Self.parse(config)
        queue.async { [self] in
            targets = parsed.targets
            applyOnStart = parsed.defaultIsAutomation
            if fresh { lastKind = nil }
            if !targets.isEmpty {
                log("automation: " + targets.map { "\($0.key.rawValue)→\($0.value.tag)\($0.value.isURLTest ? " (urltest)" : "")" }.sorted().joined(separator: ", "))
            }
        }
    }

    func pathChanged(_ path: NWPath) {
        let kind = NetworkKind(path: path)
        queue.async { [self] in
            guard let kind, !targets.isEmpty else { return }
            pending?.cancel()
            // networks flap while switching; act once things settle
            let work = DispatchWorkItem { [weak self] in self?.apply(kind) }
            pending = work
            queue.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func apply(_ kind: NetworkKind) {
        guard kind != lastKind else { return }
        let first = lastKind == nil
        lastKind = kind
        if first, !applyOnStart { return }
        guard let target = targets[kind] else {
            log("automation: \(kind.rawValue), no rule")
            return
        }
        log("automation: network \(kind.rawValue) → \(target.tag)")
        DispatchQueue.global(qos: .userInitiated).async { [log] in
            // the service may still be starting
            for attempt in 0 ..< 5 {
                do {
                    try TunnelCommands.selectOutbound(group: ConfigBuilder.selectorTag, outbound: target.tag)
                    if target.isURLTest {
                        try? TunnelCommands.urlTest(group: target.tag)
                    }
                    return
                } catch {
                    log("automation: select attempt \(attempt + 1): \(error.localizedDescription)")
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
    }

    private static func parse(_ config: String) -> (targets: [NetworkKind: Target], defaultIsAutomation: Bool) {
        guard let data = config.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]],
              let selector = outbounds.first(where: { $0["tag"] as? String == ConfigBuilder.selectorTag })
        else { return ([:], false) }
        let items = Set(selector["outbounds"] as? [String] ?? [])
        var targets: [NetworkKind: Target] = [:]
        for outbound in outbounds {
            guard let tag = outbound["tag"] as? String, items.contains(tag),
                  let kind = ConfigBuilder.networkKind(ofTag: tag)
            else { continue }
            targets[kind] = Target(tag: tag, isURLTest: outbound["type"] as? String == "urltest")
        }
        let defaultTag = selector["default"] as? String ?? ""
        return (targets, ConfigBuilder.networkKind(ofTag: defaultTag) != nil)
    }
}
