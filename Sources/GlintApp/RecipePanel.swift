import SwiftUI
import AppKit
import GlintCore
import GlintAgent

/// The demo's recipe: its scenes, what each must show, and the evidence for it. Only evidence verifies an outcome:
/// a check of the app's state, text Glint reads on screen, or a person who looked. A reported click never does.
struct RecipePanel: View {
    let model: EditorModel
    @State private var recipe: DemoRecipe?
    @State private var evidence = EvidenceLog()
    @State private var loaded = false
    @State private var editing = false
    @State private var refreshing = false
    @State private var working: String?
    @State private var error: String?
    @State private var notice: String?
    @State private var pendingBind: (ops: [EditOperation], ranges: [(scene: String, range: TimeRange)])?

    var report: RecipeReport? { recipe.map { RecipeReport.evaluate(recipe: $0, document: model.doc, evidence: evidence) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let working { WorkingRow(text: working) }
            if let error { InlineError(text: error) { self.error = nil } }
            if let notice {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.ok).padding(.top, 1)
                    Text(notice).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { self.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(Theme.text3)
                }
            }
            if let r = recipe, let rep = report {
                summary(r, rep)
                proofNote
                SectionHeader(title: "Scenes", systemImage: "list.number")
                ForEach(r.scenes) { s in
                    RecipeSceneCard(model: model, scene: s, status: rep.scenes.first { $0.scene == s.id }, items: rep.items.filter { $0.scene == s.id },
                                    evidence: evidence.records.filter { $0.scene == s.id }, onRecorded: reload)
                }
                binding(r)
                refreshSection(r)
            } else if loaded {
                emptyState
            }
        }
        .task {
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        .sheet(isPresented: $editing) {
            RecipeEditorSheet(model: model, existing: recipe) { saved in
                recipe = saved
                notice = "Saved \(saved.title), version \(saved.version)."
                reload()
            }
        }
        .sheet(isPresented: $refreshing) {
            if let r = recipe { RefreshSceneSheet(model: model, recipe: r) { reload() } }
        }
        .confirmationDialog("Split the recording into \(pendingBind?.ranges.count ?? 0) scene shot\(pendingBind?.ranges.count == 1 ? "" : "s")?",
                            isPresented: Binding(get: { pendingBind != nil }, set: { if !$0 { pendingBind = nil } }), titleVisibility: .visible) {
            Button("Split into scenes") {
                if let p = pendingBind { model.apply(p.ops, label: "Bind \(p.ranges.count) recipe scene\(p.ranges.count == 1 ? "" : "s")") }
                pendingBind = nil
                reload()
            }
            Button("Cancel", role: .cancel) { pendingBind = nil }
        } message: { Text(bindMessage) }
    }

    func reload() {
        let r = model.bundle.readRecipe()
        if r != recipe { recipe = r }
        let e = model.bundle.readEvidence()
        if e != evidence { evidence = e }
        loaded = true
    }

    // MARK: Empty

