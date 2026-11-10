import SwiftUI
import GlintCore
import GlintAgent

/// Reusable looks: Glint's built-in presets and ones saved from a project. Applying one is a single undoable edit.
struct StylePresetsSection: View {
    let model: EditorModel
    @State private var presets: [StylePreset] = []
    @State private var saving = false
    @State private var name = ""
    @State private var summary = ""
    @State private var error: String?
    @State private var deleteCandidate: StylePreset?
    @State private var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionHeader(title: "Presets", systemImage: "square.stack")
                HeaderAction(title: saving ? "Close" : "Save current look…") { saving.toggle(); error = nil }
            }
            if saving { saveForm }
            if let saved {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.ok)
                    Text("Saved “\(saved)”. It's available in every project.").font(.system(size: 11.5))
                    Spacer(minLength: 0)
                }
            }
            VStack(spacing: 4) {
                ForEach(presets, id: \.name) { p in row(p) }
            }
        }
        .onAppear(perform: reload)
        .confirmationDialog("Delete the preset “\(deleteCandidate?.name ?? "")”?", isPresented: Binding(get: { deleteCandidate != nil }, set: { if !$0 { deleteCandidate = nil } }), titleVisibility: .visible) {
            Button("Delete preset", role: .destructive) {
                if let p = deleteCandidate {
                    do { try model.service.deletePreset(name: p.name) } catch { self.error = "\(error)" }
                    reload()
                }
                deleteCandidate = nil
            }
            Button("Cancel", role: .cancel) { deleteCandidate = nil }
        } message: { Text("Projects that used it keep their look. This can't be undone.") }
    }

    func row(_ p: StylePreset) -> some View {
        Hoverable { hover in
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(p.name.replacingOccurrences(of: "-", with: " ").capitalized).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !p.builtIn { Tag("Saved") }
                    }
                    Text(p.summary).font(.system(size: 10.5)).foregroundStyle(Theme.text3).lineLimit(2)
                }
                Spacer(minLength: 4)
                if !p.builtIn && hover {
                    Button { deleteCandidate = p } label: { Image(systemName: "trash").font(.system(size: 9.5)) }.buttonStyle(MiniButtonStyle()).help("Delete preset")
                }
                Button("Apply") { apply(p) }.buttonStyle(GhostButtonStyle()).controlSize(.small)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hover ? 0.05 : 0.025)))
        }
    }

    var saveForm: some View {
        Card {
            TextField("Name, e.g. Launch week", text: $name).textFieldStyle(.roundedBorder).font(.system(size: 12))
                .onChange(of: name) { _, _ in confirmReplace = false }
            TextField("One line about it (optional)", text: $summary).textFieldStyle(.roundedBorder).font(.system(size: 12))
            Hint("Saves the background, frame, cursor, camera, captions, canvas and facecam settings. Audio levels and the narration voice stay with the project.")
            if let error { InlineError(text: error) { self.error = nil } }
            HStack {
                Spacer()
                Button("Save preset") { save() }.buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    func reload() { presets = model.service.presets() }

    func apply(_ p: StylePreset) {
        model.apply([EditOperation(.mergeStyle, value: p.style)], label: "Apply preset “\(p.name)”")
    }

    func save() {
        error = nil
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if presets.contains(where: { !$0.builtIn && $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            // Saving under an existing name replaces it; say so rather than silently overwriting.
            if !confirmReplace { confirmReplace = true; error = "A saved preset is already called “\(n)”. Press Save preset again to replace it."; return }
        }
        do {
            let p = try model.service.savePreset(name: n, summary: s.isEmpty ? nil : s, from: model.bundle)
            saved = p.name
            name = ""; summary = ""; saving = false; confirmReplace = false
            reload()
        } catch { self.error = "\(error)" }
    }

    @State private var confirmReplace = false
}
