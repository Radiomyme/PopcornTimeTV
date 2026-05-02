

import Foundation

/// Minimal SwiftyJSON-compatible shim covering the subset of the API used
/// across PopcornKit. Lets us drop the SwiftyJSON dependency without rewriting
/// every callsite.
///
/// Supports:
///   - `JSON(value)` constructor from `Any`
///   - subscript by `Int` and `String` (returns another `JSON`)
///   - `.string` → `String?`, `.string ?? ""` style usage
///   - `.array` → `[JSON]?`, `.arrayValue` → `[JSON]`, `.dictionary` / `.dictionaryValue`
///   - `.first` and `.first(where:)` returning `(String, JSON)` pairs
///   - `for (key, value) in JSON(...)` enumeration over dict members
public struct JSON {
    public let raw: Any?

    public init(_ value: Any?) {
        if let json = value as? JSON {
            self.raw = json.raw
        } else if value is NSNull {
            self.raw = nil
        } else {
            self.raw = value
        }
    }

    public subscript(key: String) -> JSON {
        return JSON((raw as? [String: Any])?[key])
    }

    public subscript(index: Int) -> JSON {
        guard let array = raw as? [Any], index >= 0, index < array.count else {
            return JSON(nil)
        }
        return JSON(array[index])
    }

    public var string: String?           { raw as? String }
    public var int: Int?                 { (raw as? Int) ?? (raw as? NSNumber)?.intValue }
    public var double: Double?           { (raw as? Double) ?? (raw as? NSNumber)?.doubleValue }
    public var float: Float?             { (raw as? Float) ?? (raw as? NSNumber)?.floatValue }
    public var bool: Bool?               { (raw as? Bool) ?? (raw as? NSNumber)?.boolValue }
    public var dictionary: [String: JSON]? {
        guard let dict = raw as? [String: Any] else { return nil }
        return dict.mapValues { JSON($0) }
    }
    public var dictionaryValue: [String: JSON] { dictionary ?? [:] }
    public var array: [JSON]?            { (raw as? [Any]).map { $0.map { JSON($0) } } }
    public var arrayValue: [JSON]        { array ?? [] }
    public var dictionaryObject: [String: Any]? { raw as? [String: Any] }
    public var arrayObject: [Any]?       { raw as? [Any] }

    public var first: (String, JSON)? {
        guard let dict = raw as? [String: Any], let pair = dict.first else { return nil }
        return (pair.key, JSON(pair.value))
    }

    public func first(where predicate: ((String, JSON)) throws -> Bool) rethrows -> (String, JSON)? {
        guard let dict = raw as? [String: Any] else { return nil }
        for (k, v) in dict {
            if try predicate((k, JSON(v))) { return (k, JSON(v)) }
        }
        return nil
    }
}

extension JSON: Sequence {
    public func makeIterator() -> AnyIterator<(String, JSON)> {
        if let dict = raw as? [String: Any] {
            var it = dict.makeIterator()
            return AnyIterator { it.next().map { ($0.key, JSON($0.value)) } }
        }
        if let array = raw as? [Any] {
            var idx = 0
            var it = array.makeIterator()
            return AnyIterator {
                guard let next = it.next() else { return nil }
                defer { idx += 1 }
                return (String(idx), JSON(next))
            }
        }
        return AnyIterator { nil }
    }
}

/// Convenience used by callers that wrote `responseObject.first?.1["key"]…`.
extension Optional where Wrapped == (String, JSON) {
    public var second: JSON { self?.1 ?? JSON(nil) }
}