    var emptyState: some View {
        Card {
            HStack(spacing: 10) {
                IconTile(systemName: "checklist", size: 32, tint: Theme.accent)
                Text("No recipe yet").font(.system(size: 13, weight: .semibold))
            }
            Text("A recipe is the plan behind a demo: who it's for, its scenes in order, and what each scene has to show. With one, Glint can tell you which outcomes are backed by evidence and which still need a look, and you can re-record a single scene after the product changes without redoing the edit.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            Button { editing = true } label: { Label("New recipe", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
            Hint("Agents connected to Glint can write and follow recipes too.")
        }
    }

    // MARK: Summary

    func summary(_ r: DemoRecipe, _ rep: RecipeReport) -> some View {
        let (label, tint) = EvidenceText.status(rep.status)
        return Card {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(.system(size: 14, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text("Version \(r.version)\(r.audience.map { " · for \($0)" } ?? "")").font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
                Spacer(minLength: 6)
                StatusPill(text: label, tint: tint)
            }
            Text(rep.summary.prefix(1).uppercased() + rep.summary.dropFirst()).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            HStack(spacing: 6) {
                Button { verify() } label: { Label("Verify", systemImage: "text.viewfinder") }.buttonStyle(PrimaryButtonStyle()).disabled(working != nil)
                    .help("Read the text on the last frame of each scene and update the status")
                Button("Edit") { editing = true }.buttonStyle(GhostButtonStyle())
                Spacer(minLength: 0)
            }
            Hint("Verify reads the screen at the end of each scene for the text it should show. Text it can't find is left for review, never failed.")
        }
    }

    var proofNote: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(Theme.text3).padding(.top, 1)
            Text("An outcome counts as verified only with evidence: a check of the app's state, text Glint read on screen, or you looking at it. A click or keystroke someone reports is never proof that it worked.")
                .font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    func verify() {
        error = nil; notice = nil
        working = "Reading the screen at the end of each scene…"
        let m = model
        Task {
            defer { working = nil }
            do {
                let rep = try await m.service.verifyRecipe(m.bundle, author: .app)
                notice = rep.summary.prefix(1).uppercased() + rep.summary.dropFirst() + "."
                reload()
            } catch { self.error = "\(error)" }
        }
    }

    // MARK: Binding scenes to shots

    @ViewBuilder func binding(_ r: DemoRecipe) -> some View {
        let doc = model.doc
        let bound = doc.effectiveClips.contains { $0.scene != nil }
        if doc.isSingleRecording && doc.effectiveClips.count == 1 {
            let found = RecipeBinding.ranges(recipe: r, markers: doc.timeline.markers + model.events.markers, end: doc.duration)
            SectionHeader(title: "Scenes in the recording", systemImage: "flag")
            Card {
                Text("Glint finds where each scene starts from markers named scene:<id>, dropped while recording (or added here). Binding splits the recording into one shot per scene, so each scene's evidence and re-recordings stay with it.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                if found.isEmpty {
                    Hint("No scene markers yet.")
                } else {
                    ForEach(found, id: \.scene) { x in
                        HStack {
                            Text(r.scene(x.scene)?.title ?? x.scene).font(.system(size: 11.5)).lineLimit(1)
                            Spacer()
                            Text("\(Theme.time(x.range.start)) – \(Theme.time(x.range.end))").font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.text3)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Menu {
                        ForEach(r.scenes) { s in
                            Button(s.title) {
                                model.apply([EditOperation(.addMarker, time: model.sourceTime, text: "scene:\(s.id)")], label: "Mark start of “\(s.title)”")
                            }
                        }
                    } label: { MenuChip(title: "Mark scene at playhead", systemImage: "flag") }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    Button("Bind scenes") { bind() }.buttonStyle(GhostButtonStyle()).disabled(found.isEmpty)
                    Spacer(minLength: 0)
                }
            }
        } else if !bound {
            Hint("No shot is tagged with a recipe scene yet. Pick each shot's scene in the Media tab.")
        }
    }

    var bindMessage: String {
        guard let p = pendingBind, let r = recipe else { return "" }
        let lines = p.ranges.map { "\(r.scene($0.scene)?.title ?? $0.scene): \(Theme.time($0.range.start)) – \(Theme.time($0.range.end))" }
        return lines.joined(separator: "\n") + "\n\nYou can undo this."
    }

    func bind() {
        error = nil
        do { let (ops, ranges) = try model.service.recipeBindOps(model.bundle); pendingBind = (ops, ranges) } catch { self.error = "\(error)" }
    }

    // MARK: Refresh

    @ViewBuilder func refreshSection(_ r: DemoRecipe) -> some View {
        if model.doc.effectiveClips.contains(where: { $0.scene != nil }) {
            SectionHeader(title: "After the product changes", systemImage: "arrow.triangle.2.circlepath")
            Card {
                Hint("Record the scene again (mark it scene:<id> while recording), then swap it in here. Edits elsewhere stay put; the scene's evidence starts over.")
                Button { refreshing = true } label: { Label("Refresh a scene from another recording…", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(GhostButtonStyle())
            }
        }
    }
}

enum EvidenceText {
    static func status(_ s: EvidenceStatus) -> (String, Color) {
        switch s {
        case .verified: ("Verified", Theme.ok)
        case .failed: ("Failed", Theme.cut)
        case .needsReview: ("Needs review", Theme.speed)
        }
    }
    static func source(_ s: EvidenceRecord.Source) -> String {
        switch s {
        case .assertion: "Checked in the app"
        case .ocr: "Read on screen"
        case .human: "A person looked"
        case .action: "Reported action"
        case .vision: "A model's reading"
        }
    }
    static func kind(_ k: RecipeExpectation.Kind) -> String {
        switch k { case .visibleText: "Text on screen"; case .state: "App state"; case .manual: "Checked by a person" }
    }
}

// MARK: - A scene

struct RecipeSceneCard: View {
    let model: EditorModel
    let scene: RecipeScene
    let status: RecipeReport.SceneStatus?
    let items: [RecipeReport.Item]
    let evidence: [EvidenceRecord]
    let onRecorded: () -> Void
    @State private var open: String?

    var body: some View {
        let (label, tint) = status.map { $0.inEdit ? EvidenceText.status($0.status) : ("Not in the edit", Theme.text3) } ?? ("Needs review", Theme.speed)
        Card {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(scene.title).font(.system(size: 12.5, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    if let t = status?.take { Text(t == "primary" ? "From this recording" : "From another recording").font(.system(size: 10.5)).foregroundStyle(Theme.text3).help("Take \(t)") }
                }
                Spacer(minLength: 6)
                StatusPill(text: label, tint: tint)
            }
            .contentShape(Rectangle())
            .onTapGesture { jump() }
            if !scene.steps.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(scene.steps.enumerated()), id: \.offset) { i, s in
                        Text("\(i + 1). \(s)").font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if scene.expectations.isEmpty { Hint("No expected outcomes. Edit the recipe to say what this scene must show.") }
            ForEach(scene.expectations) { e in
                let item = items.first { $0.expectation == e.id }
                ExpectationRow(model: model, scene: scene, expectation: e, item: item, records: evidence.filter { $0.expectation == e.id },
                               open: open == e.id, toggle: { open = open == e.id ? nil : e.id }, onRecorded: onRecorded)
            }
        }
    }

    func jump() {
        if let seg = model.clipLayout.segments.first(where: { $0.clip.scene == scene.id }) { model.seek(source: seg.start); model.selection = .clip(seg.clip.id) }
    }
}

struct ExpectationRow: View {
    let model: EditorModel
    let scene: RecipeScene
    let expectation: RecipeExpectation
    let item: RecipeReport.Item?
    let records: [EvidenceRecord]
    let open: Bool
    let toggle: () -> Void
    let onRecorded: () -> Void
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        let st = item?.status ?? .needsReview
        let (label, tint) = EvidenceText.status(st)
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: st == .verified ? "checkmark.circle.fill" : st == .failed ? "xmark.circle.fill" : "questionmark.circle")
                    .font(.system(size: 11.5)).foregroundStyle(tint).padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(expectation.description).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Tag(EvidenceText.kind(expectation.kind))
                        if !expectation.required { Tag("Optional") }
                        Text(label).font(.system(size: 10.5)).foregroundStyle(tint)
                    }
                    if let r = item?.reason, st != .verified || open { Text(r).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(open ? nil : 2) }
                }
                Spacer(minLength: 0)
                Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.text3).padding(.top, 3)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if open { detail }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(open ? 0.04 : 0.02)))
    }

    @ViewBuilder var detail: some View {
        let current = Set(item?.evidence ?? [])
        if records.isEmpty { Hint("No evidence yet.") }
        ForEach(records.reversed()) { r in EvidenceRow(model: model, record: r, current: current.contains(r.id)) }
        VStack(alignment: .leading, spacing: 6) {
            if expectation.kind == .visibleText, let t = expectation.text { Hint("Glint looks for “\(t)” on screen when you press Verify.") }
            TextField(expectation.kind == .manual ? "What you saw" : "What you saw, or what went wrong", text: $note, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 11.5)).lineLimit(1...3)
                .padding(6).background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline))
            HStack(spacing: 6) {
                Button { record(.verified) } label: { Label("Mark verified by me", systemImage: "checkmark") }.buttonStyle(GhostButtonStyle())
                Button(role: .destructive) { record(.failed) } label: { Label("Mark failed", systemImage: "xmark") }.buttonStyle(GhostButtonStyle())
                Spacer(minLength: 0)
            }
            .controlSize(.small).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Hint("Watch the scene first. Your note is kept with the evidence.")
            if let error { InlineError(text: error) { self.error = nil } }
        }
        .padding(.top, 2)
    }

    func record(_ status: EvidenceStatus) {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        error = nil
        do {
            _ = try model.service.recordEvidence(model.bundle, EvidenceRecord(
                scene: scene.id, expectation: expectation.id, status: status, source: .human,
                detail: status == .verified ? "Checked by a person in Glint" : n, observed: status == .verified ? n : nil,
                time: model.sourceTime, author: .app))
            note = ""
            onRecorded()
        } catch { self.error = "\(error)" }
    }
}

