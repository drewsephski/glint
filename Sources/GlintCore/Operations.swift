import Foundation

/// One edit, in a flat shape that is easy to write by hand or from an agent:
/// `{"op": "add_zoom", "start": 3.2, "end": 6, "scale": 2}`.
/// Times are source (recording) seconds unless `time_base` is `"output"`, in which case they are converted
/// through the current time map before applying — convenient when an agent reasons about rendered frames.
public struct EditOperation: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case addZoom = "add_zoom", updateZoom = "update_zoom", removeZoom = "remove_zoom", clearZooms = "clear_zooms"
        case addCut = "add_cut", updateCut = "update_cut", removeCut = "remove_cut", clearCuts = "clear_cuts"
        case setSpeed = "set_speed", updateSpeed = "update_speed", removeSpeed = "remove_speed", clearSpeeds = "clear_speeds"
        case setTrim = "set_trim"
        case setStyle = "set_style"
        case setCaptions = "set_captions", updateCaption = "update_caption", removeCaption = "remove_caption", clearCaptions = "clear_captions"
        case addMarker = "add_marker", removeMarker = "remove_marker"
        case addVoiceover = "add_voiceover", updateVoiceover = "update_voiceover", removeVoiceover = "remove_voiceover", clearVoiceover = "clear_voiceover"
        case rename
        case insertClip = "insert_clip", updateClip = "update_clip", removeClip = "remove_clip", moveClip = "move_clip", splitClip = "split_clip", replaceClip = "replace_clip"
        case addAnnotation = "add_annotation", updateAnnotation = "update_annotation", removeAnnotation = "remove_annotation", clearAnnotations = "clear_annotations"
        case addRedaction = "add_redaction", updateRedaction = "update_redaction", removeRedaction = "remove_redaction"
        case addTransition = "add_transition", updateTransition = "update_transition", removeTransition = "remove_transition"
        case addAudio = "add_audio", updateAudio = "update_audio", removeAudio = "remove_audio"
        case mergeStyle = "merge_style"
    }

    public var op: Kind
    public var id: String?
    public var start: Double?
    public var end: Double?
    public var time: Double?
    public var scale: Double?
    /// `"cursor"` or `{"x":…, "y":…}` (normalized screen coordinates).
    public var focus: JSONValue?
    public var rate: Double?
    /// For set_style: dotted path under `style`, e.g. `background.preset`, `cursor.scale`, `canvas.aspect`.
    public var path: String?
    public var value: JSONValue?
    public var text: String?
    public var hidden: Bool?
    public var reason: String?
    /// For clear_*: only remove items with this origin ("auto", "agent", "manual").
    public var origin: String?
    /// For set_captions: caption segments.
    public var items: [CaptionSegment]?
    /// For add_voiceover: the clip (file path, text, duration, word timings).
    public var clip: VoiceoverClip?
    /// For update_voiceover: clip gain (0…3).
    public var gain: Double?
    public var timeBase: String?
    /// For insert_clip / replace_clip: the shot to place.
    public var shot: MediaClip?
    /// For add_/update_ annotation, redaction, transition, audio: the item (update: only the fields to change).
    public var item: JSONValue?
    /// For move_clip: new position (0-based).
    public var index: Int?
    /// For replace_clip / update_clip: recipe scene ID.
    public var scene: String?

    enum CodingKeys: String, CodingKey {
        case op, id, start, end, time, scale, focus, rate, path, value, text, hidden, reason, origin, items, clip, gain, shot, item, index, scene
        case timeBase = "time_base"
    }

    public init(_ op: Kind, id: String? = nil, start: Double? = nil, end: Double? = nil, time: Double? = nil, scale: Double? = nil,
                focus: JSONValue? = nil, rate: Double? = nil, path: String? = nil, value: JSONValue? = nil, text: String? = nil,
                hidden: Bool? = nil, reason: String? = nil, origin: String? = nil, items: [CaptionSegment]? = nil, clip: VoiceoverClip? = nil,
                gain: Double? = nil, timeBase: String? = nil, shot: MediaClip? = nil, item: JSONValue? = nil, index: Int? = nil, scene: String? = nil) {
        self.op = op; self.id = id; self.start = start; self.end = end; self.time = time; self.scale = scale; self.focus = focus
        self.rate = rate; self.path = path; self.value = value; self.text = text; self.hidden = hidden; self.reason = reason
        self.origin = origin; self.items = items; self.clip = clip; self.gain = gain; self.timeBase = timeBase
        self.shot = shot; self.item = item; self.index = index; self.scene = scene
    }

    public static func add<T: Encodable>(_ kind: Kind, _ value: T) -> EditOperation {
        EditOperation(kind, item: try? JSONValue.from(value))
    }

    public static func addVoiceover(_ c: VoiceoverClip) -> EditOperation { EditOperation(.addVoiceover, id: c.id, reason: c.reason, origin: c.origin.rawValue, clip: c) }

    // Convenience constructors.
    public static func addZoom(_ z: ZoomSegment) -> EditOperation {
        var f: JSONValue = .string("cursor")
        if case .point(let p) = z.focus { f = .object(["x": .number(p.x), "y": .number(p.y)]) }
        return EditOperation(.addZoom, id: z.id, start: z.start, end: z.end, scale: z.scale, focus: f, reason: z.reason, origin: z.origin.rawValue)
    }
    public static func addCut(_ c: Cut) -> EditOperation { EditOperation(.addCut, id: c.id, start: c.start, end: c.end, reason: c.reason, origin: c.origin.rawValue) }
    public static func setSpeed(_ s: SpeedSegment) -> EditOperation { EditOperation(.setSpeed, id: s.id, start: s.start, end: s.end, rate: s.rate, reason: s.reason, origin: s.origin.rawValue) }
    public static func style(_ path: String, _ value: JSONValue) -> EditOperation { EditOperation(.setStyle, path: path, value: value) }

    /// One-line human description, used in history and proposal views.
    public var summary: String {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "?" }
        switch op {
        case .addZoom: return "Zoom \(f(scale))× \(f(start))–\(f(end))s"
        case .updateZoom: return "Change zoom \(id ?? "?")"
        case .removeZoom: return "Remove zoom \(id ?? "?")"
        case .clearZooms: return "Remove \(origin ?? "all") zooms"
        case .addCut: return "Cut \(f(start))–\(f(end))s"
        case .updateCut: return "Change cut \(id ?? "?")"
        case .removeCut: return "Restore cut \(id ?? "?")"
        case .clearCuts: return "Remove \(origin ?? "all") cuts"
        case .setSpeed: return "Speed \(f(rate))× \(f(start))–\(f(end))s"
        case .updateSpeed: return "Change speed \(id ?? "?")"
        case .removeSpeed: return "Remove speed \(id ?? "?")"
        case .clearSpeeds: return "Remove \(origin ?? "all") speed changes"
        case .setTrim: return "Trim to \(f(start))–\(end.map { String(format: "%.2f", $0) } ?? "end")s"
        case .setStyle: return "Set \(path ?? "?") = \(value?.description ?? "null")"
        case .setCaptions: return "Set \(items?.count ?? 0) captions"
        case .updateCaption: return "Edit caption \(id ?? "?")"
        case .removeCaption: return "Remove caption \(id ?? "?")"
        case .clearCaptions: return "Remove captions"
        case .addMarker: return "Marker at \(f(time))s"
        case .removeMarker: return "Remove marker \(id ?? "?")"
        case .addVoiceover: return "Voiceover at \(f(clip?.start))s (\(f(clip?.duration))s)"
        case .updateVoiceover: return "Change voiceover \(id ?? "?")"
        case .removeVoiceover: return "Remove voiceover \(id ?? "?")"
        case .clearVoiceover: return "Remove \(origin ?? "all") voiceover"
        case .rename: return "Rename to “\(text ?? "")”"
        case .insertClip: return "Insert clip “\(shot?.name ?? "?")” (\(f(shot?.duration))s)"
        case .updateClip: return "Change clip \(id ?? "?")"
        case .removeClip: return "Remove clip \(id ?? "?")"
        case .moveClip: return "Move clip \(id ?? "?") to \(index.map(String.init) ?? "?")"
        case .splitClip: return "Split clip at \(f(time))s"
        case .replaceClip: return "Replace \(scene.map { "scene \($0)" } ?? "clip \(id ?? "?")") with “\(shot?.name ?? "?")”"
        case .addAnnotation: return "Add \(item?["kind"]?.stringValue ?? "callout")"
        case .updateAnnotation: return "Change callout \(id ?? "?")"
        case .removeAnnotation: return "Remove callout \(id ?? "?")"
        case .clearAnnotations: return "Remove \(origin ?? "all") callouts"
        case .addRedaction: return "Add redaction"
        case .updateRedaction: return "Change redaction \(id ?? "?")"
        case .removeRedaction: return "Remove redaction \(id ?? "?")"
        case .addTransition: return "Add transition"
        case .updateTransition: return "Change transition \(id ?? "?")"
        case .removeTransition: return "Remove transition \(id ?? "?")"
        case .addAudio: return "Add \(item?["kind"]?.stringValue ?? "audio")"
        case .updateAudio: return "Change audio \(id ?? "?")"
        case .removeAudio: return "Remove audio \(id ?? "?")"
        case .mergeStyle: return "Apply style preset"
        }
    }
}

