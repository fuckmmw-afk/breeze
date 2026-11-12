import Foundation

/// Optional shared container used only for diagnostics (logs the app can read even
/// when the tunnel failed to start). The group id is taken from whatever profile the
/// app was signed with, so nothing is hardcoded.
public enum SharedGroup {
    public static let optionKey = "group"

    /// App side: groups listed in embedded.mobileprovision that are actually usable.
    public static func discover() -> String? {
        let candidates = profileGroups() + SigningInfo.inspect(Bundle.main).groups.sorted()
        for group in candidates where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
            return group
        }
        return nil
    }

    public static func container(_ group: String?) -> URL? {
        guard let group, !group.isEmpty,
              let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        else { return nil }
        let dir = url.appendingPathComponent("Breeze", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func profileGroups() -> [String] {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound ..< data.endIndex)
        else { return [] }
        let plistData = data.subdata(in: start.lowerBound ..< end.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups.sorted()
    }
}

/// Timestamped step log written by the tunnel extension into the shared group.
public final class DiagnosticLog {
    public static let fileName = "tunnel-diag.log"
    public static let launchName = "tunnel-launch.log"
    public static let boxLogName = "box.log"
    public static let stderrName = "stderr.log"

    private let url: URL?
    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    public init(directory: URL?) {
        url = directory?.appendingPathComponent(Self.fileName)
    }

    public func reset() {
        guard let url else { return }
        try? Data().write(to: url)
    }

    public func write(_ message: String) {
        guard let url else { return }
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// App side: reads a diagnostic file from the shared container (tail only).
    public static func read(_ name: String, group: String?, maxBytes: Int = 64 * 1024) -> String? {
        guard let dir = SharedGroup.container(group) else { return nil }
        let url = dir.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        let data = handle.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }
}
