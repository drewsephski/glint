import SwiftUI
import GlintCore
import GlintRender
import GlintAgent
import GlintAnalysis

// Durable jobs (renders and production checks) as people see them: what's running, how far along it is, each
// stage, what needs a look, and the files it made. Jobs live in the project, so they survive closing the sheet,
// the editor or the app (a job whose process went away shows as interrupted and can be retried).

/// Runs jobs in this process, at most once each.
@MainActor
final class JobLauncher {
    static let shared = JobLauncher()
    private(set) var running = Set<String>()

    func isRunningHere(_ id: String) -> Bool { running.contains(id) }

    func start(_ service: GlintService, _ bundle: ProjectBundle, _ id: String) {
        guard running.insert(id).inserted else { return }
        Task.detached(priority: .userInitiated) {
            _ = await JobRunner.run(service, bundle, id)
            await MainActor.run { _ = JobLauncher.shared.running.remove(id) }
        }
    }

    func retry(_ service: GlintService, _ bundle: ProjectBundle, _ id: String) throws {
        _ = try JobRunner.prepareRetry(bundle, id)
        start(service, bundle, id)
    }
}

enum JobText {
    static func status(_ s: Job.Status) -> (String, Color) {
        switch s {
        case .queued: ("Waiting", Theme.text3)
        case .running: ("Running", Theme.accent)
        case .succeeded: ("Done", Theme.ok)
        case .failed: ("Failed", Theme.cut)
        case .cancelled: ("Cancelled", Theme.text3)
        case .interrupted: ("Interrupted", Theme.speed)
        case .needsReview: ("Needs review", Theme.speed)
        }
    }

    static func variantName(_ v: String) -> String {
        switch v {
        case "landscape": "Landscape 1080p"
        case "landscape-4k": "Landscape 4K"
        case "square": "Square"
        case "portrait": "Vertical"
        case "gif": "GIF"
        case "prores": "ProRes"
        case "preview": "Draft 720p"
        default: v
        }
    }

    static func stage(_ name: String) -> String {
        if name.hasPrefix("render:") { return "Render \(variantName(String(name.dropFirst(7))))" }
        switch name {
        case "quality": return "Check the edit"
        case "repair": return "Safe automatic fixes"
        case "inspect": return "Inspect the rendered file"
        case "evidence": return "Check the recipe's evidence"
        default: return name
        }
    }

    static func title(_ j: Job) -> String {
        switch j.kind {
        case .production: return "Production check"
        case .render:
            let vs = j.params["variants"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return vs.isEmpty ? "Render" : "Render " + vs.map(variantName).joined(separator: ", ")
        }
    }

    static func stageIcon(_ s: JobStage.Status) -> (String, Color) {
        switch s {
        case .pending: ("circle", Theme.text3)
        case .running: ("circle.dotted", Theme.accent)
        case .done: ("checkmark.circle.fill", Theme.ok)
        case .failed: ("xmark.circle.fill", Theme.cut)
        case .skipped: ("minus.circle", Theme.text3)
        case .cancelled: ("stop.circle", Theme.text3)
        }
    }
}

/// One job, live: polls its file twice a second while it isn't finished.
struct JobDetailView: View {
    let model: EditorModel
    let jobID: String
    var compact = false
    @State private var job: Job?
    @State private var error: String?

    var store: JobStore { JobStore(bundle: model.bundle) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let j = job { content(j) } else if let error { InlineError(text: error) } else { WorkingRow(text: "Loading…") }
        }
        .task(id: jobID) {
            while !Task.isCancelled {
                do { job = try store.get(jobID); error = nil } catch { self.error = "\(error)" }
                let done = job?.status.isTerminal ?? false
                try? await Task.sleep(nanoseconds: done ? 2_000_000_000 : 500_000_000)
            }
        }
    }

