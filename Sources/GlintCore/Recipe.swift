import Foundation

// MARK: - Demo recipes
//
// A recipe is the reusable intent behind a demo: who it's for, the ordered scenes with STABLE IDs, what each scene
// must show (expected outcomes) and how it should be narrated. It is stored in the project (`recipe.json`) and can be
// exported/imported as a standalone file, so the same demo can be re-recorded after the product changes.
//
// Glint does not drive the product. An external coding agent (or a person) performs the steps while Glint records,
// marks each scene with `scene:<id>` markers, and reports what it observed as evidence. Glint keeps the evidence,
// checks what it can itself (on-screen text in the recorded frames) and never treats a reported click as proof.

public struct RecipeExpectation: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Text that must be visible on screen at the end of the scene. Glint can check this itself (OCR on the
        /// recorded frame); a match marks the expectation verified, a miss leaves it for review.
        case visibleText = "visible_text"
        /// Application state an external check must confirm (DOM/accessibility assertion, API response, …).
        case state
        /// Needs a human to look.
        case manual
    }
    public var id: String
    public var description: String
    public var kind: Kind
    /// For visible_text: the text to find.
    public var text: String?
    /// Required outcomes gate the release; optional ones are reported only.
    public var required: Bool
    public init(id: String, description: String, kind: Kind = .state, text: String? = nil, required: Bool = true) {
        self.id = id; self.description = description; self.kind = kind; self.text = text; self.required = required
    }
    enum CodingKeys: String, CodingKey { case id, description, kind, text, required }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? id
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .state
        text = try c.decodeIfPresent(String.self, forKey: .text)
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }
}

public struct RecipeScene: Codable, Hashable, Sendable, Identifiable {
    /// Stable across recordings and recipe versions. Never derived from timestamps.
    public var id: String
    public var title: String
    public var intent: String?
    /// What must be true before the scene starts (e.g. "signed in as the demo admin").
    public var preconditions: [String]
    /// The steps the driver performs, in plain language or with semantic targets ("click button 'Invite'").
    public var steps: [String]
    public var expectations: [RecipeExpectation]
    /// What the narration should convey (the script writer's brief for this scene).
    public var narration: String?
    /// Production preferences, not content: left out of the recipe's version and evidence fingerprint (see
    /// `DemoRecipe.content`), and encoded only when set so older recipes keep their fingerprints.
    /// A locked scene is finished: automatic passes (autopilot, `write_narration`) keep its narration line as is and
    /// agents can't overwrite it with `set_narration`.
    public var locked: Bool?
    /// How long this scene should run in the finished video (seconds), if the person said.
    public var targetDuration: Double?
    public var isLocked: Bool { locked == true }
    public init(id: String, title: String, intent: String? = nil, preconditions: [String] = [], steps: [String] = [],
                expectations: [RecipeExpectation] = [], narration: String? = nil, locked: Bool? = nil, targetDuration: Double? = nil) {
        self.id = id; self.title = title; self.intent = intent; self.preconditions = preconditions; self.steps = steps
        self.expectations = expectations; self.narration = narration; self.locked = locked; self.targetDuration = targetDuration
    }
    enum CodingKeys: String, CodingKey { case id, title, intent, preconditions, steps, expectations, narration, locked, targetDuration }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        preconditions = try c.decodeIfPresent([String].self, forKey: .preconditions) ?? []
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        expectations = try c.decodeIfPresent([RecipeExpectation].self, forKey: .expectations) ?? []
        narration = try c.decodeIfPresent(String.self, forKey: .narration)
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked)
        targetDuration = try c.decodeIfPresent(Double.self, forKey: .targetDuration)
    }
}

public struct DemoRecipe: Codable, Hashable, Sendable {
    public static let formatVersion = 1
    public var formatVersion: Int
    public var id: String
    public var title: String
    /// Increments whenever scenes, steps or expectations change.
    public var version: Int
    public var audience: String?
    public var intent: String?
    /// The product being demonstrated (name, bundle ID or URL, build). Informational.
    public var app: [String: String]
    /// References to fixture data the driver sets up (names/paths, never credentials).
    public var fixtures: [String]
    public var scenes: [RecipeScene]
    /// Render presets for deliverables.
    public var outputs: [String]
    public var createdAt: Date
    public var updatedAt: Date
    /// Production preferences from the guided "polish" flow (encoded only when set; not part of `content`):
    /// the approximate finished length, and moments the video must show, in the person's words.
    public var targetDuration: Double?
    public var mustShow: [String]?

