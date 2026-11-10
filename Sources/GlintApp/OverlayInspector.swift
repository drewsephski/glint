import SwiftUI
import GlintCore
import GlintAgent

// Inspectors for shots, callouts, masks, transitions and audio. Every change is one undoable edit through
// `model.apply`. Used by the selection card (Style tab) and inline in the Media tab.

/// Picks the inspector for a selected item.
struct OverlayInspector: View {
    let model: EditorModel
    let selection: Selection
    var body: some View {
        switch selection {
        case .clip(let id): ClipInspector(model: model, id: id)
        case .annotation(let id): AnnotationInspector(model: model, id: id)
        case .redaction(let id): RedactionInspector(model: model, id: id)
        case .transition(let id): TransitionInspector(model: model, id: id)
        case .audio(let id): AudioInspector(model: model, id: id)
        default: EmptyView()
        }
    }
}

/// The heading of an inspector: what it is, in its lane colour.
struct InspectorTitle: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.text
    var detail: String?
    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(tint).lineLimit(1)
            Spacer(minLength: 4)
            if let detail { Text(detail).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3) }
        }
    }
}

/// A destructive row action that removes an item (undoable, so no confirmation).
struct RemoveButton: View {
    var title = "Remove"
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) { Label(title, systemImage: "trash") }.buttonStyle(GhostButtonStyle())
    }
}

/// Where an item sits in the program, and controls to move its start and end.
struct SpanEditor: View {
    let model: EditorModel
    let start: Double
    let end: Double
    var minimum = 0.1
    let onChange: (_ start: Double?, _ end: Double?) -> Void
    var body: some View {
        let d = model.doc.duration
        VStack(alignment: .leading, spacing: 6) {
            TimeStepper(label: "Starts", value: start, range: 0...max(0, end - minimum)) { onChange($0, nil) }
            TimeStepper(label: "Ends", value: end, range: min(d, start + minimum)...d) { onChange(nil, $0) }
            HStack(spacing: 6) {
                Button("Start at playhead") {
                    let t = model.sourceTime
                    let len = end - start
                    onChange(min(t, max(0, d - minimum)), min(d, max(t + minimum, t + len)))
                }
                Button("End at playhead") { onChange(nil, model.sourceTime) }.disabled(model.sourceTime < start + minimum)
                Spacer(minLength: 0)
            }
            .buttonStyle(GhostButtonStyle()).controlSize(.small)
        }
    }
}

// MARK: - Shots

struct ClipInspector: View {
    let model: EditorModel
    let id: String
    @State private var confirmRemove = false
    @State private var recipe: DemoRecipe?