    @ViewBuilder func content(_ j: Job) -> some View {
        let (label, tint) = JobText.status(j.status)
        if !compact {
            HStack(spacing: 8) {
                Text(JobText.title(j)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                StatusPill(text: label, tint: tint)
            }
        }
        if !j.status.isTerminal {
            ProgressView(value: min(1, max(0, j.progress))).tint(Theme.accent)
        }
        if let m = j.message, !m.isEmpty { Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
        if let e = j.error, j.status == .failed { InlineError(text: e) }
        VStack(alignment: .leading, spacing: 5) {
            ForEach(j.stages, id: \.name) { st in
                let (icon, c) = JobText.stageIcon(st.status)
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: icon).font(.system(size: 11)).foregroundStyle(c).frame(width: 14).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(JobText.stage(st.name)).font(.system(size: 12)).foregroundStyle(st.status == .pending ? Theme.text3 : Theme.text)
                        if let d = st.detail ?? st.error { Text(d).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(3) }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        if !j.review.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("To look at before publishing").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.speed)
                ForEach(Array(j.review.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(Theme.speed)
                        Text(r).font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.speed.opacity(0.08)))
        }
        outputs(j)
        actions(j)
        if !compact { Text("Started \(j.createdAt.formatted(date: .omitted, time: .shortened)) by \(j.author.kind == .agent ? j.author.name : j.author.kind == .user ? "you" : "Glint")").font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
    }

    /// Files finished stages wrote, with their quality when they were measured.
    @ViewBuilder func outputs(_ j: Job) -> some View {
        let files = j.stages.filter { $0.status == .done }.flatMap(\.artifacts)
        let reports = renderOutputs(j)
        if !files.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files, id: \.self) { rel in
                    let url = model.bundle.resolve(rel)
                    let out = reports.first { URL(fileURLWithPath: $0.path).standardizedFileURL == url.standardizedFileURL }
                    let failing = out?.report?.quality.failures ?? []
                    HStack(spacing: 8) {
                        Image(systemName: failing.isEmpty ? "film" : "exclamationmark.triangle.fill").font(.system(size: 11))
                            .foregroundStyle(failing.isEmpty ? Theme.text2 : Theme.speed)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(out.map { "\(JobText.variantName($0.variant)) · \($0.width)×\($0.height) · \(String(format: "%.1fs", $0.duration))" } ?? url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            if let q = out?.report?.quality { Text("Quality \(q.score)/100\(failing.isEmpty ? "" : " · \(failing.count) check\(failing.count == 1 ? "" : "s") failed")").font(.system(size: 10.5)).foregroundStyle(Theme.text3) }
                        }
                        Spacer(minLength: 4)
                        Button("Show") { FilePick.reveal(url) }.buttonStyle(GhostButtonStyle()).controlSize(.small).help("Show in Finder")
                        Button("Save…") { save(url, variant: out?.variant) }.buttonStyle(GhostButtonStyle()).controlSize(.small)
                    }
                }
            }
        }
    }

    func renderOutputs(_ j: Job) -> [RenderOutput] {
        guard let r = j.result else { return [] }
        if let m = try? r.decode(RenderManifest.self) { return m.outputs }
        if let o = r["render"], let out = try? o.decode(RenderOutput.self) { return [out] }
        return []
    }

    @ViewBuilder func actions(_ j: Job) -> some View {
        HStack(spacing: 6) {
            if !j.status.isTerminal {
                Button(role: .destructive) { cancel(j) } label: { Label("Cancel", systemImage: "stop.fill") }.buttonStyle(GhostButtonStyle())
            }
            if [.failed, .cancelled, .interrupted].contains(j.status) {
                Button { retry(j) } label: { Label("Retry", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
                    .help("Picks up after the last finished stage")
            }
            if j.status == .needsReview, j.kind == .production {
                Button { retry(j) } label: { Label("Check again", systemImage: "arrow.clockwise") }.buttonStyle(GhostButtonStyle())
                    .help("Run the inspection and evidence checks again (after you fix things or record evidence)")
            }
            Spacer(minLength: 0)
        }
    }

    func cancel(_ j: Job) {
        do { job = try store.requestCancel(j.id) } catch { self.error = "\(error)" }
    }

    func retry(_ j: Job) {
        do { try JobLauncher.shared.retry(model.service, model.bundle, j.id); job = try store.get(j.id) } catch { self.error = "\(error)" }
    }

    func save(_ url: URL, variant: String?) {
        guard let dest = FilePick.save(suggestedName: "\(model.doc.name)\(variant.map { " \($0)" } ?? "").\(url.pathExtension)") else { return }
        do {
            // The save panel already asked about replacing an existing file.
            _ = try model.service.export(file: url, to: dest, author: .app, approvalID: nil, confirmedByUser: true)
        } catch { self.error = "\(error)" }
    }
}

/// Starts a production check: quality → safe fixes → draft render → inspection → recipe evidence.
struct ProductionCheckForm: View {
    let model: EditorModel
    let onStart: (String) -> Void
    @State private var repair = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Hint("Checks the edit, applies safe automatic fixes (each one undoable), renders a 720p draft, inspects the file and checks the recipe's evidence. It ends Needs review unless every check passes; it never cuts content or changes the story on its own.")
            Toggle("Apply safe automatic fixes", isOn: $repair).toggleStyle(.switch).controlSize(.small).tint(Theme.accentStrong)
            if let error { InlineError(text: error) { self.error = nil } }
            Button { start() } label: { Label("Run production check", systemImage: "checklist") }.buttonStyle(GhostButtonStyle())
        }
    }

    func start() {
        error = nil
        do {
            let (job, _) = try JobRunner.createProduction(model.service, model.bundle, variant: "preview", repair: repair, maxAttempts: 2, targetDuration: nil,
                                                          idempotencyKey: nil, expectedRevision: nil, author: .app)
            JobLauncher.shared.start(model.service, model.bundle, job.id)
            onStart(job.id)
        } catch { self.error = "\(error)" }
    }
}

