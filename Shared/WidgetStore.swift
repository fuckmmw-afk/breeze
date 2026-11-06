import Foundation
import WidgetKit

/// Small snapshot the app shares with widgets through the profile's app group.
struct WidgetSnapshot: Codable {
    var serverName: String
    var flag: String?
    var mode: String
    var subscription: String?
    var updatedAt: Date
}

enum WidgetStore {
    static let statusKind = "BreezeStatus"
    static let controlKind = "BreezeVPNToggle"
    private static let key = "widgetSnapshot"

    static var defaults: UserDefaults? {
        guard let group = WidgetGroup.identifier else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: key)
    }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func reloadAll() {
        WidgetCenter.shared.reloadAllTimelines()
        if #available(iOS 18.0, *) {
            ControlCenter.shared.reloadControls(ofKind: controlKind)
        }
    }
}

/// App group from whatever profile the bundle was signed with.
enum WidgetGroup {
    static let identifier: String? = {
        for group in candidates() where FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil {
            return group
        }
        return nil
    }()

    private static func candidates() -> [String] {
        var groups: [String] = []
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let plist = plist(in: data, start: "<?xml", end: "</plist>"),
           let entitlements = plist["Entitlements"] as? [String: Any],
           let list = entitlements["com.apple.security.application-groups"] as? [String]
        {
            groups.append(contentsOf: list.sorted())
        }
        if let executable = Bundle.main.executableURL,
           let data = try? Data(contentsOf: executable, options: .mappedIfSafe),
           let entitlements = entitlements(in: data),
           let list = entitlements["com.apple.security.application-groups"] as? [String]
        {
            groups.append(contentsOf: list.sorted())
        }
        return groups
    }

    private static func plist(in data: Data, start: String, end: String) -> [String: Any]? {
        guard let lower = data.range(of: Data(start.utf8)),
              let upper = data.range(of: Data(end.utf8), in: lower.lowerBound ..< data.endIndex)
        else { return nil }
        let body = data.subdata(in: lower.lowerBound ..< upper.upperBound)
        return try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
    }

    /// Entitlements blob (magic 0xFADE7171) from the code signature.
    private static func entitlements(in data: Data) -> [String: Any]? {
        let magic = Data([0xFA, 0xDE, 0x71, 0x71])
        var range = data.startIndex ..< data.endIndex
        var result: [String: Any]?
        while let found = data.range(of: magic, in: range) {
            let lengthStart = found.upperBound
            guard lengthStart + 4 <= data.endIndex else { break }
            let length = data[lengthStart ..< lengthStart + 4].reduce(0) { ($0 << 8) | Int($1) }
            let bodyEnd = found.lowerBound + length
            if length > 8, bodyEnd <= data.endIndex,
               let plist = try? PropertyListSerialization.propertyList(from: data.subdata(in: lengthStart + 4 ..< bodyEnd), format: nil) as? [String: Any]
            {
                result = plist
            }
            range = found.upperBound ..< data.endIndex
        }
        return result
    }
}
