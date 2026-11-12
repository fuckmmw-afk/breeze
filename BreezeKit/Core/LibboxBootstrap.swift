import Foundation
import Libbox

public enum LibboxBootstrap {
    private static var initialized = false
    private static let lock = NSLock()

    /// Loopback port of the app <-> tunnel command channel. Unique per signed install
    /// so a stale tunnel process or another sing-box app can't hijack it.
    public private(set) static var commandPort: Int32 = 8964

    public static func setCommandPort(_ port: Int32) {
        commandPort = port
        LibboxSetCommandServerPort(port)
    }

    /// Stable port derived from the signing identity and the tunnel bundle id.
    public static func derivePort(from identity: String) -> Int32 {
        var hash: UInt32 = 2_166_136_261
        for byte in identity.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int32(20000 + hash % 30000)
    }

    /// The command channel between the app and the tunnel runs over 127.0.0.1:8964
    /// (libbox "tvOS mode") instead of a unix socket inside an app group container.
    @discardableResult
    public static func setup() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        if initialized {
            return nil
        }
        BreezePaths.prepare()
        let options = LibboxSetupOptions()
        options.basePath = BreezePaths.base.path
        options.workingPath = BreezePaths.working.path
        options.tempPath = BreezePaths.temp.path
        options.isTVOS = true
        var error: NSError?
        LibboxSetup(options, &error)
        if let error {
            return error
        }
        LibboxSetCommandServerPort(commandPort)
        LibboxSetLocale(Locale.current.identifier)
        initialized = true
        return nil
    }

    public static var coreVersion: String {
        LibboxVersion()
    }
}
