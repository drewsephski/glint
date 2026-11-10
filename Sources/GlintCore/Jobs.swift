import Foundation

// MARK: - Durable jobs
//
// Long work (renders, production passes) runs as a job persisted in the bundle (`jobs/<id>.json`). Each stage
// records its status, artifacts and their hashes as it completes, so a job interrupted by a crash or a cancel can be
// retried from the last completed stage without redoing (or re-paying for) finished work. Jobs are idempotent by
// key: starting the same key with the same parameters returns the existing job.

public struct JobStage: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case pending, running, done, failed, skipped, cancelled }
    public var name: String
    public var status: Status
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Bundle-relative paths of files this stage produced.
    public var artifacts: [String]
    /// SHA-256 of each artifact, so a retry can trust (and skip) a completed stage.
    public var hashes: [String: String]
    public var detail: String?
    public var error: String?
    public var attempts: Int
    public init(name: String) {
        self.name = name; status = .pending; artifacts = []; hashes = [:]; attempts = 0
    }
}

public struct Job: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case render, production }
    public enum Status: String, Codable, Sendable {
        case queued, running, succeeded, failed, cancelled
        /// The process running it went away (crash, quit). Retry resumes from the last completed stage.
        case interrupted
        /// Finished, but something needs a person: failed checks it couldn't repair, unverified evidence.
        case needsReview = "needs_review"
        public var isTerminal: Bool { ![.queued, .running].contains(self) }
    }
    public var id: String
    public var kind: Kind
    public var status: Status
    public var idempotencyKey: String?
    public var params: JSONValue
    /// Document revision the job works from. A retry refuses to resume finished stages if the project changed.
    public var revision: Int
    public var stages: [JobStage]
    /// 0…1 across all stages.
    public var progress: Double
    public var message: String?
    public var author: Author
    public var createdAt: Date
    public var updatedAt: Date
    /// Process running the job (for interruption detection).
    public var pid: Int32?
    public var attempts: Int
    public var result: JSONValue?
    public var error: String?
    /// Items a person should look at before publishing.
    public var review: [String]

    public init(id: String = IDs.make("job"), kind: Kind, idempotencyKey: String?, params: JSONValue, revision: Int, stages: [String], author: Author) {
        self.id = id; self.kind = kind; status = .queued; self.idempotencyKey = idempotencyKey; self.params = params; self.revision = revision
        self.stages = stages.map(JobStage.init(name:)); progress = 0; self.author = author; createdAt = Date(); updatedAt = Date()
        attempts = 0; review = []
    }

    public func stage(_ name: String) -> JobStage? { stages.first { $0.name == name } }
}

public enum JobError: Error, CustomStringConvertible, Equatable {
    case notFound(String)
    case conflict(String)
    case notRetryable(String)
    public var description: String {
        switch self {
        case .notFound(let s): return "No job \(s)"
        case .conflict(let s), .notRetryable(let s): return s
        }
    }
}

/// Jobs of one project, on disk. Safe across processes (writes go through the bundle lock).
public struct JobStore: Sendable {
    public let bundle: ProjectBundle
    public init(bundle: ProjectBundle) { self.bundle = bundle }
    public var directory: URL { bundle.url.appendingPathComponent("jobs", isDirectory: true) }
    func url(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }
    func cancelURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).cancel") }

    public func save(_ j: Job) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var j = j
        j.updatedAt = Date()
        try JSONCoding.encoder.encode(j).write(to: url(j.id), options: .atomic)
    }

    /// A job, with a dead runner detected: `running`/`queued` whose process is gone becomes `interrupted`.
    public func get(_ id: String) throws -> Job {
        guard var j = try? JSONCoding.decoder.decode(Job.self, from: Data(contentsOf: url(id))) else { throw JobError.notFound(id) }
        if !j.status.isTerminal, let pid = j.pid, !Self.alive(pid) {
            j.status = .interrupted
            j.message = "The process running this job stopped. Retry resumes after the last completed stage."
            for i in j.stages.indices where j.stages[i].status == .running { j.stages[i].status = .pending }
            try? save(j)
        }
        return j
    }

    public func list() -> [Job] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { try? get($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// Create a job, or return the existing one for the same idempotency key. Reusing a key with different
    /// parameters is a conflict rather than a silent replacement.
    public func create(_ job: Job) throws -> (job: Job, existing: Bool) {
        try bundle.withLock {
            if let key = job.idempotencyKey, let old = list().first(where: { $0.idempotencyKey == key && $0.kind == job.kind }) {
                guard old.params == job.params else { throw JobError.conflict("idempotency key \(key) was already used for a job with different parameters (\(old.id))") }
                return (old, true)
            }
            try save(job)
            return (job, false)
        }
    }

    public func update(_ id: String, _ change: (inout Job) -> Void) throws -> Job {
        try bundle.withLock {
            var j = try get(id)
            change(&j)
            try save(j)
            return j
        }
    }

    public func requestCancel(_ id: String) throws -> Job {
        let j = try get(id)
        guard !j.status.isTerminal || j.status == .interrupted else { return j }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: cancelURL(id).path, contents: Data())
        // A queued or interrupted job has nobody to notice the flag: cancel it directly.
        if j.pid == nil || !Self.alive(j.pid!) {
            return try update(id) { $0.status = .cancelled; $0.message = "Cancelled" }
        }
        return j
    }
    public func isCancelRequested(_ id: String) -> Bool { FileManager.default.fileExists(atPath: cancelURL(id).path) }
    public func clearCancel(_ id: String) { try? FileManager.default.removeItem(at: cancelURL(id)) }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 || errno == EPERM }
}

