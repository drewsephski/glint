import SwiftUI
import GlintCore
import GlintAgent

/// Making projects from movie files on Home: from a file dialog or by dropping movies on the window.
/// The movie is copied into a new project; the original stays where it was.
@MainActor @Observable
final class MovieImport {
    var working: String?
    var errors: [String] = []
    var targeted = false

    func pick(_ app: AppModel) {
        let urls = FilePick.open(FilePick.movieTypes, multiple: true, message: "Choose movies. Each becomes a project you can edit.")
        guard !urls.isEmpty else { return }
        errors = []
        run(urls, app)
    }

    /// Accepts movie files from a drop; anything else is reported, not silently ignored.
    func drop(_ urls: [URL], _ app: AppModel) -> Bool {
        guard working == nil else { return false }
        let movies = urls.filter(FilePick.isMovie)
        let other = urls.filter { !FilePick.isMovie($0) }
        errors = other.map { "\($0.lastPathComponent) isn't a movie file" }
        guard !movies.isEmpty, working == nil else { return false }
        run(movies, app)
        return true
    }

    private func run(_ urls: [URL], _ app: AppModel) {
        working = "Importing movies…"
        Task {
            var last: ProjectBundle?
            for (i, u) in urls.enumerated() {
                working = urls.count == 1 ? "Importing \(u.lastPathComponent)…" : "Importing \(i + 1) of \(urls.count): \(u.lastPathComponent)…"
                do { last = try await app.service.importMovie(u, name: nil) }
                catch { errors.append("\(u.lastPathComponent): \(error)") }
            }
            working = nil
            app.refresh()
            // One movie opens straight into the editor; several land on Home to choose from.
            if urls.count == 1, errors.isEmpty, let b = last { app.open(b.url) }
        }
    }
}

struct MovieImportStatus: View {
    let state: MovieImport
    var body: some View {
        if state.working != nil || !state.errors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let w = state.working {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(w).font(.system(size: 12.5))
                        Spacer()
                        Text("Copying into a new project").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                    }
                }
                ForEach(state.errors, id: \.self) { e in InlineError(text: e) }
                if !state.errors.isEmpty && state.working == nil {
                    HStack { Spacer(); Button("Dismiss") { state.errors = [] }.buttonStyle(LinkButtonStyle()) }
                }
            }
            .padding(12)
            .surface(radius: 12)
        }
    }
}

struct MovieDropOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent.opacity(0.06)))
            .overlay {
                VStack(spacing: 8) {
                    IconTile(systemName: "film", size: 40, tint: Theme.accent)
                    Text("Drop movies to make new projects").font(.system(size: 14, weight: .semibold))
                    Text("Each file is copied into its own project. The original isn't changed.").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))
            }
            .padding(14)
            .allowsHitTesting(false)
    }
}
