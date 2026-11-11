import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GlintCore
import GlintRender
import GlintAgent

// MARK: - Export

/// "Export the video I'm looking at." The first choice renders the composition exactly as edited (canvas, framing,
/// padding, captions, camera layout and mix); alternate formats are explicit, each with a frame rendered through the
/// real export path so a changed crop or caption size is visible before rendering. Before anything renders, the media
/// the edit needs is checked, and each problem comes with a fix. The render then runs as a durable job: live progress,
/// stages, cancel and retry. The job keeps running if the sheet closes (see Activity).
struct ExportSheet: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    /// New key: earlier builds defaulted to "landscape", which silently changed 4:3 / square / source-canvas edits.
    @AppStorage("GlintExportVariants.v2") private var chosenRaw = "current"
    @State private var jobID: String?
    @State private var error: String?
    @State private var showProduction = false
    /// The format whose frame is previewed (the last one clicked).
    @State private var focus = "current"
    @State private var stills: [String: NSImage] = [:]
    @State private var stillError: String?
    /// nil while checking.
    @State private var problems: [MediaProblem]?

    struct Option: Identifiable { let id: String; let title: String; let icon: String }
    static let options: [Option] = [
        Option(id: "current", title: "Current composition", icon: "rectangle.on.rectangle"),
        Option(id: "landscape", title: "Landscape 1080p", icon: "rectangle"),
        Option(id: "landscape-4k", title: "Landscape 4K", icon: "rectangle"),
        Option(id: "square", title: "Square", icon: "square"),
        Option(id: "portrait", title: "Vertical", icon: "rectangle.portrait"),
        Option(id: "prores", title: "ProRes master", icon: "film.stack"),
        Option(id: "gif", title: "GIF", icon: "photo.on.rectangle"),
    ]

    var chosen: Set<String> { Set(chosenRaw.split(separator: ",").map(String.init)).intersection(Self.options.map(\.id)) }
    var blocking: [MediaProblem] { (problems ?? []).filter(\.blocking) }
    /// The document the render job will use: the saved edit, or the proposal being previewed.
    var document: ProjectDocument { model.previewDocument }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemName: "square.and.arrow.up", size: 36, tint: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Export").font(.system(size: 17, weight: .semibold)).tracking(-0.2)
                    Text(jobID == nil ? "Renders the video you're looking at. Add other formats if you need them." : "Rendering continues if you close this window. Follow it in Activity.")
                        .font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            if let jobID {
                JobDetailView(model: model, jobID: jobID)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            } else {
                HStack(alignment: .top, spacing: 14) {
                    ScrollView { variants }.frame(width: 300).frame(maxHeight: 380)
                    preview.frame(maxWidth: .infinity)
                }
                readiness
                if model.previewProposal != nil { Hint("Renders the proposal you're previewing, not the saved edit.") }
                DisclosureGroup(isExpanded: $showProduction) {
                    ProductionCheckForm(model: model) { id in jobID = id }.padding(.top, 8)
                } label: {
                    Text("Production check").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.text2)
                }
            }
            if let error { InlineError(text: error) { self.error = nil } }
            HStack {
                if jobID != nil { Button("Export something else") { jobID = nil }.buttonStyle(LinkButtonStyle()) }
                Spacer()
                Button(jobID == nil ? "Cancel" : "Close") { dismiss() }.buttonStyle(GhostButtonStyle())
                if jobID == nil {
                    Button { start() } label: { Label(chosen.count > 1 ? "Render \(chosen.count) files" : "Render", systemImage: "film") }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(chosen.isEmpty || problems == nil || !blocking.isEmpty)
                        .help(!blocking.isEmpty ? "Fix the media problems first" : problems == nil ? "Checking media…" : "")
                }
            }
        }
        .padding(22).frame(width: 760)
        .background(Theme.panel)
        .task(id: checkKey) { await check() }
    }

    // MARK: Formats

    var variants: some View {
        VStack(spacing: 6) {
            ForEach(Self.options) { o in
                let on = chosen.contains(o.id)
                let focused = focus == o.id
                HStack(alignment: .top, spacing: 11) {
                    Button { toggle(o.id) } label: {
                        Image(systemName: on ? "checkmark.circle.fill" : "circle").font(.system(size: 15)).foregroundStyle(on ? Theme.accent : Theme.text3)
                    }.buttonStyle(.plain).accessibilityLabel(on ? "Don't export \(o.title)" : "Export \(o.title)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(o.title).font(.system(size: 13, weight: .medium))
                        Text(facts(o.id)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
                        if let change = changes(o.id) {
                            Text(change).font(.system(size: 11)).foregroundStyle(o.id == "current" ? Theme.text3 : Theme.speed.opacity(0.9))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? Theme.accent.opacity(0.1) : Color.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.6) : on ? Theme.accent.opacity(0.3) : Theme.hairline))
                .contentShape(Rectangle())
                .onTapGesture { if focus == o.id { toggle(o.id) } else { focus = o.id; if !on { toggle(o.id) } } }
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    func toggle(_ id: String) {
        var c = chosen
        if c.contains(id) { c.remove(id) } else { c.insert(id); focus = id }
        chosenRaw = Self.options.map(\.id).filter(c.contains).joined(separator: ",")
    }

    func resolved(_ id: String) -> (RenderVariant, ProjectDocument)? {
        guard let v = RenderVariant.preset(id), let d = try? v.resolve(document) else { return nil }
        return (v, d)
    }

    /// "1440×1080 · 30 fps · MP4 H.264 · ≈ 38 MB"
    func facts(_ id: String) -> String {
        guard let (v, d) = resolved(id) else { return "" }
        let o = v.output(for: d)
        let format: String
        switch (v.format, v.codec) {
        case (.gif, _): format = "GIF"
        case (_, .prores): format = "MOV ProRes 422"
        case (let f, let c): format = "\(f.rawValue.uppercased()) \(c == .hevc ? "HEVC" : "H.264")"
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(o.estimatedBytes), countStyle: .file)
        // Non-breaking spaces keep "≈ 38 MB" and "30 fps" whole when the line wraps.
        let nb = "\u{00A0}"
        return "\(o.width)×\(o.height) · \(Int(o.fps.rounded()))\(nb)fps · \(format) · ≈\(nb)\(size.replacingOccurrences(of: " ", with: nb))"
    }

    /// How a format differs from the edit, in words. nil when it renders the composition unchanged (besides size).
    func changes(_ id: String) -> String? {
        guard let (v, d) = resolved(id) else { return nil }
        let doc = document
        if id == "current" { return "Your \(aspectName(doc.style.canvas.aspect)) canvas, framing, captions and mix, as previewed." }
        var parts: [String] = []
        if d.style.canvas.aspect != doc.style.canvas.aspect { parts.append("\(aspectName(d.style.canvas.aspect)) canvas") }
        if d.style.canvas.baseScale > doc.style.canvas.baseScale + 0.01 { parts.append("zoomed in to follow the cursor") }
        if abs(d.style.frame.padding - doc.style.frame.padding) > 0.001 { parts.append(d.style.frame.padding < doc.style.frame.padding ? "less padding" : "more padding") }
        if abs(d.style.captions.size - doc.style.captions.size) > 0.0001 { parts.append(d.style.captions.size < doc.style.captions.size ? "smaller captions" : "larger captions") }
        if v.format == .gif { parts.append("no sound") }
        guard !parts.isEmpty else { return v.preservesComposition(of: doc) ? nil : "Same composition at a different size." }
        return "Changes your edit: " + parts.joined(separator: ", ") + "."
    }

    func aspectName(_ a: Aspect) -> String {
        switch a {
        case .auto: return "source-shaped"
        case .landscape: return "16:9"
        case .square: return "square"
        case .portrait: return "9:16"
        case .classic: return "4:3"
        case .vertical45: return "4:5"
        }
    }

    // MARK: Preview

    /// A frame at the playhead rendered through the export path for the focused format: what that file will show.
    var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.well)
                if let img = stills[stillKey] {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(8)
                } else if let stillError {
                    Text(stillError).font(.system(size: 11)).foregroundStyle(Theme.text3).padding()
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 300)
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
            let title = Self.options.first { $0.id == focus }?.title ?? focus
            Text("\(title) at \(Theme.time(model.currentTime))").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        .task(id: stillKey) { await renderStill() }
    }

    var stillKey: String { "\(focus)|\(document.revision)|\(model.previewProposal ?? "")|\(Int(model.currentTime * 10))" }

    func renderStill() async {
        let key = stillKey, id = focus
        guard stills[key] == nil, let v = RenderVariant.preset(id) else { return }
        stillError = nil
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("glint-export-preview-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try await model.service.renderFrame(model.bundle, time: model.currentTime, proposal: model.previewProposal, variant: v, to: url, maxWidth: 900)
            guard !Task.isCancelled, let img = NSImage(contentsOf: url) else { return }
            stills[key] = img
        } catch { if !Task.isCancelled { stillError = "Couldn't render a preview: \(error)" } }
    }

    // MARK: Readiness

    var checkKey: String { "\(document.revision)|\(model.previewProposal ?? "")" }

    func check() async {
        let found = await MediaPreflight.check(bundle: model.bundle, document: document)
        guard !Task.isCancelled else { return }
        problems = found
    }

    @ViewBuilder var readiness: some View {
        if let problems {
            if problems.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.ok)
                    Text("Ready. Every picture and sound in the edit is available.").font(.system(size: 11.5)).foregroundStyle(Theme.text2)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(blocking.isEmpty ? "Worth a look before exporting" : "Fix before exporting")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(blocking.isEmpty ? Theme.speed : Theme.cut)
                    ForEach(problems) { p in problemRow(p) }
                }
            }
        } else {
            WorkingRow(text: "Checking the media the edit uses…")
        }
    }

    func problemRow(_ p: MediaProblem) -> some View {
        let tint = p.blocking ? Theme.cut : Theme.speed
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: p.blocking ? "exclamationmark.triangle.fill" : "info.circle.fill").font(.system(size: 10.5)).foregroundStyle(tint).padding(.top, 2)
            Text(p.message).font(.system(size: 11.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 6)
            HStack(spacing: 6) { fixes(p) }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint.opacity(0.2)))
    }

    @ViewBuilder func fixes(_ p: MediaProblem) -> some View {
        switch p.kind {
        case .voiceover:
            if p.reason != .silentOutOfRange { Button("Locate…") { locate(p) } }
            if let id = p.itemID { Button("Remove") { model.apply([EditOperation(.removeVoiceover, id: id)], label: "Remove missing voiceover") } }
        case .audioClip:
            Button("Locate…") { locate(p) }
            if let id = p.itemID { Button("Remove") { model.apply([EditOperation(.removeAudio, id: id)], label: "Remove missing audio") } }
        case .microphone:
            Button("Mute microphone") { model.style("audio.muteMicrophone", .bool(true)) }
        case .systemAudio, .shotAudio:
            Button("Mute system audio") { model.style("audio.muteSystem", .bool(true)) }
        case .camera:
            Button("Hide facecam") { model.style("facecam.visible", .bool(false)) }
        case .screen, .shot:
            EmptyView()
        }
    }

    /// Put a file back where the edit expects it (copied into the project; the edit itself doesn't change).
    func locate(_ p: MediaProblem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.message = "Choose the file to use for \((p.path as NSString).lastPathComponent)"
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let dst = model.bundle.resolve(p.path)
        do {
            try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dst.path) {
                // An unreadable file is kept beside the new one rather than overwritten.
                try FileManager.default.moveItem(at: dst, to: dst.appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970))"))
            }
            try FileManager.default.copyItem(at: src, to: dst)
            problems = nil
            Task { await check() }
        } catch { self.error = "Couldn't use that file: \(error.localizedDescription)" }
    }

    func start() {
        error = nil
        let names = Self.options.map(\.id).filter(chosen.contains)
        do {
            let (job, existing) = try JobRunner.createRender(model.service, model.bundle, variants: names, proposal: model.previewProposal,
                                                              idempotencyKey: nil, expectedRevision: document.revision, inspect: true, author: .app)
            if !existing || job.status == .queued { JobLauncher.shared.start(model.service, model.bundle, job.id) }
            jobID = job.id
        } catch { self.error = "\(error)" }
    }
}
