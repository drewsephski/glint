import SwiftUI
import AppKit
import GlintCore
import GlintAgent
import GlintAnalysis

/// The guided pass: say what you want (a tighter take, or a narrated demo), how long, and what it must show; Glint
/// runs the autopilot as a resumable job. The person follows it scene by scene: each card shows the scene's frame
/// and line, can be edited, locked so no automatic pass touches it, or re-recorded. Approvals for anything that
/// leaves the Mac are asked for here, and the run continues from where it paused.
struct PolishSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss

    enum Goal: String, CaseIterable, Identifiable {
        case polish, demo
        var id: String { rawValue }
        var title: String { self == .polish ? "Polish this recording" : "Create a demo" }
        var detail: String {
            self == .polish ? "Tightens pauses and idle stretches, adds zooms on what you click, and captions what you say."
                : "Everything in Polish, plus a script written for each scene and a voiceover fitted to the picture."
        }
    }

    @AppStorage("GlintPolishGoal") private var goalRaw = Goal.polish.rawValue
    @State private var useTarget = false
    @State private var target: Double = 60
    @State private var brief = ""
    @State private var mustShow = ""
    @State private var captions = true
    @State private var exportWhenDone = false
    @State private var voiceID: String?
    @State private var jobID: String?
    @State private var job: Job?
    @State private var showSetup = true
    @State private var error: String?
    @State private var reRecord: String?

    var goal: Goal { Goal(rawValue: goalRaw) ?? .polish }
    var store: JobStore { JobStore(bundle: model.bundle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if showSetup || job == nil { setup } else if let job { progress(job) }
                    if let error { InlineError(text: error) { self.error = nil } }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 560)
            footer
        }
        .padding(22).frame(width: 640)
        .background(Theme.panel)
        .onAppear(perform: restore)
        .task(id: jobID) {
            guard let jobID else { return }
            while !Task.isCancelled {
                job = try? store.get(jobID)
                try? await Task.sleep(nanoseconds: (job?.status.isActive ?? false) ? 600_000_000 : 1_500_000_000)
            }
        }
        .task(id: model.voiceCredentialsID) { if goal == .demo { await model.loadVoices() } }
        .sheet(isPresented: Binding(get: { reRecord != nil }, set: { if !$0 { reRecord = nil } })) {
            if let r = model.bundle.readRecipe() { RefreshSceneSheet(model: model, recipe: r, onDone: {}, initialScene: reRecord) }
        }
    }

    // MARK: Header and footer

    var header: some View {
        HStack(spacing: 12) {
            IconTile(systemName: "film.stack", size: 36, tint: Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.map { JobText.title($0) == "Polish" ? Goal.polish.title : Goal.demo.title } ?? goal.title)
                    .font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                Text(showSetup || job == nil ? "Every change is a separate step you can undo." : (job.map(Autopilot.statusLine) ?? ""))
                    .font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Spacer()
            if let job, !showSetup { let (t, c) = JobText.status(job.status); StatusPill(text: t, tint: c) }
        }
    }

    var footer: some View {
        HStack(spacing: 8) {
            if job != nil {
                if showSetup { Button("Back to the run") { showSetup = false }.buttonStyle(LinkButtonStyle()) }
                else if !(job?.status.isActive ?? false) { Button("Start over") { showSetup = true }.buttonStyle(LinkButtonStyle()) }
            }
            Spacer()
            Button("Close") { dismiss() }.buttonStyle(GhostButtonStyle())
                .help("The run keeps going if you close this. Follow it in Activity.")
            if showSetup || job == nil {
                Button { start() } label: { Label("Start", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                    .disabled(job?.status.isActive ?? false)
            } else if let job {
                if job.status == .waitingApproval, decision(job) != .pending {
                    Button { resume() } label: { Label("Continue", systemImage: "play.fill") }.buttonStyle(PrimaryButtonStyle())
                } else if [.failed, .interrupted, .cancelled].contains(job.status) {
                    Button { resume() } label: { Label("Continue", systemImage: "arrow.clockwise") }.buttonStyle(PrimaryButtonStyle())
                        .help("Continues from the first unfinished stage; finished stages are kept")
                } else if [.succeeded, .needsReview].contains(job.status), scriptChanged(job) {
                    Button { resume() } label: { Label("Re-voice changed lines", systemImage: "waveform") }.buttonStyle(PrimaryButtonStyle())
                        .help("Only the lines you changed are synthesized again")
                }
            }
        }
    }

    // MARK: Setup

    @ViewBuilder var setup: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Goal.allCases) { g in
                let on = g == goal
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 15)).foregroundStyle(on ? Theme.accent : Theme.text3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(g.title).font(.system(size: 13, weight: .medium))
                        Text(g.detail).font(.system(size: 11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.accent.opacity(0.1) : Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? Theme.accent.opacity(0.35) : Theme.hairline))
                .contentShape(Rectangle())
                .onTapGesture { goalRaw = g.rawValue }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }

        SectionHeader(title: "Length", systemImage: "timer")
        HStack(spacing: 10) {
            Toggle("Aim for", isOn: $useTarget).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
            Slider(value: $target, in: 10...300, step: 5).disabled(!useTarget).frame(maxWidth: 240)
            Text(Self.clock(target)).font(.system(size: 12).monospacedDigit()).foregroundStyle(useTarget ? Theme.text : Theme.text3).frame(width: 44, alignment: .leading)
            Spacer(minLength: 0)
        }
        Hint(useTarget ? "Now \(Self.clock(model.map.outputDuration)). Cuts tighten (never into speech) until it fits\(goal == .demo ? ", and the script is written to the length" : ""). If it can't fit, you'll be told how long it needs."
             : "Now \(Self.clock(model.map.outputDuration)). Without a goal, only dead air and idle stretches are trimmed.")

        if goal == .demo {
            SectionHeader(title: "What it's about", systemImage: "text.alignleft")
            TextField("The product, and who the demo is for", text: $brief, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            TextField("Moments it must show, one per line (optional)", text: $mustShow, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...5)
            HStack(spacing: 8) {
                Text("Voice").font(.system(size: 12)).foregroundStyle(Theme.text2)
                Picker("", selection: Binding(get: { voiceID ?? model.doc.style.voice.voiceID ?? "" }, set: { voiceID = $0 })) {
                    if model.voices.isEmpty { Text(model.voicesLoaded ? "Project voice" : "Loading voices…").tag(voiceID ?? model.doc.style.voice.voiceID ?? "") }
                    ForEach(model.voices) { v in Text(v.name).tag(v.id) }
                }.labelsHidden().frame(maxWidth: 240)
                Spacer(minLength: 0)
            }
            Hint("Writing the script sends each scene's frame and on-screen text to \(model.narrationWriterName ?? "the script writer"); the voice is made by ElevenLabs. Glint asks before each, and privacy masks are applied to the frames first.")
        }

        SectionHeader(title: "Finish", systemImage: "checkmark.seal")
        Toggle("Captions when there's speech", isOn: $captions).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
        Toggle("Render the current composition when it's done", isOn: $exportWhenDone).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
        if model.bundle.readRecipe() == nil {
            Hint("Without a recipe the run ends in Needs review: nothing has checked what the video shows. Add one in the Recipe tab.")
        }
    }

    // MARK: Progress

    @ViewBuilder func progress(_ j: Job) -> some View {
        stageStrip(j)
        if j.status.isActive { ProgressView(value: min(1, max(0, j.progress))).tint(Theme.accent) }
        if j.status == .waitingApproval, let w = j.stages.first(where: { $0.status == .waitingApproval }), let id = w.approvalID,
           let req = model.service.approvals.get(id) {
            approvalCard(req, stage: w.name)
        }
        if !j.review.isEmpty {
            SectionHeader(title: "To look at", systemImage: "exclamationmark.bubble")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(j.review.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 4)).foregroundStyle(Theme.speed).padding(.top, 6)
                        Text(r).font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        if let sb = model.storyboard, !sb.scenes.isEmpty {
            SectionHeader(title: "Scenes", systemImage: "rectangle.stack")
            if j.params["narrate"]?.boolValue == true {
                Hint("Edit a line and Glint re-voices just that line. Lock a scene when it's right: no automatic pass or agent changes its line.")
            }
            ForEach(sb.scenes) { s in
                PolishSceneCard(model: model, scene: s, index: (sb.scenes.firstIndex(of: s) ?? 0) + 1,
                                canReRecord: model.bundle.readRecipe()?.scene(s.id) != nil, busy: j.status.isActive) { reRecord = s.id }
            }
        }
    }

    func stageStrip(_ j: Job) -> some View {
        let shown = j.stages.filter { st in st.status != .skipped || st.result?["status"]?.stringValue != "skipped" }
        return FlowRow(spacing: 6) {
            ForEach(shown, id: \.name) { st in
                let (icon, tint) = JobText.stageIcon(st.status)
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 10)).foregroundStyle(tint)
                    Text(StageText.title(st.name)).font(.system(size: 11)).foregroundStyle(st.status == .pending ? Theme.text3 : Theme.text2)
                }
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.04)))
                .help(st.detail ?? st.status.rawValue)
                .accessibilityElement(children: .combine)
            }
        }
    }

    func approvalCard(_ r: ApprovalRequest, stage: String) -> some View {
        Card {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill").font(.system(size: 14)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(StageText.title(stage)) needs your OK").font(.system(size: 12.5, weight: .semibold))
                    Text(r.summary).font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    if r.status != .pending { Text(r.status == .approved ? "Approved. Continue to go on." : "This request is \(r.status.rawValue).").font(.system(size: 11)).foregroundStyle(Theme.text3) }
                }
                Spacer(minLength: 0)
            }
            if r.status == .pending {
                HStack {
                    Spacer()
                    Button("Don't send") { decide(r, approve: false) }.buttonStyle(GhostButtonStyle())
                    Button("Approve and continue") { decide(r, approve: true) }.buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }

    // MARK: Actions

    func restore() {
        guard jobID == nil, let last = store.list().first(where: { $0.kind == .autopilot && $0.status != .cancelled }) else { return }
        jobID = last.id; job = last; showSetup = false
        let p = last.params
        goalRaw = p["narrate"]?.boolValue == true ? Goal.demo.rawValue : Goal.polish.rawValue
        if let t = p["target_duration"]?.doubleValue { useTarget = true; target = t }
        brief = p["brief"]?.stringValue ?? brief
        captions = p["captions"]?.boolValue ?? true
        exportWhenDone = !(p["variants"]?.arrayValue ?? []).isEmpty
        voiceID = p["voice"]?.stringValue
    }

    func start() {
        error = nil
        var fullBrief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let musts = mustShow.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !musts.isEmpty { fullBrief += (fullBrief.isEmpty ? "" : "\n") + "The video must show: " + musts.joined(separator: "; ") + "." }
        // Captions on means "when there's speech" (the autopilot default); only an explicit off is passed, since
        // captions: true would make them required and fail a run on a recording without a voice.
        var args: [String: JSONValue] = ["narrate": .bool(goal == .demo), "variants": .array(exportWhenDone ? [.string("current")] : [])]
        if !captions { args["captions"] = .bool(false) }
        if useTarget { args["target_duration"] = .number(target) }
        if goal == .demo {
            if !fullBrief.isEmpty { args["brief"] = .string(fullBrief) }
            if let v = voiceID, !v.isEmpty { args["voice"] = .string(v) }
        }
        do {
            // Keep the person's goals with the recipe (they don't change its version or evidence).
            if var r = model.bundle.readRecipe() {
                r.targetDuration = useTarget ? target : nil
                r.mustShow = musts.isEmpty ? nil : musts
                _ = try model.service.saveRecipe(model.bundle, r)
            }
            let (j, _) = try JobRunner.createAutopilot(model.service, model.bundle, params: Autopilot.params(.object(args)), idempotencyKey: nil,
                                                       expectedRevision: model.doc.revision, author: .app)
            JobLauncher.shared.start(model.service, model.bundle, j.id)
            jobID = j.id; job = j; showSetup = false
        } catch { self.error = "\(error)" }
    }

    func resume() {
        guard let id = jobID else { return }
        error = nil
        do { try JobLauncher.shared.retry(model.service, model.bundle, id); job = try store.get(id) } catch { self.error = "\(error)" }
    }

    func decide(_ r: ApprovalRequest, approve: Bool) {
        do {
            _ = try model.service.approvals.decide(r.id, approve: approve, by: NSUserName())
            // Approved: go on. Denied: the run settles with that stage failed, keeping everything before it.
            resume()
        } catch { self.error = "\(error)" }
    }

    func decision(_ j: Job) -> ApprovalRequest.Status? {
        j.stages.first { $0.status == .waitingApproval }?.approvalID.flatMap { model.service.approvals.get($0)?.status }
    }

    /// The script differs from what the finished voiceover spoke.
    func scriptChanged(_ j: Job) -> Bool {
        guard let st = j.stage("voiceover"), st.status == .done, st.result?["status"]?.stringValue == "ok",
              let spoken = st.inputs?["script"]?.stringValue else { return false }
        _ = model.storyboard // re-evaluate when the storyboard changes
        return spoken != Autopilot.scriptHash(model.bundle, voice: j.params["voice"]?.stringValue)
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// One scene of the run: its frame, where it plays in the edit, its line (editable unless locked), and actions.
struct PolishSceneCard: View {
    let model: EditorModel
    let scene: GlintCore.Scene
    let index: Int
    let canReRecord: Bool
    let busy: Bool
    let onReRecord: () -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let locked = scene.isLocked
        let span = model.map.outputSpan(forSource: scene.range)
        Card {
            HStack(alignment: .top, spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("\(index). \(scene.title)").font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                        Spacer(minLength: 4)
                        Text(span.map { "\(PolishSheet.clock($0.start))–\(PolishSheet.clock($0.end))" } ?? "Cut").font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.text3)
                            .help(span == nil ? "This scene is cut from the edited video" : "Where it plays in the edited video")
                        if locked { StatusPill(text: "Locked", tint: Theme.accent) }
                    }
                    if scene.narration != nil || !locked {
                        TextField("No line for this scene", text: $draft, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(1...4)
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(locked ? 0.02 : 0.045)))
                            .disabled(locked || busy)
                            .focused($focused)
                            .onSubmit(commit)
                            .onChange(of: focused) { _, f in if !f { commit() } }
                            .accessibilityLabel("Line for scene \(index)")
                    }
                    HStack(spacing: 6) {
                        Button { model.seek(source: scene.start) } label: { Label("Show", systemImage: "play.rectangle") }
                        Button { model.setSceneLocked(scene.id, !locked) } label: {
                            Label(locked ? "Unlock" : "Lock scene", systemImage: locked ? "lock.open" : "lock")
                        }
                        .help(locked ? "Let automatic passes change this line again" : "Keep this line exactly as it is: automatic passes and agents won't change it")
                        if canReRecord {
                            Button { onReRecord() } label: { Label("Re-record…", systemImage: "record.circle") }
                                .help("Replace this scene with a new take; every other edit is kept")
                        }
                        Spacer(minLength: 0)
                    }
                    .buttonStyle(GhostButtonStyle()).controlSize(.small)
                }
            }
        }
        .onAppear { draft = scene.narration ?? "" }
        .onChange(of: scene.narration) { _, n in if !focused { draft = n ?? "" } }
    }

    @ViewBuilder var thumbnail: some View {
        let image = scene.frame.flatMap { NSImage(contentsOf: model.bundle.resolve($0)) }
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.black.opacity(0.35))
            if let image { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(Theme.text3) }
        }
        .frame(width: 112, height: 70)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    func commit() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !scene.isLocked, t != (scene.narration ?? "") else { return }
        model.setNarration(scene.id, t)
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}
