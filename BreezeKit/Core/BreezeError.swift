import Foundation

public struct BreezeError: LocalizedError, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }

    public var nsError: NSError {
        NSError(domain: "com.fuckmmw.breeze", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