struct EvidenceRow: View {
    let model: EditorModel
    let record: EvidenceRecord
    let current: Bool

    var body: some View {
        let (label, tint) = EvidenceText.status(record.status)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(EvidenceText.source(record.source)).font(.system(size: 11, weight: .semibold))
                Text(label).font(.system(size: 10.5)).foregroundStyle(tint)
                Spacer(minLength: 4)
                Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(Theme.text3)
            }
            Text(record.detail).font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            if let o = record.observed, !o.isEmpty { Text("Saw: \(o)").font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
            if !record.frames.isEmpty {
                HStack(spacing: 6) {
                    ForEach(record.frames, id: \.self) { f in
                        if let img = NSImage(contentsOf: model.bundle.resolve(f)) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 84, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline))
                                .onTapGesture { NSWorkspace.shared.open(model.bundle.resolve(f)) }
                                .help("Open the frame")
                        }
                    }
                }
            }
            ForEach(record.notes, id: \.self) { n in
                Text(n).font(.system(size: 10.5)).foregroundStyle(Theme.speed).fixedSize(horizontal: false, vertical: true)
            }
            if !current { Text("From a recording that isn't in the edit any more, so it doesn't count.").font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 2) {
                    Text("By \(record.author.description)").textSelection(.enabled)
                    if let t = record.take { Text("Take \(t)").textSelection(.enabled) }
                    if let t = record.time { Text("At \(Theme.time(t, precise: true)) in the video") }
                    Text("Record \(record.id)").textSelection(.enabled)
                }
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.text3).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.well))
        .opacity(current ? 1 : 0.6)
    }
}