    var body: some View {
        let layout = model.clipLayout
        if let seg = layout.segments.first(where: { $0.clip.id == id }) {
            let c = seg.clip
            let fileLength = c.fileDuration ?? (c.primary ? model.doc.media.duration : c.mediaEnd)
            VStack(alignment: .leading, spacing: 10) {
                InspectorTitle(title: "Shot \(seg.index + 1)", systemImage: "film", tint: Theme.accent, detail: String(format: "%.1fs", c.duration))
                CommitTextField(placeholder: "Shot name", value: c.name) { name in
                    let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    model.apply([EditOperation(.updateClip, id: id, text: t)], label: "Rename shot")
                }
                Hint("\(ShotKind(c).description). Plays from \(Theme.time(seg.start, precise: true)) in the video.")
                SectionHeader(title: "Part of the file to use")
                TimeStepper(label: "From", value: c.mediaStart, range: 0...max(0, c.mediaEnd - 0.1)) { v in
                    model.apply([EditOperation(.updateClip, id: id, start: v)], label: "Trim shot start")
                }
                TimeStepper(label: "To", value: c.mediaEnd, range: min(fileLength, c.mediaStart + 0.1)...fileLength) { v in
                    model.apply([EditOperation(.updateClip, id: id, end: v)], label: "Trim shot end")
                }
                Hint("Times in the \(c.primary ? "recording" : "file") (\(Theme.time(fileLength, precise: true)) long). Edits on the shot stay on the same moments.")
                if !c.primary, !c.audio.isEmpty {
                    CommitSlider(label: "Shot audio", value: c.gain, range: 0...3, format: { "\(Int(($0 * 100).rounded()))%" }) { g in
                        model.apply([EditOperation(.updateClip, id: id, gain: g)], label: "Shot audio level")
                    }
                }
                if let recipe {
                    Picker("Recipe scene", selection: Binding(get: { c.scene ?? "" }, set: { s in
                        model.apply([EditOperation(.updateClip, id: id, scene: s)], label: s.isEmpty ? "Clear shot scene" : "Shot shows scene \(recipe.scene(s)?.title ?? s)")
                    })) {
                        Text("None").tag("")
                        ForEach(recipe.scenes) { s in Text(s.title).tag(s.id) }
                        if let s = c.scene, recipe.scene(s) == nil { Text("\(s) (not in the recipe)").tag(s) }
                    }
                    .controlSize(.small)
                } else if let s = c.scene {
                    HStack { Text("Recipe scene").font(.system(size: 12)).foregroundStyle(Theme.text2); Spacer(); Tag(s) }
                }
                HStack(spacing: 6) {
                    Button { model.moveShot(id, to: seg.index - 1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(IconButtonStyle()).disabled(seg.index == 0).help("Move earlier")
                    Button { model.moveShot(id, to: seg.index + 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(IconButtonStyle()).disabled(seg.index >= layout.segments.count - 1).help("Move later")
                    Button { model.splitShotAtPlayhead() } label: { Label("Split at playhead", systemImage: "scissors") }
                        .buttonStyle(GhostButtonStyle()).disabled(!canSplit(seg))
                        .help(canSplit(seg) ? "Split this shot in two at the playhead" : "Move the playhead inside this shot to split it")
                    Spacer(minLength: 0)
                    Button(role: .destructive) { confirmRemove = true } label: { Image(systemName: "trash") }
                        .buttonStyle(IconButtonStyle()).disabled(layout.segments.count < 2)
                        .help(layout.segments.count < 2 ? "The video needs at least one shot" : "Remove this shot")
                }
            }
            .onAppear { recipe = model.bundle.readRecipe() }
            .confirmationDialog("Remove “\(c.name)”?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove shot", role: .destructive) {
                    model.apply([EditOperation(.removeClip, id: id)], label: "Remove shot “\(c.name)”")
                    if model.selection == .clip(id) { model.selection = nil }
                }
                Button("Cancel", role: .cancel) {}
            } message: { Text(removeMessage(c)) }
        } else {
            Hint("This shot is no longer in the edit.")
        }
    }

    func canSplit(_ seg: ClipLayout.Segment) -> Bool {
        let t = model.sourceTime
        return t - seg.start >= 0.05 && seg.end - t >= 0.05
    }

    func removeMessage(_ c: MediaClip) -> String {
        let report = (try? ClipEditor.preview(EditOperation(.removeClip, id: id), on: model.doc))?.report
        let n = report?.dropped.count ?? 0
        let file = c.primary ? "The recording stays in the project." : "The file stays in the project."
        return n == 0 ? "\(file) You can undo this." : "\(n) edit\(n == 1 ? "" : "s") on this shot (zooms, captions, callouts…) will be removed with it. \(file) You can undo this."
    }
}

/// How a shot got into the project, in words.
struct ShotKind: CustomStringConvertible {
    let clip: MediaClip
    init(_ c: MediaClip) { clip = c }
    var description: String { clip.primary ? "Your recording" : clip.take != nil ? "From another recording" : "Imported movie" }
    var short: String { clip.primary ? "Recording" : clip.take != nil ? "Take" : "Imported" }
}

// MARK: - Audio

struct AudioInspector: View {
    let model: EditorModel
    let id: String

    var body: some View {
        if let a = model.doc.timeline.audio.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                InspectorTitle(title: AudioKindText.title(a.kind), systemImage: AudioKindText.icon(a.kind), tint: Theme.voice, detail: String(format: "%.1fs file", a.fileDuration))
                CommitTextField(placeholder: "Name", value: a.name) { n in
                    let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    update(["name": .string(t)], "Rename audio")
                }
                TimeStepper(label: "Starts in the video at", value: a.start, range: 0...model.doc.duration) { v in
                    model.apply([EditOperation(.updateAudio, id: id, start: v)], label: "Move \(a.name)")
                }
                HStack {
                    Button("Start at playhead") { model.apply([EditOperation(.updateAudio, id: id, start: model.sourceTime)], label: "Move \(a.name)") }
                        .buttonStyle(GhostButtonStyle()).controlSize(.small)
                    Spacer()
                }
                CommitSlider(label: "Level", value: a.gain, range: 0...3, format: { "\(Int(($0 * 100).rounded()))%" }) { g in
                    model.apply([EditOperation(.updateAudio, id: id, gain: g)], label: "\(a.name) level")
                }
                Toggle("Repeat to fill the video", isOn: Binding(get: { a.loop }, set: { update(["loop": .bool($0)], $0 ? "Loop \(a.name)" : "Stop looping \(a.name)") }))
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                Toggle("Lower under narration", isOn: Binding(get: { a.duckUnderVoice }, set: { update(["duckUnderVoice": .bool($0)], "Ducking for \(a.name)") }))
                    .toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                CommitSlider(label: "Fade in", value: a.fadeIn, range: 0...10, step: 0.1, format: { String(format: "%.1fs", $0) }) { update(["fadeIn": .number($0)], "Fade in \(a.name)") }
                CommitSlider(label: "Fade out", value: a.fadeOut, range: 0...10, step: 0.1, format: { String(format: "%.1fs", $0) }) { update(["fadeOut": .number($0)], "Fade out \(a.name)") }
                Toggle("Stop after a set time", isOn: Binding(get: { a.length != nil }, set: { on in
                    update(["length": on ? .number(max(0.1, min(30, a.loop ? 30 : a.fileDuration - a.mediaStart))) : .null], on ? "Set length of \(a.name)" : "Play \(a.name) to the end")
                }))
                .toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
                if let l = a.length {
                    TimeStepper(label: "Plays for", value: l, range: 0.1...3600) { update(["length": .number($0)], "Set length of \(a.name)") }
                } else {
                    Hint(a.loop ? "Repeats until the video ends." : "Plays until the file or the video ends.")
                }
                if a.fileDuration > 0.2 {
                    TimeStepper(label: "Skip into the file", value: a.mediaStart, range: 0...max(0, a.fileDuration - 0.1)) { update(["mediaStart": .number($0)], "Offset \(a.name)") }
                }
                RemoveButton { model.apply([EditOperation(.removeAudio, id: id)], label: "Remove \(a.name)"); if model.selection == .audio(id) { model.selection = nil } }
            }
        } else {
            Hint("This audio is no longer in the edit.")
        }
    }

    func update(_ fields: [String: JSONValue], _ label: String) { model.updateOverlay(.updateAudio, id: id, fields, label: label) }
}

enum AudioKindText {
    static func title(_ k: AudioClip.Kind) -> String { k == .music ? "Music" : k == .voice ? "Voiceover" : "Sound" }
    static func icon(_ k: AudioClip.Kind) -> String { k == .music ? "music.note" : k == .voice ? "mic" : "speaker.wave.2" }
}

// MARK: - Transitions

struct TransitionInspector: View {
    let model: EditorModel
    let id: String
    var body: some View {
        if let t = model.doc.timeline.transitions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                InspectorTitle(title: "Transition", systemImage: "square.on.square.dashed", tint: Theme.accent, detail: Theme.time(t.time, precise: true))
                Segmented(items: [(GlintCore.Transition.Kind.dipBlack, "Dip to black"), (.dipWhite, "Dip to white")],
                          selection: Binding(get: { t.kind }, set: { k in model.updateOverlay(.updateTransition, id: id, ["kind": .string(k.rawValue)], label: "GlintCore.Transition colour") }), compact: true)
                CommitSlider(label: "Length", value: t.duration, range: 0.1...4, step: 0.05, format: { String(format: "%.2fs", $0) }) { v in
                    model.updateOverlay(.updateTransition, id: id, ["duration": .number(v)], label: "GlintCore.Transition length")
                }
                TimeStepper(label: "Centred at", value: t.time, range: 0...model.doc.duration) { v in
                    model.apply([EditOperation(.updateTransition, id: id, time: v)], label: "Move transition")
                }
                HStack {
                    Button("Move to playhead") { model.apply([EditOperation(.updateTransition, id: id, time: model.sourceTime)], label: "Move transition") }
                        .buttonStyle(GhostButtonStyle()).controlSize(.small)
                    Spacer()
                    RemoveButton { model.apply([EditOperation(.removeTransition, id: id)], label: "Remove transition"); if model.selection == .transition(id) { model.selection = nil } }
                }
                if t.time < 0.05 || t.time > model.doc.duration - 0.05 { Hint("At the very start or end, a dip becomes a fade in or out.") }
            }
        } else {
            Hint("This transition is no longer in the edit.")
        }
    }
}

