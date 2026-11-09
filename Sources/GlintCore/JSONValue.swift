import Foundation

/// A dynamically typed JSON value. The engine uses it to diff document states into JSON patches, so every
/// edit — whichever surface made it (UI, CLI, MCP) — gets an exact, automatically derived inverse.
public enum JSONValue: Codable, Hashable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var description: String {
        (try? String(data: JSONCoding.compactEncoder.encode(self), encoding: .utf8)) ?? "<json>"
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    public var intValue: Int? { doubleValue.map { Int($0) } }
    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .string(let s): return ["true", "yes", "1"].contains(s.lowercased()) ? true : (["false", "no", "0"].contains(s.lowercased()) ? false : nil)
        default: return nil
        }
    }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    /// Encode any Encodable into a JSONValue tree.
    public static func from<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONCoding.compactEncoder.encode(value)
        return try JSONCoding.decoder.decode(JSONValue.self, from: data)
    }

    /// Decode this JSON tree into a typed value.
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        let data = try JSONCoding.compactEncoder.encode(self)
        return try JSONCoding.decoder.decode(T.self, from: data)
    }
}

public enum JSONCoding {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static var compactEncoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    public static func string<T: Encodable>(_ value: T, pretty: Bool = true) -> String {
        let enc = pretty ? encoder : compactEncoder
        guard let data = try? enc.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - JSON Patch (RFC 6902 subset) with recorded old values

public struct PatchOp: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case add, remove, replace }
    public var op: Kind
    /// JSON Pointer (RFC 6901), e.g. `/timeline/zooms/2/scale`.
    public var path: String
    /// New value (add/replace).
    public var value: JSONValue?
    /// Value before the change (remove/replace). Used to verify a revert still applies cleanly.
    public var old: JSONValue?

    public init(op: Kind, path: String, value: JSONValue? = nil, old: JSONValue? = nil) {
        self.op = op; self.path = path; self.value = value; self.old = old
    }

    public var inverse: PatchOp {
        switch op {
        case .add: return PatchOp(op: .remove, path: path, value: nil, old: value)
        case .remove: return PatchOp(op: .add, path: path, value: old, old: nil)
        case .replace: return PatchOp(op: .replace, path: path, value: old, old: value)
        }
    }
}

public enum PatchError: Error, CustomStringConvertible {
    case badPath(String)
    case conflict(String)
    public var description: String {
        switch self {
        case .badPath(let p): return "Invalid patch path \(p)"
        case .conflict(let p): return "The document changed at \(p) since this edit; it can't be reverted cleanly"
        }
    }
}