/// Every job of the project, newest first (Activity tab).
struct JobsPanel: View {
    let model: EditorModel
    @State private var jobs: [Job] = []
    @State private var expanded: String?
    @State private var showProduction = false
    @State private var showAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Renders and checks", systemImage: "film")
                HeaderAction(title: showProduction ? "Close" : "Production check") { showProduction.toggle() }
            }
            if showProduction {
                Card { ProductionCheckForm(model: model) { id in expanded = id; showProduction = false; reload() } }
            }
            if jobs.isEmpty {
                Hint("Exports and production checks appear here with their progress. They keep running if you close the export window, and can be retried if Glint quits.")
            }
            ForEach(jobs.prefix(showAll ? jobs.count : 20)) { j in
                let (label, tint) = JobText.status(j.status)
                let open = expanded == j.id
                ListRow(selected: open) { expanded = open ? nil : j.id } content: {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Image(systemName: j.kind == .production ? "checklist" : "film").font(.system(size: 11)).foregroundStyle(Theme.text2).frame(width: 16)
                            Text(JobText.title(j)).font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 4)
                            StatusPill(text: label, tint: tint)
                        }
                        if !j.status.isTerminal { ProgressView(value: min(1, max(0, j.progress))).tint(Theme.accent).padding(.leading, 24) }
                        Text(j.createdAt.formatted(.relative(presentation: .named))).font(.system(size: 10.5)).foregroundStyle(Theme.text3).padding(.leading, 24)
                    }
                }
                if open { Card { JobDetailView(model: model, jobID: j.id, compact: true) } }
            }
            if jobs.count > 20 {
                Button(showAll ? "Show newest 20" : "Show all \(jobs.count) jobs") { showAll.toggle() }
                    .buttonStyle(GhostButtonStyle())
            }
        }
        .task {
            while !Task.isCancelled {
                reload()
                let active = jobs.contains { !$0.status.isTerminal }
                try? await Task.sleep(nanoseconds: active ? 1_000_000_000 : 3_000_000_000)
            }
        }
    }

    func reload() {
        let j = JobStore(bundle: model.bundle).list()
        if j != jobs { jobs = j }
    }
}