    public init(id: String = IDs.make("rcp"), title: String, version: Int = 1, audience: String? = nil, intent: String? = nil, app: [String: String] = [:],
                fixtures: [String] = [], scenes: [RecipeScene], outputs: [String] = ["current"], createdAt: Date = Date(), updatedAt: Date = Date()) {
        formatVersion = Self.formatVersion
        self.id = id; self.title = title; self.version = version; self.audience = audience; self.intent = intent; self.app = app
        self.fixtures = fixtures; self.scenes = scenes; self.outputs = outputs; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    enum CodingKeys: String, CodingKey { case formatVersion, id, title, version, audience, intent, app, fixtures, scenes, outputs, createdAt, updatedAt, targetDuration, mustShow }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.formatVersion
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? IDs.make("rcp")
        title = try c.decode(String.self, forKey: .title)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        audience = try c.decodeIfPresent(String.self, forKey: .audience)
        intent = try c.decodeIfPresent(String.self, forKey: .intent)
        app = try c.decodeIfPresent([String: String].self, forKey: .app) ?? [:]
        fixtures = try c.decodeIfPresent([String].self, forKey: .fixtures) ?? []
        scenes = try c.decode([RecipeScene].self, forKey: .scenes)
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? ["landscape"]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        targetDuration = try c.decodeIfPresent(Double.self, forKey: .targetDuration)
        mustShow = try c.decodeIfPresent([String].self, forKey: .mustShow)
    }

    public func scene(_ id: String) -> RecipeScene? { scenes.first { $0.id == id } }

    /// Scenes a person marked finished; automatic narration passes keep their lines.
    public var lockedScenes: Set<String> { Set(scenes.filter(\.isLocked).map(\.id)) }

    /// The recipe without production preferences (locks, target lengths, must-show notes). Versions and evidence
    /// fingerprints are computed on this, so locking a scene or changing the length goal never invalidates evidence.
    public var content: DemoRecipe {
        var r = self
        r.targetDuration = nil; r.mustShow = nil
        for i in r.scenes.indices { r.scenes[i].locked = nil; r.scenes[i].targetDuration = nil }
        return r
    }

    /// Structural checks: stable, unique, well-formed IDs; at least one scene; no credentials in fixtures.
    public func validate() throws {
        guard formatVersion <= Self.formatVersion else { throw EditError.invalid("recipe format \(formatVersion) is newer than this Glint (\(Self.formatVersion))") }
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { throw EditError.invalid("recipe needs a title") }
        guard !scenes.isEmpty else { throw EditError.invalid("recipe needs at least one scene") }
        let idPattern = #"^[A-Za-z0-9][A-Za-z0-9_\-\.]{0,63}$"#
        var seen = Set<String>()
        for s in scenes {
            guard s.id.range(of: idPattern, options: .regularExpression) != nil else { throw EditError.invalid("scene id “\(s.id)” must be 1–64 letters, digits, _ - .") }
            guard seen.insert(s.id).inserted else { throw EditError.invalid("duplicate scene id \(s.id)") }
            var eids = Set<String>()
            for e in s.expectations {
                guard e.id.range(of: idPattern, options: .regularExpression) != nil else { throw EditError.invalid("expectation id “\(e.id)” in \(s.id) is not a valid id") }
                guard eids.insert(e.id).inserted else { throw EditError.invalid("duplicate expectation \(e.id) in scene \(s.id)") }
                if e.kind == .visibleText, (e.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    throw EditError.invalid("visible_text expectation \(s.id)/\(e.id) needs text")
                }
            }
        }
        for f in fixtures where f.range(of: #"(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]"#, options: .regularExpression) != nil {
            throw EditError.invalid("fixtures reference data by name; don't put credentials in a recipe (“\(f.prefix(30))…”)")
        }
    }