// MARK: - Callouts

struct AnnotationInspector: View {
    let model: EditorModel
    let id: String

    var body: some View {
        if let a = model.doc.timeline.annotations.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                InspectorTitle(title: CalloutText.title(a.kind), systemImage: CalloutText.icon(a.kind), tint: Theme.accent, detail: String(format: "%.1fs", a.end - a.start))
                if a.kind == .text {
                    CommitTextField(placeholder: "Label text", value: a.text ?? "", axis: .vertical, lineLimit: 1...4) { t in
                        let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !s.isEmpty else { model.banner = "A text label needs some text"; return }
                        update(["text": .string(String(s.prefix(280)))], "Edit label text")
                    }
                }
                SpanEditor(model: model, start: a.start, end: a.end) { s, e in
                    var f: [String: JSONValue] = [:]
                    if let s { f["start"] = .number(s) }
                    if let e { f["end"] = .number(e) }
                    update(f, "Retime \(CalloutText.title(a.kind).lowercased())")
                }
                ColorField(label: a.kind == .text ? "Label background" : "Colour", color: a.color) { update(["color": .string($0)], "Callout colour") }
                if a.kind == .text {
                    ColorField(label: "Text colour", color: a.textColor) { update(["textColor": .string($0)], "Callout text colour") }
                    CommitSlider(label: "Text size", value: a.fontSize, range: 0.01...0.2, format: { String(format: "%.1f%%", $0 * 100) }) { update(["fontSize": .number($0)], "Callout text size") }
                } else {
                    CommitSlider(label: "Line width", value: a.strokeWidth, range: 0.0005...0.05, format: { String(format: "%.1f%%", $0 * 100) }) { update(["strokeWidth": .number($0)], "Callout line width") }
                }
                if a.kind == .highlight {
                    CommitSlider(label: "Darken outside", value: a.dim, range: 0...0.9, format: { "\(Int(($0 * 100).rounded()))%" }) { update(["dim": .number($0)], "Spotlight darkness") }
                }
                DisclosureGroup("Position and size") {
                    VStack(alignment: .leading, spacing: 8) {
                        if a.kind == .arrow {
                            PointEditor(title: "Tail", point: a.from ?? NormPoint(0.35, 0.35)) { update(["from": jsonPoint($0)], "Move arrow tail") }
                            PointEditor(title: "Tip", point: a.to ?? .center) { update(["to": jsonPoint($0)], "Move arrow tip") }
                        } else {
                            RectEditor(rect: a.rect ?? NormRect(x: 0.35, y: 0.35, width: 0.3, height: 0.2), textOnly: a.kind == .text) { update(["rect": jsonRect($0)], "Move callout") }
                        }
                        Hint("Positions are a share of the screen, from the top left. You can also drag on the preview.")
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                RemoveButton { model.apply([EditOperation(.removeAnnotation, id: id)], label: "Remove callout"); if model.selection == .annotation(id) { model.selection = nil } }
            }
        } else {
            Hint("This callout is no longer in the edit.")
        }
    }