// MARK: - Editing the recipe

struct RecipeEditorSheet: View {
    let model: EditorModel
    let existing: DemoRecipe?
    let onSaved: (DemoRecipe) -> Void
    @Environment(\.dismiss) private var dismiss

    struct DraftExpectation: Identifiable {
        let uid = UUID()
        var eid: String = ""
        var kind: RecipeExpectation.Kind = .visibleText
        var description = ""
        var text = ""
        var required = true
        var id: UUID { uid }
    }
    struct DraftScene: Identifiable {
        let uid = UUID()
        var sceneID: String = ""
        var idEdited = false
        var saved = false
        var title = ""
        var steps = ""
        var expectations: [DraftExpectation] = []
        var id: UUID { uid }
    }

    @State private var title = ""
    @State private var audience = ""
    @State private var intent = ""
    @State private var scenes: [DraftScene] = []
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                IconTile(systemName: "checklist", size: 36, tint: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "New recipe" : "Edit recipe").font(.system(size: 17, weight: .semibold))
                    Text(existing.map { "Version \($0.version). Saving changes makes a new version." } ?? "The plan for this demo: scenes in order and what each must show.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            .padding(22)
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    field("Title", "e.g. Inviting a teammate", $title)
                    field("Who it's for", "e.g. Admins setting up a new workspace", $audience)
                    field("What they should come away with (optional)", "e.g. Inviting takes one step", $intent)
                    SectionHeader(title: "Scenes", systemImage: "list.number")
                    ForEach($scenes) { $s in sceneEditor($s) }
                    Button { scenes.append(DraftScene(expectations: [DraftExpectation()])) } label: { Label("Add scene", systemImage: "plus") }
                        .buttonStyle(GhostButtonStyle())
                }
                .padding(22)
            }
            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 8) {
                if let error { InlineError(text: error) { self.error = nil } }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle())
                    Button { save() } label: { Text(existing == nil ? "Save recipe" : "Save new version") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty || scenes.isEmpty)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(width: 600, height: 680)
        .background(Theme.panel)
        .onAppear(perform: load)
    }

    func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text2)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder).font(.system(size: 12.5))
        }
    }

    @ViewBuilder func sceneEditor(_ s: Binding<DraftScene>) -> some View {
        let index = scenes.firstIndex { $0.uid == s.wrappedValue.uid } ?? 0
        Card {
            HStack {
                Text("Scene \(index + 1)").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
                Spacer()
                Button { move(index, -1) } label: { Image(systemName: "arrow.up") }.buttonStyle(MiniButtonStyle()).disabled(index == 0).help("Move earlier")
                Button { move(index, 1) } label: { Image(systemName: "arrow.down") }.buttonStyle(MiniButtonStyle()).disabled(index >= scenes.count - 1).help("Move later")
                Button { scenes.removeAll { $0.uid == s.wrappedValue.uid } } label: { Image(systemName: "trash").font(.system(size: 9.5)) }.buttonStyle(MiniButtonStyle()).help("Remove scene")
            }
            TextField("Scene title, e.g. Send the invite", text: s.title).textFieldStyle(.roundedBorder).font(.system(size: 12.5))
                .onChange(of: s.wrappedValue.title) { _, t in
                    if !s.wrappedValue.idEdited && !s.wrappedValue.saved { s.wrappedValue.sceneID = uniqueSceneID(t.slug, excluding: s.wrappedValue.uid) }
                }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("scene-id", text: Binding(get: { s.wrappedValue.sceneID }, set: { s.wrappedValue.sceneID = $0; s.wrappedValue.idEdited = true }))
                        .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    Hint(s.wrappedValue.saved
                         ? "Recordings and evidence refer to this ID. Changing it disconnects them from this scene."
                         : "Made from the title. Mark the scene while recording with a marker named scene:\(s.wrappedValue.sceneID.isEmpty ? "<id>" : s.wrappedValue.sceneID).")
                }
                .padding(.top, 4)
            } label: {
                Text("Scene ID: \(s.wrappedValue.sceneID.isEmpty ? "(from the title)" : s.wrappedValue.sceneID)").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Steps, one per line").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text2)
                TextField("Open Settings › Members\nClick Invite\nType bo@example.com and press Send", text: s.steps, axis: .vertical)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12)).lineLimit(2...6)
            }
            Text("What this scene must show").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text2)
            ForEach(s.expectations) { $e in expectationEditor($e, scene: s) }
            Button { s.wrappedValue.expectations.append(DraftExpectation()) } label: { Label("Add an outcome", systemImage: "plus") }.buttonStyle(LinkButtonStyle())
        }
    }

    @ViewBuilder func expectationEditor(_ e: Binding<DraftExpectation>, scene s: Binding<DraftScene>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Picker("", selection: e.kind) {
                    Text("Text on screen").tag(RecipeExpectation.Kind.visibleText)
                    Text("App state").tag(RecipeExpectation.Kind.state)
                    Text("Checked by a person").tag(RecipeExpectation.Kind.manual)
                }
                .labelsHidden().controlSize(.small).frame(width: 170)
                Toggle("Required", isOn: e.required).toggleStyle(.checkbox).controlSize(.small)
                Spacer()
                Button { s.wrappedValue.expectations.removeAll { $0.uid == e.wrappedValue.uid } } label: { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }
                    .buttonStyle(MiniButtonStyle()).help("Remove outcome")
            }
            TextField("Outcome, e.g. The invite shows as pending", text: e.description).textFieldStyle(.roundedBorder).font(.system(size: 12))
            if e.wrappedValue.kind == .visibleText {
                TextField("Exact text to find on screen, e.g. Invitation sent", text: e.text).textFieldStyle(.roundedBorder).font(.system(size: 12))
            }
            Hint(e.wrappedValue.kind == .visibleText ? "Glint reads the last frame of the scene for this text."
                 : e.wrappedValue.kind == .state ? "Confirmed by a check of the app (an agent reports it), or by you."
                 : "You confirm this yourself after watching the scene.")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.well))
    }

    func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard scenes.indices.contains(i), scenes.indices.contains(j) else { return }
        scenes.swapAt(i, j)
    }

    func uniqueSceneID(_ base: String, excluding uid: UUID) -> String {
        let b = base.isEmpty ? "scene" : base
        let taken = Set(scenes.filter { $0.uid != uid }.map(\.sceneID))
        var id = b, n = 2
        while taken.contains(id) { id = "\(b)-\(n)"; n += 1 }
        return id
    }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let r = existing else { scenes = [DraftScene(expectations: [DraftExpectation()])]; return }
        title = r.title; audience = r.audience ?? ""; intent = r.intent ?? ""
        scenes = r.scenes.map { s in
            DraftScene(sceneID: s.id, idEdited: true, saved: true, title: s.title, steps: s.steps.joined(separator: "\n"),
                       expectations: s.expectations.map { e in
                           DraftExpectation(eid: e.id, kind: e.kind, description: e.description, text: e.text ?? "", required: e.required)
                       })
        }
    }

    func save() {
        error = nil
        var used = Set<String>()
        var out: [RecipeScene] = []
        for (i, d) in scenes.enumerated() {
            let t = d.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { error = "Scene \(i + 1) needs a title."; return }
            var sid = d.sceneID.trimmingCharacters(in: .whitespaces)
            if sid.isEmpty { sid = t.slug.isEmpty ? "scene-\(i + 1)" : t.slug }
            guard used.insert(sid).inserted else { error = "Two scenes have the ID “\(sid)”. Give one a different title or ID."; return }
            var eids = Set<String>()
            var exps: [RecipeExpectation] = []
            for (k, e) in d.expectations.enumerated() {
                let desc = e.description.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = e.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if desc.isEmpty && text.isEmpty { continue }
                if e.kind == .visibleText && text.isEmpty { error = "“\(t)”: say which text should be on screen for “\(desc)”."; return }
                var eid = e.eid.isEmpty ? (desc.isEmpty ? text : desc).slug : e.eid
                if eid.isEmpty { eid = "outcome-\(k + 1)" }
                var n = 2
                let base = eid
                while eids.contains(eid) { eid = "\(base)-\(n)"; n += 1 }
                eids.insert(eid)
                exps.append(RecipeExpectation(id: eid, description: desc.isEmpty ? "Shows “\(text)”" : desc, kind: e.kind, text: e.kind == .visibleText ? text : nil, required: e.required))
            }
            // Keep what the form doesn't show (preconditions, narration brief, intent) from the saved scene.
            let prev = existing?.scene(sid)
            out.append(RecipeScene(id: sid, title: t, intent: prev?.intent, preconditions: prev?.preconditions ?? [],
                                   steps: d.steps.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                                   expectations: exps, narration: prev?.narration))
        }
        var r = existing ?? DemoRecipe(title: "", scenes: [])
        r.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        r.audience = audience.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : audience.trimmingCharacters(in: .whitespacesAndNewlines)
        r.intent = intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : intent.trimmingCharacters(in: .whitespacesAndNewlines)
        r.scenes = out
        do {
            let saved = try model.service.saveRecipe(model.bundle, r)
            onSaved(saved)
            dismiss()
        } catch { self.error = "\(error)" }
    }
}

