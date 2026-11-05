import Foundation
import Libbox

public enum LibboxBootstrap {
    private static var initialized = false
    private static let lock = NSLock()

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
        LibboxSetLocale(Locale.current.identifier)
        initialized = true
        return nil
    }

    public static var coreVersion: String {
        LibboxVersion()
    }
}
