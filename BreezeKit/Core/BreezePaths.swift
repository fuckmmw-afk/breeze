import Foundation

/// Every process (app and tunnel extension) keeps its own private container.
/// Nothing here depends on an app group, so the app survives any re-signing.
public enum BreezePaths {
    public static let base: URL = FileManager.default
        .urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Breeze", isDirectory: true)

    public static let working = base.appendingPathComponent("Working", isDirectory: true)

    public static let temp: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Breeze", isDirectory: true)

    public static func prepare() {
        for url in [base, working, temp] {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}
