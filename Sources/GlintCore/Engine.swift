import Foundation

/// A `.glint` project bundle on disk:
///
///     Name.glint/
///       project.json        the document (timeline + style); never contains media
///       events.json         input event log
///       transcript.json     optional
///       history.jsonl       append-only transactions (forward + inverse JSON patches)
///       proposals/<id>.json pending/applied/rejected edit proposals
///       media/              screen.mov, mic.m4a, system.m4a …  (never modified by editing)
///       cursors/<id>.png    recorded cursor images
///       renders/<id>/       outputs + manifest.json + qc.json
///       .lock               advisory lock serializing writers across processes (app, CLI, MCP)
public struct ProjectBundle: Sendable, Hashable {
    public static let pathExtension = "glint"
    public let url: URL
    public init(url: URL) { self.url = url.standardizedFileURL }

    public var documentURL: URL { url.appendingPathComponent("project.json") }
    public var eventsURL: URL { url.appendingPathComponent("events.json") }
    public var transcriptURL: URL { url.appendingPathComponent("transcript.json") }
    public var historyURL: URL { url.appendingPathComponent("history.jsonl") }
    public var proposalsURL: URL { url.appendingPathComponent("proposals", isDirectory: true) }
    public var mediaURL: URL { url.appendingPathComponent("media", isDirectory: true) }
    public var cursorsURL: URL { url.appendingPathComponent("cursors", isDirectory: true) }
    public var rendersURL: URL { url.appendingPathComponent("renders", isDirectory: true) }
    public var lockURL: URL { url.appendingPathComponent(".lock") }
    public func resolve(_ relative: String) -> URL {
        relative.hasPrefix("/") ? URL(fileURLWithPath: relative) : url.appendingPathComponent(relative)
    }

    public static func create(at url: URL, document: ProjectDocument, events: EventLog) throws -> ProjectBundle {
        let b = ProjectBundle(url: url)
        let fm = FileManager.default
        for d in [b.url, b.proposalsURL, b.mediaURL, b.cursorsURL, b.rendersURL] {
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        try b.writeDocument(document)
        try b.writeEvents(events)
        if !fm.fileExists(atPath: b.historyURL.path) { fm.createFile(atPath: b.historyURL.path, contents: Data()) }
        return b
    }

    /// Reads the document, filling keys missing from older files with today's defaults (forward compatible:
    /// a document written before a setting existed still loads, and the new setting takes its default).
    public func readDocument() throws -> ProjectDocument {
        let raw = try JSONCoding.decoder.decode(JSONValue.self, from: Data(contentsOf: documentURL))
        let template = ProjectDocument(id: "", name: "", createdAt: Date(timeIntervalSince1970: 0),
                                       media: MediaInfo(screen: "", width: 1, height: 1, scale: 1, duration: 0, frameRate: 30))
        var defaults = try JSONValue.from(template)
        // Only the nested settings/timeline objects take defaults; identity and media always come from the file.
        if case .object(var d) = defaults { for k in ["id", "name", "createdAt", "media", "recording", "revision"] { d.removeValue(forKey: k) }; defaults = .object(d) }
        return try raw.merged(over: defaults).decode(ProjectDocument.self)
    }
    public func writeDocument(_ d: ProjectDocument) throws {
        try JSONCoding.encoder.encode(d).write(to: documentURL, options: .atomic)
    }
    public func readEvents() -> EventLog {
        (try? JSONCoding.decoder.decode(EventLog.self, from: Data(contentsOf: eventsURL))) ?? EventLog()
    }
    public func writeEvents(_ e: EventLog) throws {
        try JSONCoding.compactEncoder.encode(e).write(to: eventsURL, options: .atomic)
    }
    public func readTranscript() -> Transcript? {
        try? JSONCoding.decoder.decode(Transcript.self, from: Data(contentsOf: transcriptURL))
    }
    public func writeTranscript(_ t: Transcript) throws {
        try JSONCoding.encoder.encode(t).write(to: transcriptURL, options: .atomic)
    }

    /// Run `body` holding an exclusive advisory lock on the bundle (blocks other processes' writers).
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw EditError.conflict("Can't open project lock at \(lockURL.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw EditError.conflict("Can't lock project") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

// MARK: - History

public struct HistoryRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case edit, undo, redo, revert }
    public var id: String
    public var kind: Kind
    public var label: String
    public var author: Author
    public var date: Date
    public var baseRevision: Int
    public var revision: Int
    public var operations: [EditOperation]?
    /// For undo/redo/revert: the transaction acted on.
    public var target: String?
    public var proposalID: String?
    public var forward: [PatchOp]
    public var inverse: [PatchOp]
}

/// Result of applying a transaction, returned to every surface.
public struct EditResult: Codable, Hashable, Sendable {
    public var transaction: String
    public var label: String
    public var revision: Int
    public var changes: [String]
    public var outputDuration: Double
    /// IDs of items created by the operations (e.g. new zoom IDs) in order.
    public var created: [String]
}

// MARK: - Proposals

public struct Proposal: Codable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, applied, rejected }
    public var id: String
    public var title: String
    public var rationale: String
    public var author: Author
    public var createdAt: Date
    public var baseRevision: Int
    public var operations: [EditOperation]
    public var status: Status
    public var appliedTransaction: String?
    public var decidedBy: Author?
    public var decidedAt: Date?
    /// Free-form metrics the proposer attached (e.g. predicted duration, zoom coverage).
    public var metrics: [String: JSONValue]?
}