    func update(_ fields: [String: JSONValue], _ label: String) { model.updateOverlay(.updateAnnotation, id: id, fields, label: label) }
}

enum CalloutText {
    static func title(_ k: Annotation.Kind) -> String {
        switch k { case .text: "Text label"; case .arrow: "Arrow"; case .box: "Box"; case .highlight: "Spotlight" }
    }
    static func icon(_ k: Annotation.Kind) -> String {
        switch k { case .text: "textformat"; case .arrow: "arrow.up.right"; case .box: "rectangle"; case .highlight: "light.max" }
    }
}

func jsonPoint(_ p: NormPoint) -> JSONValue { .object(["x": .number(p.x), "y": .number(p.y)]) }
func jsonRect(_ r: NormRect) -> JSONValue { .object(["x": .number(r.x), "y": .number(r.y), "width": .number(r.width), "height": .number(r.height)]) }

/// Edits a normalized rectangle, keeping it inside the screen.
struct RectEditor: View {
    let rect: NormRect
    var textOnly = false
    let onCommit: (NormRect) -> Void
    var body: some View {
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        VStack(alignment: .leading, spacing: 6) {
            CommitSlider(label: "Left", value: rect.x, range: 0...max(0, 1 - rect.width), format: pct) { var r = rect; r.x = $0; onCommit(r) }
            CommitSlider(label: "Top", value: rect.y, range: 0...max(0, 1 - (textOnly ? 0.02 : rect.height)), format: pct) { var r = rect; r.y = $0; onCommit(r) }
            CommitSlider(label: "Width", value: rect.width, range: (textOnly ? 0.05 : 0.01)...max(textOnly ? 0.05 : 0.01, 1 - rect.x), format: pct) { var r = rect; r.width = $0; onCommit(r) }
            if !textOnly {
                CommitSlider(label: "Height", value: rect.height, range: 0.01...max(0.01, 1 - rect.y), format: pct) { var r = rect; r.height = $0; onCommit(r) }
            }
        }
    }
}

