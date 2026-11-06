import ActivityKit
import Foundation

struct BreezeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var serverName: String
        var flag: String?
        var mode: String
        var since: Date
    }

    var title: String
}
