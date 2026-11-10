import SwiftUI
import AppKit
import GlintCore
import GlintAgent

/// Home's list of takes that never finished: Glint or the recording process crashed, was force-quit or lost power, or
/// finalizing failed. Media is saved every 2 s while recording, so Recover rebuilds the take from what reached the disk.
struct RecoveryBanner: View {
    let app: AppModel
    @State private var discardCandidate: RecoverableRecording?

    var body: some View {
        if !app.recoverable.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: 14)).foregroundStyle(Theme.speed).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.recoverable.count == 1 ? "A recording was interrupted" : "\(app.recoverable.count) recordings were interrupted")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Glint saves a take every couple of seconds while it records. Recover keeps everything up to the last save; the final moments before the interruption may be missing.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(app.recoverable, id: \.project) { r in
                        RecoveryRow(item: r, onRecover: { app.recover(r) }, onDiscard: { discardCandidate = r })
                        if r.project != app.recoverable.last?.project { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.speed.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.speed.opacity(0.22)))
            .confirmationDialog("Move “\(discardCandidate?.name ?? "")” to the Trash?", isPresented: Binding(get: { discardCandidate != nil }, set: { if !$0 { discardCandidate = nil } }), titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) { if let r = discardCandidate { app.discard(r) }; discardCandidate = nil }
                Button("Cancel", role: .cancel) { discardCandidate = nil }
            } message: {
                Text("The interrupted take and its partial media move to the Trash. You can put it back from the Trash in Finder.")
            }
        }
    }
}

private struct RecoveryRow: View {
    let item: RecoverableRecording
    let onRecover: () -> Void
    let onDiscard: () -> Void

    private var detail: String {
        var parts = ["\(Theme.time(item.elapsed, precise: false)) recorded"]
        parts.append("interrupted \(item.lastCheckpoint.formatted(.relative(presentation: .named)))")
        if item.recordedBy.kind == .agent { parts.append("by \(item.recordedBy.name)") }
        let bytes = item.files.values.reduce(0, +)
        if bytes > 0 { parts.append(PreflightMath.formatBytes(Double(bytes))) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "film").font(.system(size: 12)).frame(width: 18).foregroundStyle(Theme.text3)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.text3).lineLimit(1)
                if let e = item.error { Text(e).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.project)]) }.buttonStyle(LinkButtonStyle())
            Button("Discard…", action: onDiscard).buttonStyle(GhostButtonStyle())
            Button("Recover", action: onRecover).buttonStyle(PrimaryButtonStyle())
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// What the New Recording sheet's preflight found: failures (Record stays off) and warnings, each with its fix, and
/// a one-line disk estimate when all is well.
struct PreflightSummary: View {
    let report: PreflightReport
    /// Checks shown elsewhere in the sheet (Screen Recording help has its own panel).
    var hiding: Set<String> = []

    var body: some View {
        let issues = report.checks.filter { $0.verdict != .pass && !hiding.contains($0.id) }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(issues, id: \.id) { c in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: c.verdict == .fail ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11.5)).foregroundStyle(c.verdict == .fail ? Theme.cut : Theme.speed).frame(width: 14).padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(c.title): \(c.detail)").font(.system(size: 11.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                        if let fix = c.fix { Text(fix).font(.system(size: 11)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            if issues.isEmpty, let disk = report.checks.first(where: { $0.id == "disk" && $0.verdict == .pass }) {
                Hint("About \(PreflightMath.formatBytes(report.estimatedBytesPerMinute)) a minute. \(disk.detail)")
            }
        }
    }
}