public enum EditError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    case notFound(String)
    case staleRevision(expected: Int, actual: Int)
    case nothingToUndo, nothingToRedo
    case conflict(String)

    public var description: String {
        switch self {
        case .invalid(let s): return "Invalid edit: \(s)"
        case .notFound(let s): return "Not found: \(s)"
        case .staleRevision(let e, let a): return "The project changed (revision \(a), expected \(e)). Re-read it and retry."
        case .nothingToUndo: return "Nothing to undo"
        case .nothingToRedo: return "Nothing to redo"
        case .conflict(let s): return s
        }
    }
}

/// Applies operations to a document value. Pure: no I/O.
public enum OperationApplier {
    public static func apply(_ ops: [EditOperation], to input: ProjectDocument) throws -> ProjectDocument {
        var doc = input
        for raw in ops {
            let op = try normalizeTimes(raw, doc: doc)
            try apply(op, to: &doc)
        }
        try validate(doc)
        return doc
    }

    static func normalizeTimes(_ op: EditOperation, doc: ProjectDocument) throws -> EditOperation {
        guard let base = op.timeBase?.lowercased(), base != "source" else { return op }
        guard base == "output" else { throw EditError.invalid("time_base must be \"source\" or \"output\"") }
        let map = TimeMap(document: doc)
        var o = op
        o.start = op.start.map { map.source(forOutput: $0) }
        o.end = op.end.map { map.source(forOutput: $0) }
        o.time = op.time.map { map.source(forOutput: $0) }
        if case .object(var it)? = op.item {
            for k in ["start", "end", "time"] { if let v = it[k]?.doubleValue { it[k] = .number(map.source(forOutput: v)) } }
            o.item = .object(it)
        }
        o.timeBase = nil
        return o
    }

