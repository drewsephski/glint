import SwiftUI
import AppKit

/// Every editor shortcut, in one place: the help sheet lists these and `EditorKeys` handles the single-key ones.
enum EditorShortcuts {
    struct Item: Identifiable { let keys: String; let action: String; var id: String { keys + action } }
    struct Group: Identifiable { let title: String; let items: [Item]; var id: String { title } }

    static let groups: [Group] = [
        Group(title: "Playback", items: [
            Item(keys: "Space", action: "Play or pause"),
        ]),
        Group(title: "Editing", items: [
            Item(keys: "⌘Z", action: "Undo"),
            Item(keys: "⇧⌘Z", action: "Redo"),
            Item(keys: "⌫", action: "Delete the selected item"),
            Item(keys: "S", action: "Split the shot at the playhead"),
            Item(keys: "I", action: "Start the video at the playhead (in point)"),
            Item(keys: "O", action: "End the video at the playhead (out point)"),
        ]),
        Group(title: "Drawing on the preview", items: OverlayTool.allCases.map { Item(keys: String($0.key).uppercased(), action: "\($0.title) tool") } + [
            Item(keys: "Esc", action: "Put the tool away, then clear the selection"),
        ]),
        Group(title: "Help", items: [
            Item(keys: "⌘/", action: "Show this list"),
        ]),
    ]
}

struct ShortcutsHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemName: "keyboard", size: 36, tint: Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keyboard shortcuts").font(.system(size: 17, weight: .semibold))
                    Text("Single-key shortcuts work whenever you are not typing in a text field.").font(.system(size: 12)).foregroundStyle(Theme.text2)
                }
            }
            ForEach(EditorShortcuts.groups) { g in
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader(title: g.title)
                    ForEach(g.items) { item in
                        HStack {
                            Text(item.action).font(.system(size: 12.5)).foregroundStyle(Theme.text)
                            Spacer()
                            Keycap(item.keys)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22).frame(width: 440)
        .background(Theme.panel)
    }
}

/// Handles the editor's single-key shortcuts for the window it sits in. Keys pass through untouched while a text
/// field is being edited, while a sheet or popover has focus, and when a modifier other than Shift is held.
struct EditorKeys: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> KeyView { KeyView(model: model) }
    func updateNSView(_ v: KeyView, context: Context) { v.model = model }

    final class KeyView: NSView {
        var model: EditorModel
        private var monitor: Any?
        init(model: EditorModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self else { return e }
                let consumed = MainActor.assumeIsolated { self.handle(e) }
                return consumed ? nil : e
            }
        }
        override func removeFromSuperview() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            super.removeFromSuperview()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        @MainActor func handle(_ e: NSEvent) -> Bool {
            guard let window, e.window === window, window.attachedSheet == nil, window.isKeyWindow else { return false }
            if model.transcriptHasFocus { return false }
            // Typing goes to the text field (the field editor is an NSTextView).
            if let tv = window.firstResponder as? NSTextView, tv.isEditable { return false }
            let mods = e.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty else { return false }
            switch e.keyCode {
            case 49: model.togglePlay(); return true                                  // space
            case 51, 117:                                                              // delete, forward delete
                guard model.selection != nil else { return false }
                model.deleteSelection(); return true
            case 53:                                                                   // escape
                if model.overlayTool != nil { model.overlayTool = nil; return true }
                if model.selection != nil { model.selection = nil; return true }
                return false
            default: break
            }
            guard !e.modifierFlags.contains(.shift), let ch = e.charactersIgnoringModifiers?.lowercased().first else { return false }
            switch ch {
            case "s": model.splitShotAtPlayhead(); return true
            case "i": model.setTrimAtPlayhead(in: true); return true
            case "o": model.setTrimAtPlayhead(in: false); return true
            default:
                guard let tool = OverlayTool.allCases.first(where: { $0.key == ch }) else { return false }
                guard model.previewProposal == nil else { model.banner = "Apply or discard the previewed proposal to draw on the preview"; return true }
                if model.isPlaying { model.togglePlay() }
                model.overlayTool = model.overlayTool == tool ? nil : tool
                return true
            }
        }
    }
}

/// Undo/redo inside the text field being edited, if any (the app's Undo menu otherwise undoes project edits).
enum TextUndo {
    @MainActor static func perform(redo: Bool) -> Bool {
        guard let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable, let um = tv.undoManager else { return false }
        if redo { guard um.canRedo else { return true }; um.redo() } else { guard um.canUndo else { return true }; um.undo() }
        return true
    }
}
