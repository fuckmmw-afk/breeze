import Foundation
import NetworkExtension

/// Lightweight VPN control used by widgets, controls and intents.
/// Starts the tunnel with the config the extension persisted on its last run.
enum VPNController {
    enum ControlError: LocalizedError {
        case notConfigured

        var errorDescription: String? {
            "Сначала подключитесь один раз в приложении Breeze."
        }
    }

    static func manager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { $0.protocolConfiguration is NETunnelProviderProtocol } ?? managers.first
    }

    static func status() async -> NEVPNStatus {
        guard let manager = try? await manager() else { return .invalid }
        return manager.connection.status
    }

    static func isActive() async -> Bool {
        let status = await status()
        return status == .connected || status == .connecting || status == .reasserting
    }

    static func connectedDate() async -> Date? {
        guard let manager = try? await manager(), manager.connection.status == .connected else { return nil }
        return manager.connection.connectedDate
    }

    static func start() async throws {
        guard let manager = try await manager() else { throw ControlError.notConfigured }
        if !manager.isEnabled {
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        try manager.connection.startVPNTunnel()
    }

    static func stop() async throws {
        guard let manager = try await manager() else { return }
        if manager.isOnDemandEnabled {
            manager.isOnDemandEnabled = false
            try await manager.saveToPreferences()
        }
        manager.connection.stopVPNTunnel()
    }

    /// Waits until the tunnel settles (connected / disconnected) so widgets refresh with the final state.
    static func waitUntilSettled(timeout: TimeInterval = 8) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let status = await status()
            if status == .connected || status == .disconnected || status == .invalid {
                return
            }
            try? await Task.sleep(nanoseconds: 300 * NSEC_PER_MSEC)
        }
    }
}