    /// The saved version after an update: same ID and creation date; version bumps when content changed.
    public func revised(from previous: DemoRecipe?) -> DemoRecipe {
        guard let p = previous else { return self }
        var r = self
        r.id = p.id
        r.createdAt = p.createdAt
        var a = content, b = p.content
        a.version = 0; b.version = 0; a.updatedAt = .distantPast; b.updatedAt = .distantPast; a.createdAt = .distantPast; b.createdAt = .distantPast; a.id = ""; b.id = ""
        r.version = a == b ? p.version : p.version + 1
        r.updatedAt = a == b ? p.updatedAt : Date()
        return r
    }
}

// MARK: - Evidence

public enum EvidenceStatus: String, Codable, Sendable, CaseIterable {
    case verified, failed
    case needsReview = "needs_review"
}

/// One observation about an expectation.
public struct EvidenceRecord: Codable, Hashable, Sendable, Identifiable {
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// A deterministic check by the driver: DOM/accessibility query, HTTP response, database row…
        case assertion
        /// Glint's on-device text recognition on a recorded frame.
        case ocr
        /// A person looked at it.
        case human
        /// Something the driver did (a click, a keystroke). Never proof of an outcome.
        case action
        /// A model's judgement of a frame. Not equivalent to a deterministic check.
        case vision
    }
    public var id: String
    public var scene: String
    public var expectation: String
    public var status: EvidenceStatus
    public var source: Source
    /// What was checked and how ("GET /invites → 1 pending", "OCR found “Invitation sent”").
    public var detail: String
    /// The observed value (text, state) — required for a verified assertion.
    public var observed: String?
    /// Program time of the frame that shows it, and frames saved for review (bundle-relative).
    public var time: Double?
    public var frames: [String]
    /// Which recording it was observed in. Evidence from a take that's no longer in the edit is stale.
    public var take: String?
    /// Missing fingerprints on legacy evidence leave the observation for review until it is rechecked.
    public var recipeFingerprint: String?
    public var sceneFingerprint: String?
    public var author: Author
    public var recordedAt: Date
    /// Notes Glint added while normalizing (e.g. why a claimed "verified" was downgraded).
    public var notes: [String]

    public init(id: String = IDs.make("ev"), scene: String, expectation: String, status: EvidenceStatus, source: Source, detail: String,
                observed: String? = nil, time: Double? = nil, frames: [String] = [], take: String? = nil, author: Author, recordedAt: Date = Date(), notes: [String] = [], recipeFingerprint: String? = nil, sceneFingerprint: String? = nil) {
        self.id = id; self.scene = scene; self.expectation = expectation; self.status = status; self.source = source; self.detail = detail
        self.observed = observed; self.time = time; self.frames = frames; self.take = take; self.author = author; self.recordedAt = recordedAt; self.notes = notes
        self.recipeFingerprint = recipeFingerprint; self.sceneFingerprint = sceneFingerprint
    }

    /// Bind a newly observed result to the recipe and the media it actually checked.
    public func bound(to recipe: DemoRecipe, document: ProjectDocument) -> EvidenceRecord {
        var record = self
        record.recipeFingerprint = EvidenceContext.recipeFingerprint(recipe)
        record.sceneFingerprint = EvidenceContext.sceneFingerprint(scene, document: document, visual: source == .ocr)
        return record
    }

    public func isCurrent(recipe: DemoRecipe, document: ProjectDocument) -> Bool {
        recipeFingerprint != nil && sceneFingerprint != nil && recipeFingerprint == EvidenceContext.recipeFingerprint(recipe)
            && sceneFingerprint == EvidenceContext.sceneFingerprint(scene, document: document, visual: source == .ocr)
    }

    /// Apply Glint's evidence rules: an action or a model's opinion can't verify anything, and "verified" needs an
    /// observed value. Downgrades are recorded in `notes` rather than rejected, so nothing reported is lost.
    public func normalized() -> EvidenceRecord {
        var r = self
        if r.status == .verified {
            switch r.source {
            case .action:
                r.status = .needsReview
                r.notes.append("A performed action doesn't show its outcome; recorded as needs review.")
            case .vision:
                r.status = .needsReview
                r.notes.append("A model's reading of a frame is not a deterministic check; recorded as needs review.")
            case .assertion, .ocr:
                if (r.observed ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                    r.status = .needsReview
                    r.notes.append("Verified evidence needs the observed value; recorded as needs review.")
                }
            case .human: break
            }
        }
        return r
    }
}