    static func origin(_ op: EditOperation, default d: Origin) -> Origin { op.origin.flatMap(Origin.init(rawValue:)) ?? d }

    static func parseFocus(_ v: JSONValue?) throws -> ZoomSegment.Focus? {
        guard let v else { return nil }
        if let s = v.stringValue {
            if ["cursor", "follow", "follow_cursor", "auto"].contains(s.lowercased()) { return .followCursor }
            throw EditError.invalid("focus must be \"cursor\" or {x, y}")
        }
        if let x = v["x"]?.doubleValue, let y = v["y"]?.doubleValue {
            guard (0...1).contains(x), (0...1).contains(y) else { throw EditError.invalid("focus x/y must be in 0…1") }
            return .point(NormPoint(x, y))
        }
        throw EditError.invalid("focus must be \"cursor\" or {x, y}")
    }

    static func range(_ op: EditOperation, doc: ProjectDocument) throws -> (Double, Double) {
        guard let s = op.start, let e = op.end else { throw EditError.invalid("\(op.op.rawValue) needs start and end") }
        let lo = max(0, min(s, e)), hi = min(doc.duration, max(s, e))
        guard hi - lo >= 0.05 else { throw EditError.invalid("\(op.op.rawValue) range is empty or outside the recording (0–\(String(format: "%.2f", doc.duration))s)") }
        return (lo, hi)
    }

