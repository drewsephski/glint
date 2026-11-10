import Foundation

/// How risky an action is. Agents may freely read, propose and make reversible edits; capture, destructive
/// and outward-facing actions go through approval unless the user's policy pre-authorizes them.
public enum Risk: String, Codable, Sendable, Comparable, CaseIterable {
    /// Inspection only.
    case read
    /// Changes the project document through the engine (always undoable) or adds new files inside the project.
    case reversible
    /// Captures the screen / microphone.
    case capture
    /// Deletes or overwrites user data that can't be restored by undo (e.g. deleting a project, overwriting a file).
    case destructive
    /// Sends content outside this Mac (uploads, sharing, publishing).
    case external

    var order: Int { Risk.allCases.firstIndex(of: self)! }
    public static func < (a: Risk, b: Risk) -> Bool { a.order < b.order }
}

public struct ApprovalPolicy: Codable, Hashable, Sendable {
    public enum Rule: String, Codable, Sendable { case allow, ask, deny }
    /// Screen recording started by an agent.
    public var capture: Rule = .ask
    /// Always `ask` unless the user edits the policy file by hand; agents can't change the policy.
    public var destructive: Rule = .ask
    public var external: Rule = .ask
    /// When capture is `allow`, optionally restrict to these app names / bundle IDs (empty = any).
    public var captureAllowedApps: [String] = []
    /// Approvals expire after this many seconds.
    public var approvalTTL: Double = 900
    public init() {}

    /// Policy files are written by hand and usually partial (`{"capture":"allow"}`); missing keys keep their defaults
    /// instead of failing the whole file back to "ask".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        capture = try c.decodeIfPresent(Rule.self, forKey: .capture) ?? .ask
        destructive = try c.decodeIfPresent(Rule.self, forKey: .destructive) ?? .ask
        external = try c.decodeIfPresent(Rule.self, forKey: .external) ?? .ask
        captureAllowedApps = try c.decodeIfPresent([String].self, forKey: .captureAllowedApps) ?? []
        approvalTTL = try c.decodeIfPresent(Double.self, forKey: .approvalTTL) ?? 900
    }

    public func rule(for risk: Risk, author: Author) -> Rule {
        // People acting through the app or an interactive terminal are trusted for their own actions.
        if author.kind == .user { return risk == .destructive ? .ask : .allow }
        switch risk {
        case .read, .reversible: return .allow
        case .capture: return capture
        case .destructive: return destructive
        case .external: return external
        }
    }
}

public struct ApprovalRequest: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, approved, denied, consumed, expired }
    public var id: String
    public var action: String
    public var summary: String
    public var risk: Risk
    /// Fingerprint of the exact parameters; an approval can only be used for the identical action.
    public var fingerprint: String
    public var parameters: JSONValue
    public var requestedBy: Author
    public var createdAt: Date
    public var expiresAt: Date
    public var status: Status
    public var decidedBy: String?
    public var decidedAt: Date?
}

public enum ApprovalError: Error, CustomStringConvertible {
    case required(ApprovalRequest)
    case denied(String)
    case invalid(String)
    public var description: String {
        switch self {
        case .required(let r):
            return "Approval required (\(r.risk.rawValue)): \(r.summary). Ask the user to approve request \(r.id) in the Glint app, or run `glint approve \(r.id)` in an interactive terminal, then call again with approval_id \"\(r.id)\"."
        case .denied(let s): return "Not allowed: \(s)"
        case .invalid(let s): return "Approval problem: \(s)"
        }
    }
}

/// File-backed approval queue shared by the app, CLI and MCP server.
public final class ApprovalStore: @unchecked Sendable {
    public let directory: URL
    public init(directory: URL = GlintPaths.support.appendingPathComponent("approvals", isDirectory: true)) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public var policyURL: URL { directory.deletingLastPathComponent().appendingPathComponent("policy.json") }
    public func policy() -> ApprovalPolicy {
        (try? JSONCoding.decoder.decode(ApprovalPolicy.self, from: Data(contentsOf: policyURL))) ?? ApprovalPolicy()
    }