/// Evidence follows kept file ranges, not program offsets: moving an unchanged scene preserves state assertions,
/// while trimming/cutting/replacing its content invalidates them. OCR also depends on the rendered appearance.
public enum EvidenceContext {
    private static func hash<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONCoding.encoder.encode(value), let text = String(data: data, encoding: .utf8) else { return nil }
        return StableHash.hex(text)
    }

    public static func recipeFingerprint(_ recipe: DemoRecipe) -> String? {
        var value = recipe.content
        value.createdAt = .distantPast; value.updatedAt = .distantPast
        return hash(value)
    }

    public static func sceneFingerprint(_ scene: String, document: ProjectDocument, visual: Bool) -> String? {
        let map = TimeMap(document: document)
        let kept: [JSONValue] = ClipLayout(document: document).segments.filter { $0.clip.scene == scene }.flatMap { segment in
            map.pieces.compactMap { piece -> JSONValue? in
                guard let range = segment.range.clamped(to: piece.source), range.duration > 1e-6 else { return nil }
                return .object(["path": .string(segment.clip.path), "take": .string(segment.clip.take ?? "primary"),
                                "start": .number(segment.fileTime(range.start)), "end": .number(segment.fileTime(range.end))])
            }
        }
        guard !kept.isEmpty else { return nil }
        var context: [String: JSONValue] = ["kept": .array(kept)]
        if visual {
            // Conservative: changes anywhere in the rendered timeline require fresh OCR, never reuse a hidden label.
            context["style"] = try? JSONValue.from(document.style)
            context["timeline"] = try? JSONValue.from(document.timeline)
        }
        return hash(JSONValue.object(context))
    }
}

/// Evidence for one project, stored in `evidence.json`.
public struct EvidenceLog: Codable, Hashable, Sendable {
    public var records: [EvidenceRecord] = []
    public init(records: [EvidenceRecord] = []) { self.records = records }
}

/// The verdict for a recipe's demo: every required expectation must be verified by current evidence.
public struct RecipeReport: Codable, Hashable, Sendable {
    public struct Item: Codable, Hashable, Sendable {
        public var scene: String
        public var expectation: String
        public var description: String
        public var required: Bool
        public var status: EvidenceStatus
        public var evidence: [String]
        public var reason: String
    }
    public struct SceneStatus: Codable, Hashable, Sendable {
        public var scene: String
        public var title: String
        public var inEdit: Bool
        public var take: String?
        public var status: EvidenceStatus
    }
    public var recipe: String
    public var version: Int
    public var status: EvidenceStatus
    public var scenes: [SceneStatus]
    public var items: [Item]
    public var summary: String