    static func apply(_ op: EditOperation, to doc: inout ProjectDocument) throws {
        var tl = doc.timeline
        switch op.op {
        case .addZoom:
            let (s, e) = try range(op, doc: doc)
            let scale = op.scale ?? 2
            guard (1.0...6.0).contains(scale) else { throw EditError.invalid("zoom scale must be 1…6") }
            let id = op.id ?? IDs.make("z")
            guard !tl.zooms.contains(where: { $0.id == id }) else { throw EditError.invalid("zoom id \(id) already exists") }
            tl.zooms.append(ZoomSegment(id: id, start: s, end: e, scale: scale, focus: try parseFocus(op.focus) ?? .followCursor,
                                        origin: origin(op, default: .manual), reason: op.reason))
        case .updateZoom:
            guard let id = op.id, let i = tl.zooms.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("zoom \(op.id ?? "(no id)")") }
            if let s = op.start { tl.zooms[i].start = max(0, s) }
            if let e = op.end { tl.zooms[i].end = min(doc.duration, e) }
            if let sc = op.scale { guard (1.0...6.0).contains(sc) else { throw EditError.invalid("zoom scale must be 1…6") }; tl.zooms[i].scale = sc }
            if let f = try parseFocus(op.focus) { tl.zooms[i].focus = f }
            if let r = op.reason { tl.zooms[i].reason = r }
            guard tl.zooms[i].end - tl.zooms[i].start >= 0.05 else { throw EditError.invalid("zoom would be empty") }
        case .removeZoom:
            guard let id = op.id, tl.zooms.contains(where: { $0.id == id }) else { throw EditError.notFound("zoom \(op.id ?? "(no id)")") }
            tl.zooms.removeAll { $0.id == id }
        case .clearZooms:
            if let o = op.origin.flatMap(Origin.init(rawValue:)) { tl.zooms.removeAll { $0.origin == o } } else { tl.zooms.removeAll() }

        case .addCut:
            let (s, e) = try range(op, doc: doc)
            let id = op.id ?? IDs.make("c")
            guard !tl.cuts.contains(where: { $0.id == id }) else { throw EditError.invalid("cut id \(id) already exists") }
            tl.cuts.append(Cut(id: id, start: s, end: e, origin: origin(op, default: .manual), reason: op.reason))
        case .updateCut:
            guard let id = op.id, let i = tl.cuts.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("cut \(op.id ?? "(no id)")") }
            if let s = op.start { tl.cuts[i].start = max(0, s) }
            if let e = op.end { tl.cuts[i].end = min(doc.duration, e) }
            guard tl.cuts[i].end > tl.cuts[i].start else { throw EditError.invalid("cut would be empty") }
        case .removeCut:
            guard let id = op.id, tl.cuts.contains(where: { $0.id == id }) else { throw EditError.notFound("cut \(op.id ?? "(no id)")") }
            tl.cuts.removeAll { $0.id == id }
        case .clearCuts:
            if let o = op.origin.flatMap(Origin.init(rawValue:)) { tl.cuts.removeAll { $0.origin == o } } else { tl.cuts.removeAll() }