// MARK: - Engine

/// The single entry point for changing a project. The macOS app, the `glint` CLI and the MCP server all call
/// this, so they share validation, history, undo and proposals, and can work on the same project concurrently.
public final class Engine: @unchecked Sendable {
    public let bundle: ProjectBundle
    public init(bundle: ProjectBundle) { self.bundle = bundle }

    public func document() throws -> ProjectDocument { try bundle.readDocument() }

    // History file I/O.
    public func history() -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: bundle.historyURL), !data.isEmpty else { return [] }
        let dec = JSONCoding.decoder
        return data.split(separator: UInt8(ascii: "\n")).compactMap { try? dec.decode(HistoryRecord.self, from: Data($0)) }
    }

    private func append(_ r: HistoryRecord) throws {
        var line = try JSONCoding.compactEncoder.encode(r)
        line.append(UInt8(ascii: "\n"))
        if let h = FileHandle(forWritingAtPath: bundle.historyURL.path) {
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: line)
        } else {
            try line.write(to: bundle.historyURL)
        }
    }

    /// (undo stack, redo stack) of transaction IDs derived from the log.
    public func stacks(_ records: [HistoryRecord]? = nil) -> (undo: [String], redo: [String]) {
        var undo: [String] = [], redo: [String] = []
        for r in records ?? history() {
            switch r.kind {
            case .edit, .revert: undo.append(r.id); redo.removeAll()
            case .undo: if let t = r.target, let i = undo.lastIndex(of: t) { undo.remove(at: i); redo.append(t) }
            case .redo: if let t = r.target, let i = redo.lastIndex(of: t) { redo.remove(at: i); undo.append(t) }
            }
        }
        return (undo, redo)
    }

    private static func patches(from a: ProjectDocument, to b: ProjectDocument) throws -> [PatchOp] {
        var a2 = a, b2 = b
        a2.revision = 0; b2.revision = 0
        return JSONPatch.diff(try JSONValue.from(a2), try JSONValue.from(b2))
    }

    private static func applyPatches(_ ops: [PatchOp], to doc: ProjectDocument, verify: Bool) throws -> ProjectDocument {
        var base = doc
        let rev = base.revision
        base.revision = 0
        var out = try JSONPatch.apply(ops, to: try JSONValue.from(base), verify: verify).decode(ProjectDocument.self)
        out.revision = rev
        return out
    }

    /// Apply operations as one undoable transaction.
    @discardableResult
    public func apply(_ ops: [EditOperation], label: String? = nil, author: Author, expectedRevision: Int? = nil,
                      proposalID: String? = nil) throws -> EditResult {
        guard !ops.isEmpty else { throw EditError.invalid("no operations") }
        return try bundle.withLock {
            let before = try bundle.readDocument()
            if let e = expectedRevision, e != before.revision { throw EditError.staleRevision(expected: e, actual: before.revision) }
            var after = try OperationApplier.apply(ops, to: before)
            let forward = try Self.patches(from: before, to: after)
            after.revision = before.revision + 1
            let created = Self.createdIDs(before: before, after: after)
            let rec = HistoryRecord(id: IDs.make("tx"), kind: .edit, label: label ?? ops.map(\.summary).joined(separator: "; "),
                                    author: author, date: Date(), baseRevision: before.revision, revision: after.revision,
                                    operations: ops, target: nil, proposalID: proposalID,
                                    forward: forward, inverse: forward.reversed().map(\.inverse))
            try bundle.writeDocument(after)
            try append(rec)
            return EditResult(transaction: rec.id, label: rec.label, revision: after.revision, changes: forward.map { "\($0.op.rawValue) \($0.path)" },
                              outputDuration: TimeMap(document: after).outputDuration, created: created)
        }
    }

    /// Dry-run: the document after applying ops, without saving.
    public func preview(_ ops: [EditOperation], on doc: ProjectDocument? = nil) throws -> ProjectDocument {
        try OperationApplier.apply(ops, to: doc ?? (try bundle.readDocument()))
    }

    private static func createdIDs(before: ProjectDocument, after: ProjectDocument) -> [String] {
        let b = Set(before.timeline.zooms.map(\.id) + before.timeline.cuts.map(\.id) + before.timeline.speeds.map(\.id) + before.timeline.markers.map(\.id) + before.timeline.captions.map(\.id))
        let a = after.timeline.zooms.map(\.id) + after.timeline.cuts.map(\.id) + after.timeline.speeds.map(\.id) + after.timeline.markers.map(\.id) + after.timeline.captions.map(\.id)
        return a.filter { !b.contains($0) }
    }

    @discardableResult
    public func undo(author: Author) throws -> EditResult {
        try bundle.withLock {
            let recs = history()
            guard let targetID = stacks(recs).undo.last, let target = recs.last(where: { $0.id == targetID && ($0.kind == .edit || $0.kind == .revert) }) else { throw EditError.nothingToUndo }
            return try writeInverse(of: target, kind: .undo, author: author, patches: target.inverse, label: "Undo \(target.label)")
        }
    }

    @discardableResult
    public func redo(author: Author) throws -> EditResult {
        try bundle.withLock {
            let recs = history()
            guard let targetID = stacks(recs).redo.last, let target = recs.last(where: { $0.id == targetID && ($0.kind == .edit || $0.kind == .revert) }) else { throw EditError.nothingToRedo }
            return try writeInverse(of: target, kind: .redo, author: author, patches: target.forward, label: "Redo \(target.label)")
        }
    }

    /// Selectively revert one earlier transaction, if the parts it touched haven't changed since.
    @discardableResult
    public func revert(_ transactionID: String, author: Author) throws -> EditResult {
        try bundle.withLock {
            guard let target = history().last(where: { $0.id == transactionID }) else { throw EditError.notFound("transaction \(transactionID)") }
            return try writeInverse(of: target, kind: .revert, author: author, patches: target.inverse, label: "Revert \(target.label)")
        }
    }

    private func writeInverse(of target: HistoryRecord, kind: HistoryRecord.Kind, author: Author, patches: [PatchOp], label: String) throws -> EditResult {
        let before = try bundle.readDocument()
        var after: ProjectDocument
        do { after = try Self.applyPatches(patches, to: before, verify: true) }
        catch let e as PatchError { throw EditError.conflict(e.description) }
        try OperationApplier.validate(after)
        let forward = try Self.patches(from: before, to: after)
        after.revision = before.revision + 1
        let rec = HistoryRecord(id: IDs.make("tx"), kind: kind, label: label, author: author, date: Date(), baseRevision: before.revision,
                                revision: after.revision, operations: nil, target: target.id, proposalID: nil,
                                forward: forward, inverse: forward.reversed().map(\.inverse))
        try bundle.writeDocument(after)
        try append(rec)
        return EditResult(transaction: rec.id, label: label, revision: after.revision, changes: forward.map { "\($0.op.rawValue) \($0.path)" },
                          outputDuration: TimeMap(document: after).outputDuration, created: [])
    }

    // MARK: Proposals

    public func propose(title: String, rationale: String, operations: [EditOperation], author: Author,
                        metrics: [String: JSONValue]? = nil) throws -> Proposal {
        let doc = try bundle.readDocument()
        _ = try OperationApplier.apply(operations, to: doc)   // must be valid now
        let p = Proposal(id: IDs.make("prop"), title: title, rationale: rationale, author: author, createdAt: Date(),
                         baseRevision: doc.revision, operations: operations, status: .pending, appliedTransaction: nil,
                         decidedBy: nil, decidedAt: nil, metrics: metrics)
        try save(p)
        return p
    }

    public func save(_ p: Proposal) throws {
        try FileManager.default.createDirectory(at: bundle.proposalsURL, withIntermediateDirectories: true)
        try JSONCoding.encoder.encode(p).write(to: bundle.proposalsURL.appendingPathComponent("\(p.id).json"), options: .atomic)
    }

    public func proposals() -> [Proposal] {
        let files = (try? FileManager.default.contentsOfDirectory(at: bundle.proposalsURL, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONCoding.decoder.decode(Proposal.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func proposal(_ id: String) throws -> Proposal {
        guard let p = proposals().first(where: { $0.id == id }) else { throw EditError.notFound("proposal \(id)") }
        return p
    }

    @discardableResult
    public func applyProposal(_ id: String, author: Author) throws -> EditResult {
        var p = try proposal(id)
        guard p.status == .pending else { throw EditError.invalid("proposal \(id) is already \(p.status.rawValue)") }
        let r = try apply(p.operations, label: p.title, author: author, proposalID: p.id)
        p.status = .applied; p.appliedTransaction = r.transaction; p.decidedBy = author; p.decidedAt = Date()
        try save(p)
        return r
    }

    public func rejectProposal(_ id: String, author: Author) throws -> Proposal {
        var p = try proposal(id)
        guard p.status == .pending else { throw EditError.invalid("proposal \(id) is already \(p.status.rawValue)") }
        p.status = .rejected; p.decidedBy = author; p.decidedAt = Date()
        try save(p)
        return p
    }
}
