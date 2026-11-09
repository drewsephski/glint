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
        case rename
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
    public var timeBase: String?

    enum CodingKeys: String, CodingKey {
        case op, id, start, end, time, scale, focus, rate, path, value, text, hidden, reason, origin, items
        case timeBase = "time_base"
    }

    public init(_ op: Kind, id: String? = nil, start: Double? = nil, end: Double? = nil, time: Double? = nil, scale: Double? = nil,
                focus: JSONValue? = nil, rate: Double? = nil, path: String? = nil, value: JSONValue? = nil, text: String? = nil,
                hidden: Bool? = nil, reason: String? = nil, origin: String? = nil, items: [CaptionSegment]? = nil, timeBase: String? = nil) {
        self.op = op; self.id = id; self.start = start; self.end = end; self.time = time; self.scale = scale; self.focus = focus
        self.rate = rate; self.path = path; self.value = value; self.text = text; self.hidden = hidden; self.reason = reason
        self.origin = origin; self.items = items; self.timeBase = timeBase
    }

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
        case .rename: return "Rename to “\(text ?? "")”"
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
        let lo = max(0, min(s, e)), hi = min(doc.media.duration, max(s, e))
        guard hi - lo >= 0.05 else { throw EditError.invalid("\(op.op.rawValue) range is empty or outside the recording (0–\(String(format: "%.2f", doc.media.duration))s)") }
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
            if let e = op.end { tl.zooms[i].end = min(doc.media.duration, e) }
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
            if let e = op.end { tl.cuts[i].end = min(doc.media.duration, e) }
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
            if let e = op.end { tl.speeds[i].end = min(doc.media.duration, e) }
            if let r = op.rate { guard (0.1...16).contains(r) else { throw EditError.invalid("rate must be 0.1…16") }; tl.speeds[i].rate = r }
        case .removeSpeed:
            guard let id = op.id, tl.speeds.contains(where: { $0.id == id }) else { throw EditError.notFound("speed \(op.id ?? "(no id)")") }
            tl.speeds.removeAll { $0.id == id }
        case .clearSpeeds:
            if let o = op.origin.flatMap(Origin.init(rawValue:)) { tl.speeds.removeAll { $0.origin == o } } else { tl.speeds.removeAll() }

        case .setTrim:
            if let s = op.start { tl.inPoint = max(0, min(s, doc.media.duration)) }
            if op.end != nil || op.value == .null { tl.outPoint = op.end.map { min(doc.media.duration, max(0, $0)) } }
            if let o = tl.outPoint, o - tl.inPoint < 0.2 { throw EditError.invalid("trim leaves less than 0.2s") }

        case .setStyle:
            guard let path = op.path, !path.isEmpty, let value = op.value else { throw EditError.invalid("set_style needs path and value") }
            let pointer = "/" + path.split(separator: ".").map { JSONPatch.escape(String($0)) }.joined(separator: "/")
            let styleJSON = try JSONValue.from(doc.style)
            guard let current = JSONPatch.get(pointer, in: styleJSON) else {
                throw EditError.invalid("unknown style path \(path). See `glint schema style`.")
            }
            var v = value
            // Accept "#RRGGBB" for colors.
            if case .object = current, let hex = value.stringValue, let c = RGBA(hex: hex) { v = try JSONValue.from(c) }
            if case .array = current, case .array(let items) = value {
                v = .array(try items.map { item in
                    if let hex = item.stringValue, let c = RGBA(hex: hex) { return try JSONValue.from(c) }
                    return item
                })
            }
            let patched = try JSONPatch.apply([PatchOp(op: .replace, path: pointer, value: v)], to: styleJSON)
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
        case .rename:
            guard let t = op.text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { throw EditError.invalid("rename needs text") }
            doc.name = t
        }
        tl.zooms.sort { $0.start < $1.start }
        tl.cuts.sort { $0.start < $1.start }
        doc.timeline = tl
    }

    public static func validate(_ doc: ProjectDocument) throws {
        let d = doc.media.duration
        for z in doc.timeline.zooms where z.start < 0 || z.end > d + 0.001 || z.end <= z.start {
            throw EditError.invalid("zoom \(z.id) is outside the recording")
        }
        for c in doc.timeline.cuts where c.end <= c.start { throw EditError.invalid("cut \(c.id) is empty") }
        if TimeMap(document: doc).outputDuration < 0.2 { throw EditError.invalid("the edit would leave less than 0.2s of video") }
    }
}
