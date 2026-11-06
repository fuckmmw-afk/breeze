import Foundation

/// In-app event log (app process). Survives only in memory plus a small file,
/// and does not depend on the tunnel extension at all.
public final class EventLog: ObservableObject {
    public static let shared = EventLog()

    @Published public private(set) var lines: [String] = []
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public func add(_ message: String) {
        let line = "\(formatter.string(from: Date())) \(message)"
        NSLog("[Breeze] %@", message)
        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 400 {
                self.lines.removeFirst(self.lines.count - 400)
            }
        }
    }
}

/// Reads code-signing facts of the installed app and its tunnel extension,
/// so a broken re-sign can be diagnosed on the device.
public enum SigningInfo {
    public struct Bundle {
        public var name: String
        public var bundleID: String
        public var hasProfile: Bool
        public var signed: Bool
        public var entitlements: [String: Any]

        public var networkExtension: [String] {
            entitlements["com.apple.developer.networking.networkextension"] as? [String] ?? []
        }

        public var groups: [String] {
            entitlements["com.apple.security.application-groups"] as? [String] ?? []
        }

        public var applicationIdentifier: String {
            entitlements["application-identifier"] as? String ?? "—"
        }
    }

    public static func app() -> Bundle {
        inspect(Foundation.Bundle.main)
    }

    public static func tunnel() -> Bundle? {
        guard let plugins = Foundation.Bundle.main.builtInPlugInsURL,
              let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        else { return nil }
        for url in items where url.pathExtension == "appex" {
            if let bundle = Foundation.Bundle(url: url),
               let ext = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
               ext["NSExtensionPointIdentifier"] as? String == "com.apple.networkextension.packet-tunnel"
            {
                return inspect(bundle)
            }
        }
        return nil
    }

    static func inspect(_ bundle: Foundation.Bundle) -> Bundle {
        let profile = bundle.bundleURL.appendingPathComponent("embedded.mobileprovision")
        var entitlements: [String: Any] = [:]
        var signed = false
        if let executable = bundle.executableURL, let data = try? Data(contentsOf: executable, options: .mappedIfSafe) {
            signed = data.range(of: Data([0xFA, 0xDE, 0x0C, 0xC0])) != nil
            entitlements = readEntitlements(data) ?? [:]
        }
        return Bundle(
            name: bundle.bundleURL.lastPathComponent,
            bundleID: bundle.bundleIdentifier ?? "—",
            hasProfile: FileManager.default.fileExists(atPath: profile.path),
            signed: signed,
            entitlements: entitlements
        )
    }

    /// Finds the entitlements blob (magic 0xFADE7171) in the code signature.
    static func readEntitlements(_ data: Data) -> [String: Any]? {
        let magic = Data([0xFA, 0xDE, 0x71, 0x71])
        var searchRange = data.startIndex ..< data.endIndex
        var result: [String: Any]?
        while let found = data.range(of: magic, in: searchRange) {
            let lengthStart = found.upperBound
            guard lengthStart + 4 <= data.endIndex else { break }
            let length = data[lengthStart ..< lengthStart + 4].reduce(0) { ($0 << 8) | Int($1) }
            let bodyStart = lengthStart + 4
            let bodyEnd = found.lowerBound + length
            if length > 8, bodyEnd <= data.endIndex {
                let body = data.subdata(in: bodyStart ..< bodyEnd)
                if let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] {
                    result = plist
                }
            }
            searchRange = found.upperBound ..< data.endIndex
        }
        return result
    }

    public static func report() -> String {
        var lines: [String] = []
        func describe(_ bundle: Bundle) {
            lines.append("\(bundle.name): id=\(bundle.bundleID) signed=\(bundle.signed) profile=\(bundle.hasProfile)")
            lines.append("  app-id=\(bundle.applicationIdentifier)")
            lines.append("  NE=\(bundle.networkExtension.joined(separator: ",").ifEmpty("НЕТ"))")
            lines.append("  groups=\(bundle.groups.joined(separator: ",").ifEmpty("нет"))")
        }
        describe(app())
        if let tunnel = tunnel() {
            describe(tunnel)
        } else {
            lines.append("tunnel extension: НЕ НАЙДЕНО")
        }
        lines.append("profile groups: \(SharedGroup.profileGroups().joined(separator: ",").ifEmpty("нет"))")
        return lines.joined(separator: "\n")
    }
}

extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
    }
}
