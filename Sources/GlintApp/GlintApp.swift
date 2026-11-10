import SwiftUI
import AppKit
import GlintCore
import GlintAgent

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var app = AppModel()

    var body: some SwiftUI.Scene {
        WindowGroup("Glint") {
            RootView(app: app)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                // Finder double-clicks and `open x.glint` arrive here (SwiftUI makes a window if needed).
                .onOpenURL { url in if url.pathExtension == ProjectBundle.pathExtension { app.open(url) } }
        }
        .defaultSize(width: 1500, height: 940)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") { app.showRecordSheet = true }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Open Project…") { app.openPanel() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { app.editor?.undo() }.keyboardShortcut("z").disabled(!(app.editor?.canUndo ?? false))
                Button("Redo") { app.editor?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!(app.editor?.canRedo ?? false))
            }
            CommandMenu("Edit Video") {
                Button("Play / Pause") { app.editor?.togglePlay() }.keyboardShortcut(.space, modifiers: [])
                Button("Delete Selection") { app.editor?.deleteSelection() }.keyboardShortcut(.delete, modifiers: [])
                Divider()
                Button("Auto Zoom") { app.editor?.autoZoom() }.keyboardShortcut("z", modifiers: [.command, .option])
                Button("Tighten Pauses") { app.editor?.tighten() }.keyboardShortcut("t", modifiers: [.command, .option])
                Button("Generate Captions") { app.editor?.captions() }.keyboardShortcut("c", modifiers: [.command, .option])
                Divider()
                Button("Analyze Scenes") { app.editor?.analyzeScenes() }.keyboardShortcut("s", modifiers: [.command, .option]).disabled(app.editor == nil)
                Button("Write Narration") { app.editor?.writeNarration(brief: nil) }.disabled(app.editor == nil || !(app.editor?.hasAnthropicKey ?? false))
                Button("Generate Voiceover") { app.editor?.generateVoiceover(voice: nil, fit: true, captions: true) }.disabled(app.editor == nil || !(app.editor?.hasElevenLabsKey ?? false))
                Button("Fit Picture to Narration") { app.editor?.fitNarration() }.disabled(app.editor?.doc.timeline.voiceover.isEmpty ?? true)
            }
        }

        Settings { SettingsView().preferredColorScheme(.dark) }

        MenuBarExtra {
            if app.recording != nil {
                Button("Stop Recording") { app.stopRecording() }
                Button("Drop Marker") { app.markMoment() }
            } else {
                Button("New Recording…") { app.showRecordSheet = true; NSApp.activate(ignoringOtherApps: true) }
            }
            if !app.approvals.isEmpty {
                Divider()
                Text("\(app.approvals.count) agent request(s) waiting")
            }
            ForEach(app.agentSessions, id: \.id) { s in Text("● \(s.author.name) is recording") }
            Divider()
            Button("Quit Glint") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: app.recording != nil || !app.agentSessions.isEmpty ? "record.circle.fill" : "record.circle")
        }
    }
}

struct RootView: View {
    @Bindable var app: AppModel
    var body: some View {
        ZStack(alignment: .top) {
            Theme.canvas.ignoresSafeArea()
            if let editor = app.editor {
                EditorView(app: app, model: editor)
            } else {
                HomeView(app: app)
            }
            VStack(spacing: 8) {
                ForEach(app.agentSessions, id: \.id) { s in
                    Label("\(s.author.name) is recording the screen", systemImage: "record.circle.fill")
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.red.opacity(0.85))).foregroundStyle(.white)
                }
                ForEach(app.approvals) { r in ApprovalBanner(request: r, app: app) }
            }
            .padding(.top, 44)
        }
        .sheet(isPresented: $app.showRecordSheet) { RecordSheet(app: app) }
        .alert("Glint", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) {
            Button("OK") { app.error = nil }
        } message: { Text(app.error ?? "") }
    }
}

struct ApprovalBanner: View {
    let request: ApprovalRequest
    let app: AppModel
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: request.risk == .capture ? "record.circle" : request.risk == .external ? "paperplane" : "exclamationmark.triangle.fill")
                .font(.system(size: 18)).foregroundStyle(request.risk == .destructive ? Theme.cut : Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(request.requestedBy.name) asks to: \(request.summary)").font(.system(size: 13, weight: .semibold)).lineLimit(2).truncationMode(.middle)
                Text("\(request.risk.rawValue) · expires \(request.expiresAt.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(Theme.text3)
            }
            Spacer(minLength: 20)
            Button("Deny") { app.decide(request, approve: false) }.buttonStyle(GhostButtonStyle())
            Button("Approve") { app.decide(request, approve: true) }.buttonStyle(PrimaryButtonStyle())
        }
        .padding(12)
        .frame(maxWidth: 640)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.ultraThickMaterial))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}
