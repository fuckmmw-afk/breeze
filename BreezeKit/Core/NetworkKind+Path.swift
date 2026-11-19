import Foundation
import Network

public extension NetworkKind {
    /// Physical network behind the default route; the VPN's own utun is ignored.
    /// Ethernet counts as Wi‑Fi.
    init?(path: NWPath) {
        guard path.status != .unsatisfied,
              let interface = path.availableInterfaces.first(where: { $0.type != .other && $0.type != .loopback })
        else { return nil }
        switch interface.type {
        case .wifi, .wiredEthernet: self = .wifi
        case .cellular: self = .cellular
        default: return nil
        }
    }
}