public enum JSONPatch {
    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    static func unescape(_ s: String) -> String { s.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~") }

    static func tokens(_ path: String) throws -> [String] {
        if path.isEmpty { return [] }
        guard path.hasPrefix("/") else { throw PatchError.badPath(path) }
        return path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { unescape(String($0)) }
    }

    /// Minimal structural diff. Objects recurse by key; arrays of equal length recurse by index; arrays whose
    /// elements carry an `id` are diffed by identity when lengths differ; otherwise the array is replaced.
    public static func diff(_ a: JSONValue, _ b: JSONValue, path: String = "") -> [PatchOp] {
        if a == b { return [] }
        switch (a, b) {
        case (.object(let oa), .object(let ob)):
            var ops: [PatchOp] = []
            for key in oa.keys.sorted() where ob[key] == nil {
                ops.append(PatchOp(op: .remove, path: path + "/" + escape(key), old: oa[key]))
            }
            for key in ob.keys.sorted() {
                let p = path + "/" + escape(key)
                if let va = oa[key] { ops += diff(va, ob[key]!, path: p) } else { ops.append(PatchOp(op: .add, path: p, value: ob[key])) }
            }
            return ops
        case (.array(let aa), .array(let ab)):
            if let ops = identityDiff(aa, ab, path: path) { return ops }
            if aa.count == ab.count {
                var ops: [PatchOp] = []
                for i in aa.indices { ops += diff(aa[i], ab[i], path: path + "/\(i)") }
                return ops
            }
            return [PatchOp(op: .replace, path: path, value: b, old: a)]
        default:
            return [PatchOp(op: .replace, path: path, value: b, old: a)]
        }
    }

    /// Arrays of objects with unique string `id`s, where surviving elements keep their relative order, diff as
    /// element removes + inserts + per-element changes. Returns nil when that doesn't apply.
    static func identityDiff(_ a: [JSONValue], _ b: [JSONValue], path: String) -> [PatchOp]? {
        func ids(_ arr: [JSONValue]) -> [String]? {
            let r = arr.compactMap { $0["id"]?.stringValue }
            return r.count == arr.count && Set(r).count == r.count ? r : nil
        }
        guard !(a.isEmpty && b.isEmpty), let ia = ids(a), let ib = ids(b) else { return nil }
        let setB = Set(ib), setA = Set(ia)
        let commonA = ia.filter { setB.contains($0) }
        let commonB = ib.filter { setA.contains($0) }
        guard commonA == commonB else { return nil }
        var ops: [PatchOp] = []
        for (i, id) in ia.enumerated().reversed() where !setB.contains(id) {
            ops.append(PatchOp(op: .remove, path: path + "/\(i)", old: a[i]))
        }
        for (i, id) in ib.enumerated() where !setA.contains(id) {
            ops.append(PatchOp(op: .add, path: path + "/\(i)", value: b[i]))
        }
        let byID = Dictionary(uniqueKeysWithValues: zip(ia, a))
        for (i, id) in ib.enumerated() where setA.contains(id) {
            ops += diff(byID[id]!, b[i], path: path + "/\(i)")
        }
        return ops
    }

    /// Apply ops in order. With `verify`, replace/remove require the current value to equal `old`.
    public static func apply(_ ops: [PatchOp], to doc: JSONValue, verify: Bool = false) throws -> JSONValue {
        var d = doc
        for op in ops { d = try apply(op, to: d, verify: verify) }
        return d
    }

    static func apply(_ op: PatchOp, to doc: JSONValue, verify: Bool) throws -> JSONValue {
        let t = try tokens(op.path)
        return try update(doc, tokens: t[...], op: op, verify: verify)
    }

    private static func update(_ node: JSONValue, tokens: ArraySlice<String>, op: PatchOp, verify: Bool) throws -> JSONValue {
        guard let head = tokens.first else {
            // Root replacement.
            switch op.op {
            case .replace, .add:
                if verify, op.op == .replace, let old = op.old, old != node { throw PatchError.conflict(op.path) }
                return op.value ?? .null
            case .remove: return .null
            }
        }
        let rest = tokens.dropFirst()
        switch node {
        case .object(var o):
            if rest.isEmpty {
                switch op.op {
                case .add:
                    o[head] = op.value ?? .null
                case .replace:
                    if verify, let old = op.old, o[head] != old { throw PatchError.conflict(op.path) }
                    o[head] = op.value ?? .null
                case .remove:
                    if verify, let old = op.old, o[head] != old { throw PatchError.conflict(op.path) }
                    o.removeValue(forKey: head)
                }
                return .object(o)
            }
            guard let child = o[head] else { throw PatchError.badPath(op.path) }
            o[head] = try update(child, tokens: rest, op: op, verify: verify)
            return .object(o)
        case .array(var a):
            if rest.isEmpty {
                switch op.op {
                case .add:
                    if head == "-" { a.append(op.value ?? .null); return .array(a) }
                    guard let i = Int(head), i >= 0, i <= a.count else { throw PatchError.badPath(op.path) }
                    a.insert(op.value ?? .null, at: i)
                case .replace:
                    guard let i = Int(head), a.indices.contains(i) else { throw PatchError.badPath(op.path) }
                    if verify, let old = op.old, a[i] != old { throw PatchError.conflict(op.path) }
                    a[i] = op.value ?? .null
                case .remove:
                    guard let i = Int(head), a.indices.contains(i) else { throw PatchError.badPath(op.path) }
                    if verify, let old = op.old, a[i] != old { throw PatchError.conflict(op.path) }
                    a.remove(at: i)
                }
                return .array(a)
            }
            guard let i = Int(head), a.indices.contains(i) else { throw PatchError.badPath(op.path) }
            a[i] = try update(a[i], tokens: rest, op: op, verify: verify)
            return .array(a)
        default:
            throw PatchError.badPath(op.path)
        }
    }

    /// Read the value at a JSON pointer.
    public static func get(_ path: String, in doc: JSONValue) -> JSONValue? {
        guard let t = try? tokens(path) else { return nil }
        var node = doc
        for tok in t {
            switch node {
            case .object(let o): guard let n = o[tok] else { return nil }; node = n
            case .array(let a): guard let i = Int(tok), a.indices.contains(i) else { return nil }; node = a[i]
            default: return nil
            }
        }
        return node
    }
}