// MARK: - Refreshing a scene from another recording

struct RefreshSceneSheet: View {
    let model: EditorModel
    let recipe: DemoRecipe
    let onDone: () -> Void
    /// Scene to start on (a "Re-record" button on a scene card).
    var initialScene: String? = nil
    @Environment(\.dismiss) private var dismiss

    struct Candidate: Identifiable, Hashable { var url: URL; var name: String; var created: Date; var duration: Double; var id: String { url.path } }

    @State private var sceneID = ""
    @State private var candidates: [Candidate] = []
    @State private var loading = true
    @State private var chosen: Candidate?
    @State private var useMarkers = true
    @State private var start = 0.0
    @State private var end = 5.0
    @State private var working = false
    @State private var error: String?
    @State private var result: SceneRefreshResult?

    var scenesInEdit: [RecipeScene] { recipe.scenes.filter { s in model.doc.effectiveClips.contains { $0.scene == s.id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemName: "arrow.triangle.2.circlepath", size: 36, tint: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refresh a scene").font(.system(size: 17, weight: .semibold))
                    Text("Swap one scene for the same scene from a newer recording.").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            if let result { resultView(result) } else { form }
            if let error { InlineError(text: error) { self.error = nil } }
            HStack {
                if working { WorkingRow(text: "Copying the recording into this project…") }
                Spacer()
                if result != nil {
                    Button("Done") { onDone(); dismiss() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Cancel") { dismiss() }.buttonStyle(GhostButtonStyle()).disabled(working)
                    Button("Refresh scene") { run() }.buttonStyle(PrimaryButtonStyle())
                        .disabled(working || chosen == nil || sceneID.isEmpty || (!useMarkers && end - start < 0.1))
                }
            }
        }
        .padding(22).frame(width: 560)
        .background(Theme.panel)
        .task { await loadCandidates() }
        .onAppear { if sceneID.isEmpty { sceneID = initialScene ?? scenesInEdit.first?.id ?? "" } }
    }

    @ViewBuilder var form: some View {
        Picker("Scene", selection: $sceneID) {
            ForEach(scenesInEdit) { s in Text(s.title).tag(s.id) }
        }
        .controlSize(.small)
        VStack(alignment: .leading, spacing: 4) {
            Text("New recording").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text2)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if loading { WorkingRow(text: "Finding recordings…") }
                    else if candidates.isEmpty { Hint("No other recordings in your projects folder. Record the scene again first.") }
                    ForEach(candidates) { c in
                        ListRow(selected: chosen == c) { chosen = c; end = min(c.duration, max(end, 0.1)) } content: {
                            HStack {
                                Text(c.name).font(.system(size: 12)).lineLimit(1)
                                Spacer()
                                Text("\(Theme.time(c.duration)) · \(c.created.formatted(.relative(presentation: .named)))").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: 180)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline))
        }
        Toggle("Find the scene from its scene:\(sceneID.isEmpty ? "<id>" : sceneID) marker", isOn: $useMarkers).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
        if !useMarkers, let c = chosen {
            TimeStepper(label: "Scene starts at", value: start, range: 0...max(0, c.duration - 0.1)) { start = $0; if end < start + 0.1 { end = min(c.duration, start + 0.1) } }
            TimeStepper(label: "Scene ends at", value: end, range: min(c.duration, start + 0.1)...c.duration) { end = $0 }
        }
        Hint("Edits elsewhere stay where they are. Your own callouts inside the scene are placed proportionally; automatic ones are dropped. The scene's evidence starts over, so verify it again. You can undo the swap.")
    }

    func resultView(_ r: SceneRefreshResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Swapped in \(Theme.time(r.range.start)) – \(Theme.time(r.range.end)) of the new recording", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.ok)
            if !r.dropped.isEmpty { Text("\(r.dropped.count) automatic edit\(r.dropped.count == 1 ? "" : "s") on the old scene were removed.").font(.system(size: 11.5)).foregroundStyle(Theme.text2) }
            if !r.retimedProportionally.isEmpty { Text("\(r.retimedProportionally.count) of your edits were placed proportionally. Check them.").font(.system(size: 11.5)).foregroundStyle(Theme.speed) }
            if r.importedEvidence > 0 { Text("Brought \(r.importedEvidence) evidence record\(r.importedEvidence == 1 ? "" : "s") from the new recording.").font(.system(size: 11.5)).foregroundStyle(Theme.text2) }
            ForEach(r.notes, id: \.self) { n in Text(n.replacingOccurrences(of: "glint_fit_narration", with: "Re-fit picture in the Voice tab")).font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
        }
    }

    func loadCandidates() async {
        let s = model.service
        let me = model.bundle.url.standardizedFileURL
        let list: [Candidate] = await Task.detached {
            s.listProjectURLs().filter { $0.standardizedFileURL != me }.prefix(60).compactMap { u in
                guard let d = try? ProjectBundle(url: u).readDocument() else { return nil }
                return Candidate(url: u, name: d.name, created: d.createdAt, duration: d.media.duration)
            }
        }.value
        candidates = list
        loading = false
    }

    func run() {
        guard let c = chosen else { return }
        error = nil
        working = true
        let s = model.service, b = model.bundle, scene = sceneID, rev = model.doc.revision
        let range: TimeRange? = useMarkers ? nil : TimeRange(start, end)
        Task {
            defer { working = false }
            do {
                let r = try await Task.detached {
                    try s.refreshScene(b, scene: scene, take: ProjectBundle(url: c.url), range: range, author: .app, expectedRevision: rev, apply: true)
                }.value
                result = r
            } catch { self.error = "\(error)" }
        }
    }
}
