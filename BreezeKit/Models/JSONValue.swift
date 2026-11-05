import Foundation

/// Minimal ordered-agnostic JSON value used to carry sing-box outbound objects.
public enum JSONValue: Codable, Equatable, Hashable {
    case string(String)
    case number(Double)
    case int(Int)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .int(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    /// Converts Foundation / Yams values (Any) into JSONValue.
    public init?(any value: Any?) {
        switch value {
        case nil:
            return nil
        case let value as JSONValue:
            self = value
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if JSONValue.isBoolean(value) {
                self = .bool(value.boolValue)
            } else if value.doubleValue.rounded() == value.doubleValue {
                self = .int(value.intValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [Any]:
            self = .array(value.compactMap { JSONValue(any: $0) })
        case let value as [String: Any]:
            var object: [String: JSONValue] = [:]
            for (key, item) in value {
                if let converted = JSONValue(any: item) {
                    object[key] = converted
                }
            }
            self = .object(object)
        case let value as [AnyHashable: Any]:
            var object: [String: JSONValue] = [:]
            for (key, item) in value {
                if let converted = JSONValue(any: item) {
                    object["\(key)"] = converted
                }
            }
            self = .object(object)
        default:
            self = .string("\(value!)")
        }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(Darwin)
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
            return String(cString: number.objCType) == "c"
        #endif
    }

    public subscript(key: String) -> JSONValue? {
        if case let .object(object) = self {
            return object[key]
        }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case let .string(value): return value
        case let .int(value): return String(value)
        case let .number(value): return String(value)
        case let .bool(value): return value ? "true" : "false"
        default: return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case let .int(value): return value
        case let .number(value): return Int(value)
        case let .string(value): return Int(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): return value
        case let .int(value): return value != 0
        case let .string(value): return ["true", "1", "yes"].contains(value.lowercased())
        default: return nil
        }
    }

    public var objectValue: [String: JSONValue]? {
        if case let .object(value) = self { return value }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case let .array(value) = self { return value }
        return nil
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// Sets the value only when it is non-nil and not an empty string.
    mutating func put(_ key: String, _ value: String?) {
        if let value, !value.isEmpty {
            self[key] = .string(value)
        }
    }

    mutating func put(_ key: String, _ value: Int?) {
        if let value {
            self[key] = .int(value)
        }
    }

    mutating func put(_ key: String, _ value: Bool?) {
        if let value {
            self[key] = .bool(value)
        }
    }
}

public enum JSONOutput {
    public static func string(_ value: JSONValue, pretty: Bool = false) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