struct PointEditor: View {
    let title: String
    let point: NormPoint
    let onCommit: (NormPoint) -> Void
    var body: some View {
        let pct: (Double) -> String = { "\(Int(($0 * 100).rounded()))%" }
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text2)
            CommitSlider(label: "Across", value: point.x, range: 0...1, format: pct) { onCommit(NormPoint($0, point.y)) }
            CommitSlider(label: "Down", value: point.y, range: 0...1, format: pct) { onCommit(NormPoint(point.x, $0)) }
        }
    }
}

// MARK: - Redactions

struct RedactionInspector: View {
    let model: EditorModel
    let id: String

    var body: some View {
        if let r = model.doc.timeline.redactions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 10) {
                InspectorTitle(title: r.label?.isEmpty == false ? r.label! : "Redaction", systemImage: "eye.slash", tint: Theme.cut, detail: String(format: "%.1fs", r.end - r.start))
                CommitTextField(placeholder: "What it hides (optional, for you)", value: r.label ?? "") { update(["label": .string($0)], "Name redaction") }
                Segmented(items: [(Redaction.Mode.pixelate, "Pixelate"), (.blur, "Blur"), (.solid, "Solid")],
                          selection: Binding(get: { r.mode }, set: { m in update(["mode": .string(m.rawValue)], "Redaction style") }), compact: true)
                if r.mode == .solid {
                    ColorField(label: "Colour", color: r.color) { update(["color": .string($0)], "Redaction colour") }
                } else {
                    CommitSlider(label: "Strength", value: r.strength, range: 0.1...1, format: { "\(Int(($0 * 100).rounded()))%" }) { update(["strength": .number($0)], "Redaction strength") }
                }
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.shield").font(.system(size: 11)).foregroundStyle(r.mode != .solid && r.strength < 0.6 ? Theme.speed : Theme.text3)
                    Text(r.mode == .solid ? "Solid hides everything under it. This is the safest choice for passwords, keys and personal details."
                         : "Pixelate and blur at low strength can leave text readable. Solid is the safest way to hide something.")
                        .font(.system(size: 11)).foregroundStyle(r.mode != .solid && r.strength < 0.6 ? Theme.speed : Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
                SpanEditor(model: model, start: r.start, end: r.end, minimum: 0.04) { s, e in
                    var f: [String: JSONValue] = [:]
                    if let s { f["start"] = .number(s) }
                    if let e { f["end"] = .number(e) }
                    update(f, "Retime redaction")
                }
                HStack {
                    Button("Whole video") { update(["start": .number(0), "end": .number(model.doc.duration)], "Redact for the whole video") }
                        .buttonStyle(GhostButtonStyle()).controlSize(.small).help("Keep this area hidden from start to end")
                    Spacer()
                }
                DisclosureGroup("Position and size") {
                    VStack(alignment: .leading, spacing: 8) {
                        RectEditor(rect: r.rect) { update(["rect": jsonRect($0)], "Move redaction") }
                        Hint("Positions are a share of the screen, from the top left. You can also drag on the preview.")
                    }
                    .padding(.top, 6)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.text2)
                RemoveButton { model.apply([EditOperation(.removeRedaction, id: id)], label: "Remove redaction"); if model.selection == .redaction(id) { model.selection = nil } }
            }
        } else {
            Hint("This redaction is no longer in the edit.")
        }
    }

    func update(_ fields: [String: JSONValue], _ label: String) { model.updateOverlay(.updateRedaction, id: id, fields, label: label) }
}

// MARK: - Adding callouts and masks without drawing