    public static func fingerprint(action: String, parameters: JSONValue) -> String {
        var canonical = parameters
        if case .object(var o) = canonical { o.removeValue(forKey: "approval_id"); canonical = .object(o) }
        var h: UInt64 = 0xcbf29ce484222325
        for b in (action + "|" + canonical.description).utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }

    private func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    public func save(_ r: ApprovalRequest) throws { try JSONCoding.encoder.encode(r).write(to: url(r.id), options: .atomic) }
    public func get(_ id: String) -> ApprovalRequest? { try? JSONCoding.decoder.decode(ApprovalRequest.self, from: Data(contentsOf: url(id))) }

    public func all() -> [ApprovalRequest] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONCoding.decoder.decode(ApprovalRequest.self, from: Data(contentsOf: $0)) }
            .map { r in var r = r; if r.status == .pending && r.expiresAt < Date() { r.status = .expired }; return r }
            .sorted { $0.createdAt > $1.createdAt }
    }
    public func pending() -> [ApprovalRequest] { all().filter { $0.status == .pending } }

    /// Gate an action. Returns normally when allowed (consuming a matching approval if one was supplied);
    /// throws `.required` with a new pending request otherwise.
    public func authorize(action: String, risk: Risk, summary: String, parameters: JSONValue, author: Author, approvalID: String?) throws {
        let policy = policy()
        switch policy.rule(for: risk, author: author) {
        case .allow: return
        case .deny: throw ApprovalError.denied("\(action) is disabled by policy (\(policyURL.path))")
        case .ask: break
        }
        let fp = Self.fingerprint(action: action, parameters: parameters)
        if let id = approvalID {
            guard var r = get(id) else { throw ApprovalError.invalid("no approval request \(id)") }
            guard r.fingerprint == fp else { throw ApprovalError.invalid("approval \(id) was granted for different parameters; request a new one") }
            if r.expiresAt < Date() && r.status != .consumed { r.status = .expired; try save(r) }
            switch r.status {
            case .approved:
                r.status = .consumed; try save(r)
                return
            case .pending: throw ApprovalError.required(r)
            case .denied: throw ApprovalError.denied("the user denied \(id)")
            case .consumed: throw ApprovalError.invalid("approval \(id) was already used")
            case .expired: throw ApprovalError.invalid("approval \(id) expired")
            }
        }
        // Reuse an identical pending request instead of piling up duplicates.
        if let existing = pending().first(where: { $0.fingerprint == fp }) { throw ApprovalError.required(existing) }
        let r = ApprovalRequest(id: IDs.make("apr"), action: action, summary: summary, risk: risk, fingerprint: fp, parameters: parameters,
                                requestedBy: author, createdAt: Date(), expiresAt: Date().addingTimeInterval(policy.approvalTTL),
                                status: .pending, decidedBy: nil, decidedAt: nil)
        try save(r)
        throw ApprovalError.required(r)
    }

    public func decide(_ id: String, approve: Bool, by: String) throws -> ApprovalRequest {
        guard var r = get(id) else { throw ApprovalError.invalid("no approval request \(id)") }
        guard r.status == .pending else { throw ApprovalError.invalid("request \(id) is \(r.status.rawValue)") }
        guard r.expiresAt > Date() else { r.status = .expired; try save(r); throw ApprovalError.invalid("request \(id) expired") }
        r.status = approve ? .approved : .denied
        r.decidedBy = by; r.decidedAt = Date()
        try save(r)
        return r
    }
}

public enum GlintPaths {
    public static var support: URL {
        if let o = ProcessInfo.processInfo.environment["GLINT_HOME"] { return URL(fileURLWithPath: o, isDirectory: true) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glint", isDirectory: true)
    }
    /// Default folder for new recordings.
    public static var projects: URL {
        if let o = ProcessInfo.processInfo.environment["GLINT_PROJECTS"] { return URL(fileURLWithPath: o, isDirectory: true) }
        return FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Glint", isDirectory: true)
    }
}