// MARK: - Bounded quality repair

/// Deterministic fixes for edit-quality checks that have a safe, local remedy. Anything else becomes a review item:
/// the loop never cuts content or changes the story on its own.
public enum QualityRepair {
    public struct Plan: Sendable {
        public var operations: [EditOperation]
        public var fixed: [String]
        public var unresolved: [String]
    }

    public static func plan(report: QualityReport, document doc: ProjectDocument, transcript: Transcript?) -> Plan {
        var ops: [EditOperation] = []
        var fixed: [String] = []
        var unresolved: [String] = []
        let map = TimeMap(document: doc)
        for c in report.checks where c.verdict == .fail || c.verdict == .warn {
            switch c.id {
            case "zoom_min_duration":
                // Lengthen zooms shorter than 1.2 s on the output timeline, symmetrically, within the program.
                var n = 0
                for z in doc.timeline.zooms {
                    guard let span = map.outputSpan(forSource: z.range), span.duration < 1.2 else { continue }
                    let s = map.source(forOutput: max(0, span.start - (1.3 - span.duration) / 2))
                    let e = map.source(forOutput: min(map.outputDuration, span.end + (1.3 - span.duration) / 2))
                    if e - s > z.end - z.start { ops.append(EditOperation(.updateZoom, id: z.id, start: s, end: e)); n += 1 }
                }
                if n > 0 { fixed.append("lengthened \(n) short zoom\(n == 1 ? "" : "s")") } else { unresolved.append(c.message) }
            case "zoom_pumping":
                // Join zooms separated by a tiny gap so the camera pans instead of zooming out and back in.
                let zs = doc.timeline.zooms.sorted { $0.start < $1.start }
                var n = 0
                for (a, b) in zip(zs, zs.dropFirst()) {
                    guard let ea = map.output(forSource: a.end), let sb = map.output(forSource: b.start), sb - ea > 0, sb - ea < 0.7 else { continue }
                    ops.append(EditOperation(.updateZoom, id: a.id, end: b.start)); n += 1
                }
                if n > 0 { fixed.append("joined \(n) zoom pair\(n == 1 ? "" : "s") that pumped") } else { unresolved.append(c.message) }
            case "camera_speed" where c.verdict == .fail:
                let st = max(60, doc.style.zoom.stiffness * 0.7)
                ops.append(.style("zoom.stiffness", .number(st)))
                fixed.append(String(format: "softened camera moves (stiffness %.0f → %.0f)", doc.style.zoom.stiffness, st))
            case "cursor_in_view" where c.verdict == .fail:
                let dz = max(0.15, doc.style.zoom.followDeadZone - 0.15)
                ops.append(.style("zoom.followDeadZone", .number(dz)))
                fixed.append(String(format: "camera follows the cursor sooner (dead zone %.2f → %.2f)", doc.style.zoom.followDeadZone, dz))
            case "caption_length", "caption_reading_speed":
                guard let t = transcript, !t.words.isEmpty, !fixed.contains(where: { $0.hasPrefix("re-split captions") }) else {
                    if transcript == nil { unresolved.append(c.message) }
                    continue
                }
                let maxChars = max(24, min(doc.style.captions.maxCharsPerLine, 36))
                ops.append(EditOperation(.setCaptions, items: CaptionBuilder.segments(from: t.words, maxChars: maxChars)))
                fixed.append("re-split captions at \(maxChars) characters")
            default:
                if c.verdict == .fail { unresolved.append("\(c.message)\(c.fix.map { " — suggested: \($0)" } ?? "")") }
            }
        }
        return Plan(operations: ops, fixed: fixed, unresolved: unresolved)
    }
}

/// A hash that is the same in every process (Swift's `hashValue` is seeded per process), for fingerprints that
/// must match across the app, the CLI and the MCP server.
public enum StableHash {
    public static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }
    public static func hex(_ s: String) -> String { String(format: "%016llx", fnv1a(s)) }
}