extension EditorModel {
    /// Where the pointer was at the playhead (the likeliest thing to point at), or the screen centre.
    var pointerAtPlayhead: NormPoint {
        Activity.pointer(at: sourceTime, in: events.pointer) ?? .center
    }

    /// A callout of a sensible size near the pointer, for the time around the playhead.
    func addDefaultCallout(_ kind: Annotation.Kind) {
        let (s, e) = overlaySpan()
        let p = pointerAtPlayhead
        func clampRect(w: Double, h: Double) -> NormRect {
            NormRect(x: min(max(0, p.x - w / 2), 1 - w), y: min(max(0, p.y - h / 2), 1 - h), width: w, height: h)
        }
        let a: Annotation
        switch kind {
        case .box: a = Annotation(kind: .box, start: s, end: e, rect: clampRect(w: 0.24, h: 0.14))
        case .highlight: a = Annotation(kind: .highlight, start: s, end: e, rect: clampRect(w: 0.28, h: 0.18))
        case .arrow:
            // Point at the pointer from up and to the left (or the other side when that would leave the screen).
            let tail = NormPoint(p.x > 0.25 ? p.x - 0.16 : p.x + 0.16, p.y > 0.25 ? p.y - 0.14 : p.y + 0.14)
            a = Annotation(kind: .arrow, start: s, end: e, from: tail, to: NormPoint(min(max(p.x, 0), 1), min(max(p.y, 0), 1)))
        case .text:
            let w = 0.32
            a = Annotation(kind: .text, start: s, end: e, rect: NormRect(x: min(max(0, p.x - w / 2), 1 - w), y: min(max(0.04, p.y - 0.18), 0.85), width: w, height: 0.08), text: "Label")
        }
        addAnnotation(a)
    }

    func addDefaultRedaction() {
        let (s, e) = overlaySpan()
        let p = pointerAtPlayhead
        let w = 0.26, h = 0.07
        addRedaction(Redaction(start: s, end: e, rect: NormRect(x: min(max(0, p.x - w / 2), 1 - w), y: min(max(0, p.y - h / 2), 1 - h), width: w, height: h)))
    }
}

/// Everything drawn over the screen, with jump-to and inline editing.
struct OverlayList: View {
    let model: EditorModel

    var body: some View {
        let callouts = model.doc.timeline.annotations
        let masks = model.doc.timeline.redactions
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Callouts and masks", systemImage: "rectangle.on.rectangle")
                Menu {
                    ForEach([Annotation.Kind.text, .arrow, .box, .highlight], id: \.self) { k in
                        Button { model.addDefaultCallout(k) } label: { Label(CalloutText.title(k), systemImage: CalloutText.icon(k)) }
                    }
                    Divider()
                    Button { model.addDefaultRedaction() } label: { Label("Redaction", systemImage: "eye.slash") }
                } label: { MenuChip(title: "Add", systemImage: "plus") }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("Add at the playhead, near where the pointer was")
            }
            if callouts.isEmpty && masks.isEmpty {
                Hint("Point things out with a label, arrow, box or spotlight, or hide something private with a redaction. New ones start at the playhead; draw them on the preview or adjust them here.")
            }
            ForEach(callouts) { a in
                let sel = model.selection == .annotation(a.id)
                ListRow(selected: sel) { select(.annotation(a.id), a.start) } content: {
                    row(icon: CalloutText.icon(a.kind), title: a.kind == .text ? (a.text ?? "Label") : CalloutText.title(a.kind), start: a.start, end: a.end, tint: Theme.accent)
                }
                if sel { Card { AnnotationInspector(model: model, id: a.id) } }
            }
            ForEach(masks) { r in
                let sel = model.selection == .redaction(r.id)
                ListRow(selected: sel, tint: Theme.cut) { select(.redaction(r.id), r.start) } content: {
                    row(icon: "eye.slash", title: r.label?.isEmpty == false ? r.label! : "Redaction (\(r.mode.rawValue))", start: r.start, end: r.end, tint: Theme.cut)
                }
                if sel { Card { RedactionInspector(model: model, id: r.id) } }
            }
        }
    }

    func select(_ s: Selection, _ t: Double) {
        if model.selection == s { model.selection = nil; return }
        model.selection = s
        model.seek(source: t)
    }

    func row(icon: String, title: String, start: Double, end: Double, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(tint).frame(width: 16)
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            Text("\(Theme.time(start)) – \(Theme.time(end))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3)
        }
    }
}