        case .setSpeed:
            let (s, e) = try range(op, doc: doc)
            guard let rate = op.rate, (0.1...16).contains(rate) else { throw EditError.invalid("set_speed needs rate in 0.1…16") }
            let id = op.id ?? IDs.make("s")
            // Replace overlapping speed segments (trim them around the new one).
            var kept: [SpeedSegment] = []
            for seg in tl.speeds {
                if seg.end <= s || seg.start >= e { kept.append(seg); continue }
                if seg.start < s { var a = seg; a.end = s; kept.append(a) }
                if seg.end > e { var b = seg; b.start = e; b.id = IDs.make("s"); kept.append(b) }
            }
            kept.append(SpeedSegment(id: id, start: s, end: e, rate: rate, origin: origin(op, default: .manual), reason: op.reason))
            tl.speeds = kept.sorted { $0.start < $1.start }
        case .updateSpeed:
            guard let id = op.id, let i = tl.speeds.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("speed \(op.id ?? "(no id)")") }
            if let s = op.start { tl.speeds[i].start = max(0, s) }
            if let e = op.end { tl.speeds[i].end = min(doc.duration, e) }
            if let r = op.rate { guard (0.1...16).contains(r) else { throw EditError.invalid("rate must be 0.1…16") }; tl.speeds[i].rate = r }
        case .removeSpeed:
            guard let id = op.id, tl.speeds.contains(where: { $0.id == id }) else { throw EditError.notFound("speed \(op.id ?? "(no id)")") }
            tl.speeds.removeAll { $0.id == id }
        case .clearSpeeds:
            if let o = op.origin.flatMap(Origin.init(rawValue:)) { tl.speeds.removeAll { $0.origin == o } } else { tl.speeds.removeAll() }

        case .setTrim:
            if let s = op.start { tl.inPoint = max(0, min(s, doc.duration)) }
            if op.end != nil || op.value == .null { tl.outPoint = op.end.map { min(doc.duration, max(0, $0)) } }
            if let o = tl.outPoint, o - tl.inPoint < 0.2 { throw EditError.invalid("trim leaves less than 0.2s") }

        case .setStyle:
            guard let path = op.path, !path.isEmpty, let value = op.value else { throw EditError.invalid("set_style needs path and value") }
            let pointer = "/" + path.split(separator: ".").map { JSONPatch.escape(String($0)) }.joined(separator: "/")
            let styleJSON = try JSONValue.from(doc.style)
            // Optional fields (nil) are absent from the encoded style; they're still valid paths.
            let current: JSONValue
            if let c = JSONPatch.get(pointer, in: styleJSON) { current = c }
            else if Style.optionalPaths.contains(path) { current = .null }
            else { throw EditError.invalid("unknown style path \(path). See `glint schema style`.") }
            var v = value
            // Accept "#RRGGBB" for colors.
            if case .object = current, let hex = value.stringValue, let c = RGBA(hex: hex) { v = try JSONValue.from(c) }
            if case .array = current, case .array(let items) = value {
                v = .array(try items.map { item in
                    if let hex = item.stringValue, let c = RGBA(hex: hex) { return try JSONValue.from(c) }
                    return item
                })
            }
            let patched = try JSONPatch.apply([PatchOp(op: current == .null && JSONPatch.get(pointer, in: styleJSON) == nil ? .add : .replace, path: pointer, value: v)], to: styleJSON)
            do { doc.style = try patched.decode(Style.self) } catch {
                throw EditError.invalid("value \(value) doesn't fit \(path) (current: \(current))")
            }

        case .setCaptions:
            tl.captions = (op.items ?? []).sorted { $0.start < $1.start }
        case .updateCaption:
            guard let id = op.id, let i = tl.captions.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("caption \(op.id ?? "(no id)")") }
            if let t = op.text {
                tl.captions[i].text = t
                // Re-time words evenly so highlight stays sensible after a text fix.
                let tokens = t.split(separator: " ").map(String.init)
                let c = tl.captions[i]
                let step = (c.end - c.start) / Double(max(1, tokens.count))
                tl.captions[i].words = tokens.enumerated().map { CaptionWord(text: $1, start: c.start + Double($0) * step, end: c.start + Double($0 + 1) * step) }
            }
            if let h = op.hidden { tl.captions[i].hidden = h }
            if let s = op.start { tl.captions[i].start = s }
            if let e = op.end { tl.captions[i].end = e }
        case .removeCaption:
            guard let id = op.id, tl.captions.contains(where: { $0.id == id }) else { throw EditError.notFound("caption \(op.id ?? "(no id)")") }
            tl.captions.removeAll { $0.id == id }
        case .clearCaptions:
            tl.captions.removeAll()

        case .addMarker:
            guard let t = op.time else { throw EditError.invalid("add_marker needs time") }
            tl.markers.append(Marker(id: op.id ?? IDs.make("m"), time: t, note: op.text ?? "", author: Author(.user, "edit")))
            tl.markers.sort { $0.time < $1.time }
        case .removeMarker:
            guard let id = op.id, tl.markers.contains(where: { $0.id == id }) else { throw EditError.notFound("marker \(op.id ?? "(no id)")") }
            tl.markers.removeAll { $0.id == id }
        case .addVoiceover:
            guard var c = op.clip else { throw EditError.invalid("add_voiceover needs clip {start, path, text, duration, words?}") }
            if let id = op.id { c.id = id }
            if let s = op.start { c.start = s }
            if let r = op.reason { c.reason = r }
            if let o = op.origin.flatMap(Origin.init(rawValue:)) { c.origin = o }
            guard !c.path.isEmpty, c.duration > 0.05 else { throw EditError.invalid("voiceover clip needs a path and a duration") }
            guard c.start >= 0, c.start <= doc.duration else { throw EditError.invalid("voiceover start is outside the recording") }
            guard !tl.voiceover.contains(where: { $0.id == c.id }) else { throw EditError.invalid("voiceover id \(c.id) already exists") }
            c.gain = max(0, min(3, c.gain))
            tl.voiceover.append(c)
        case .updateVoiceover:
            guard let id = op.id, let i = tl.voiceover.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("voiceover \(op.id ?? "(no id)")") }
            if let s = op.start { tl.voiceover[i].start = max(0, min(doc.duration, s)) }
            if let g = op.gain { guard (0...3).contains(g) else { throw EditError.invalid("gain must be 0…3") }; tl.voiceover[i].gain = g }
            if let t = op.text { tl.voiceover[i].text = t }
            if let r = op.reason { tl.voiceover[i].reason = r }
        case .removeVoiceover:
            guard let id = op.id, tl.voiceover.contains(where: { $0.id == id }) else { throw EditError.notFound("voiceover \(op.id ?? "(no id)")") }
            tl.voiceover.removeAll { $0.id == id }
        case .clearVoiceover:
            if let o = op.origin.flatMap(Origin.init(rawValue:)) { tl.voiceover.removeAll { $0.origin == o } } else { tl.voiceover.removeAll() }
        case .insertClip, .updateClip, .removeClip, .moveClip, .splitClip, .replaceClip:
            doc.timeline = tl
            try ClipEditor.apply(op, to: &doc)
            tl = doc.timeline
        case .addAnnotation:
            let a: Annotation = try decodeItem(op, defaults: Annotation(kind: .box, start: 0, end: 1))
            guard !tl.annotations.contains(where: { $0.id == a.id }) else { throw EditError.invalid("callout id \(a.id) already exists") }
            try a.validate(duration: doc.duration)
            tl.annotations.append(a)
        case .updateAnnotation:
            guard let id = op.id, let i = tl.annotations.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("callout \(op.id ?? "(no id)")") }
            var a: Annotation = try decodeItem(op, defaults: tl.annotations[i]); a.id = id
            try a.validate(duration: doc.duration)
            tl.annotations[i] = a
        case .removeAnnotation:
            guard let id = op.id, tl.annotations.contains(where: { $0.id == id }) else { throw EditError.notFound("callout \(op.id ?? "(no id)")") }
            tl.annotations.removeAll { $0.id == id }
        case .clearAnnotations:
            if let o = op.origin.flatMap(Origin.init(rawValue:)) { tl.annotations.removeAll { $0.origin == o } } else { tl.annotations.removeAll() }
        case .addRedaction:
            let r: Redaction = try decodeItem(op, defaults: Redaction(start: 0, end: 1, rect: NormRect(x: 0.4, y: 0.4, width: 0.2, height: 0.1)))
            guard !tl.redactions.contains(where: { $0.id == r.id }) else { throw EditError.invalid("redaction id \(r.id) already exists") }
            try r.validate(duration: doc.duration)
            tl.redactions.append(r)
        case .updateRedaction:
            guard let id = op.id, let i = tl.redactions.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("redaction \(op.id ?? "(no id)")") }
            var r: Redaction = try decodeItem(op, defaults: tl.redactions[i]); r.id = id
            try r.validate(duration: doc.duration)
            tl.redactions[i] = r
        case .removeRedaction:
            guard let id = op.id, tl.redactions.contains(where: { $0.id == id }) else { throw EditError.notFound("redaction \(op.id ?? "(no id)")") }
            tl.redactions.removeAll { $0.id == id }
        case .addTransition, .updateTransition:
            var t: Transition
            if op.op == .addTransition {
                t = try decodeItem(op, defaults: Transition(time: op.time ?? 0))
                if let tm = op.time { t.time = tm }
                guard !tl.transitions.contains(where: { $0.id == t.id }) else { throw EditError.invalid("transition id \(t.id) already exists") }
            } else {
                guard let id = op.id, let i = tl.transitions.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("transition \(op.id ?? "(no id)")") }
                t = try decodeItem(op, defaults: tl.transitions[i]); t.id = id
                if let tm = op.time { t.time = tm }
            }
            guard t.time >= 0, t.time <= doc.duration + 1e-3 else { throw EditError.invalid("transition time is outside the program (0–\(fmt(doc.duration))s)") }
            guard (0.1...4).contains(t.duration) else { throw EditError.invalid("transition duration must be 0.1…4s") }
            tl.transitions.removeAll { $0.id == t.id }
            tl.transitions.append(t)
            tl.transitions.sort { $0.time < $1.time }
        case .removeTransition:
            guard let id = op.id, tl.transitions.contains(where: { $0.id == id }) else { throw EditError.notFound("transition \(op.id ?? "(no id)")") }
            tl.transitions.removeAll { $0.id == id }
        case .addAudio:
            let a: AudioClip = try decodeItem(op, defaults: AudioClip(kind: .music, name: "", path: "", fileDuration: 0))
            guard !tl.audio.contains(where: { $0.id == a.id }) else { throw EditError.invalid("audio id \(a.id) already exists") }
            try a.validate(duration: doc.duration)
            tl.audio.append(a)
            tl.audio.sort { $0.start < $1.start }
        case .updateAudio:
            guard let id = op.id, let i = tl.audio.firstIndex(where: { $0.id == id }) else { throw EditError.notFound("audio \(op.id ?? "(no id)")") }
            var a: AudioClip = try decodeItem(op, defaults: tl.audio[i]); a.id = id
            if let g = op.gain { a.gain = g }
            if let s = op.start { a.start = s }
            try a.validate(duration: doc.duration)
            tl.audio[i] = a
        case .removeAudio:
            guard let id = op.id, tl.audio.contains(where: { $0.id == id }) else { throw EditError.notFound("audio \(op.id ?? "(no id)")") }
            tl.audio.removeAll { $0.id == id }
        case .mergeStyle:
            guard let v = op.value, case .object = v else { throw EditError.invalid("merge_style needs value: a partial style object") }
            let current = try JSONValue.from(doc.style)
            let known = Set(current.objectValue?.keys.map { $0 } ?? [])
            for k in v.objectValue?.keys.map({ $0 }) ?? [] where !known.contains(k) { throw EditError.invalid("unknown style section \(k). See `glint schema style`.") }
            do { doc.style = try v.merged(over: current).decode(Style.self) } catch { throw EditError.invalid("style preset doesn't fit the style schema: \(error)") }
        case .rename:
            guard let t = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { throw EditError.invalid("rename needs text") }
            doc.name = t
        }
        tl.voiceover.sort { $0.start < $1.start }
        tl.annotations.sort { $0.start < $1.start }
        tl.redactions.sort { $0.start < $1.start }
        tl.zooms.sort { $0.start < $1.start }
        tl.cuts.sort { $0.start < $1.start }
        doc.timeline = tl
    }

    /// Decode an item from `op.item` laid over `defaults` (for adds: type defaults; for updates: the current item).
    static func decodeItem<T: Codable>(_ op: EditOperation, defaults: T) throws -> T {
        var base = try JSONValue.from(defaults)
        if op.op.rawValue.hasPrefix("add_"), case .object(var o) = base { o["id"] = .string(op.id ?? (o["id"]?.stringValue ?? IDs.make("x"))); base = .object(o) }
        let patch = op.item ?? .object([:])
        guard case .object = patch else { throw EditError.invalid("\(op.op.rawValue) item must be an object") }
        var merged = patch.merged(over: base)
        // Accept "#RRGGBB" for colour fields.
        if case .object(var o) = merged {
            for (k, v) in o { if let hex = v.stringValue, base[k]?.objectValue?["r"] != nil, let c = RGBA(hex: hex) { o[k] = try JSONValue.from(c) } }
            if let id = op.id, op.op.rawValue.hasPrefix("add_") { o["id"] = .string(id) }
            merged = .object(o)
        }
        do { return try merged.decode(T.self) } catch {
            throw EditError.invalid("\(op.op.rawValue): item doesn't fit (\(Self.decodingMessage(error))). See glint://docs/operations.")
        }
    }

    public static func decodingMessage(_ e: Error) -> String {
        if case DecodingError.dataCorrupted(let c) = e { return c.debugDescription }
        if case DecodingError.typeMismatch(_, let c) = e { return "\(c.codingPath.map(\.stringValue).joined(separator: ".")): \(c.debugDescription)" }
        if case DecodingError.valueNotFound(_, let c) = e { return "missing \(c.codingPath.map(\.stringValue).joined(separator: "."))" }
        if case DecodingError.keyNotFound(let k, _) = e { return "missing \(k.stringValue)" }
        return "\(e)"
    }

    public static func validate(_ doc: ProjectDocument) throws {
        let d = doc.duration
        guard TimelineLimits.contains(d), TimelineLimits.contains(doc.media.duration) else {
            throw EditError.invalid("source and program duration must be finite and no longer than six hours")
        }
        guard doc.timeline.inPoint.isFinite, doc.timeline.outPoint?.isFinite ?? true else {
            throw EditError.invalid("trim times must be finite")
        }
        for c in doc.timeline.clips {
            guard TimelineLimits.contains(c.mediaStart), TimelineLimits.contains(c.mediaEnd),
                  c.fileDuration.map({ TimelineLimits.contains($0) && $0 > 0 }) ?? true else {
                throw EditError.invalid("clip \(c.id) times must be finite and within the six-hour recording limit")
            }
        }
        for s in doc.timeline.speeds where !s.start.isFinite || !s.end.isFinite || !(0.1...16).contains(s.rate) {
            throw EditError.invalid("speed times must be finite and rate must be 0.1…16")
        }
        for z in doc.timeline.zooms where z.start < 0 || z.end > d + 0.001 || z.end <= z.start {
            throw EditError.invalid("zoom \(z.id) is outside the recording")
        }
        for c in doc.timeline.cuts where c.end <= c.start { throw EditError.invalid("cut \(c.id) is empty") }
        for c in doc.timeline.clips where c.duration < 0.1 { throw EditError.invalid("clip \(c.id) is shorter than 0.1s") }
        for r in doc.timeline.redactions where r.end > d + 0.001 || r.start < 0 { throw EditError.invalid("redaction \(r.id) is outside the program") }
        for a in doc.timeline.annotations where a.end > d + 0.001 || a.start < 0 { throw EditError.invalid("callout \(a.id) is outside the program") }
        let outputDuration = TimeMap(document: doc).outputDuration
        guard TimelineLimits.contains(outputDuration) else { throw EditError.invalid("edited output must be finite and no longer than six hours") }
        if outputDuration < 0.2 { throw EditError.invalid("the edit would leave less than 0.2s of video") }
    }
}