    /// Combine the recipe, the edit (which takes each scene's shots come from) and the evidence.
    /// - A required expectation with no current evidence is `needs_review` — unknown never passes.
    /// - Any current `failed` record fails the expectation, even when another record verified it.
    /// - Evidence recorded against a take that no longer supplies the scene is ignored as stale.
    public static func evaluate(recipe: DemoRecipe, document doc: ProjectDocument, evidence: EvidenceLog) -> RecipeReport {
        let map = TimeMap(document: doc)
        let clips = ClipLayout(document: doc).segments.filter { map.outputSpan(forSource: $0.range) != nil }.map(\.clip)
        var items: [Item] = []
        var scenes: [SceneStatus] = []
        for s in recipe.scenes {
            let shots = clips.filter { $0.scene == s.id }
            let takes = Set(shots.compactMap { $0.take ?? ($0.primary ? "primary" : nil) })
            var sceneItems: [Item] = []
            for e in s.expectations {
                let current = evidence.records.filter { r in
                    r.scene == s.id && r.expectation == e.id && r.isCurrent(recipe: recipe, document: doc)
                        && (r.take == nil || takes.contains(r.take!))
                }
                let status: EvidenceStatus
                let reason: String
                if shots.isEmpty {
                    status = .needsReview; reason = "scene isn't in the edit"
                } else if let f = current.last(where: { $0.status == .failed }) {
                    status = .failed; reason = f.detail
                } else if let v = current.last(where: { $0.status == .verified }) {
                    status = .verified; reason = "\(v.source.rawValue): \(v.detail)"
                } else if current.isEmpty {
                    status = .needsReview; reason = "no evidence for the current take"
                } else {
                    status = .needsReview; reason = current.last!.notes.last ?? current.last!.detail
                }
                sceneItems.append(Item(scene: s.id, expectation: e.id, description: e.description, required: e.required, status: status,
                                       evidence: current.map(\.id), reason: reason))
            }
            items += sceneItems
            let req = sceneItems.filter(\.required)
            let st: EvidenceStatus = req.contains { $0.status == .failed } ? .failed : (req.allSatisfy { $0.status == .verified } && !shots.isEmpty ? .verified : .needsReview)
            scenes.append(SceneStatus(scene: s.id, title: s.title, inEdit: !shots.isEmpty, take: takes.sorted().first, status: st))
        }
        let req = items.filter(\.required)
        let overall: EvidenceStatus = req.contains { $0.status == .failed } || scenes.contains { $0.status == .failed } ? .failed
            : (scenes.allSatisfy { $0.inEdit } && req.allSatisfy { $0.status == .verified } ? .verified : .needsReview)
        let v = req.filter { $0.status == .verified }.count
        let summary = "\(v)/\(req.count) required outcomes verified" + (overall == .failed ? "; \(req.filter { $0.status == .failed }.count) failed" : "")
            + (scenes.contains { !$0.inEdit } ? "; \(scenes.filter { !$0.inEdit }.count) scene(s) not in the edit" : "")
        return RecipeReport(recipe: recipe.id, version: recipe.version, status: overall, scenes: scenes, items: items, summary: summary)
    }
}

extension ProjectBundle {
    public var recipeURL: URL { url.appendingPathComponent("recipe.json") }
    public var evidenceURL: URL { url.appendingPathComponent("evidence.json") }
    public var evidenceFramesURL: URL { url.appendingPathComponent("evidence", isDirectory: true) }
    public func readRecipe() -> DemoRecipe? { try? JSONCoding.decoder.decode(DemoRecipe.self, from: Data(contentsOf: recipeURL)) }
    public func writeRecipe(_ r: DemoRecipe) throws { try JSONCoding.encoder.encode(r).write(to: recipeURL, options: .atomic) }
    public func readEvidence() -> EvidenceLog { (try? JSONCoding.decoder.decode(EvidenceLog.self, from: Data(contentsOf: evidenceURL))) ?? EvidenceLog() }
    public func writeEvidence(_ e: EvidenceLog) throws { try JSONCoding.encoder.encode(e).write(to: evidenceURL, options: .atomic) }
}

// MARK: - Scene boundaries from markers

public enum RecipeBinding {
    /// Scene ranges in a recording, from markers whose note is `scene:<id>` (or exactly the scene's title).
    /// A scene runs from its marker to the next scene marker (or `end`).
    public static func ranges(recipe: DemoRecipe, markers: [Marker], end: Double) -> [(scene: String, range: TimeRange)] {
        var starts: [(String, Double)] = []
        for m in markers.sorted(by: { $0.time < $1.time }) {
            let note = m.note.trimmingCharacters(in: .whitespaces)
            var id: String?
            if note.lowercased().hasPrefix("scene:") { id = String(note.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
            else if let s = recipe.scenes.first(where: { $0.title.caseInsensitiveCompare(note) == .orderedSame }) { id = s.id }
            if let id, recipe.scene(id) != nil, !starts.contains(where: { $0.0 == id }) { starts.append((id, m.time)) }
        }
        var out: [(String, TimeRange)] = []
        for (i, (id, t)) in starts.enumerated() {
            let e = i + 1 < starts.count ? starts[i + 1].1 : end
            if e - t >= 0.1 { out.append((id, TimeRange(t, e))) }
        }
        return out
    }
}
