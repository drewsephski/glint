// A small, real AppKit app used as the subject of end-to-end recordings. On "go" (stdin) it runs a scripted tour:
// it glides the real system cursor to each control, actuates the control, and prints what it did as JSON lines
// (the way a UI-automation agent would report its actions to Glint).
import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
let application = NSApplication.shared
application.setActivationPolicy(.regular)

final class Tour: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let title = NSTextField(string: "")
    let body = NSTextField(string: "")
    let status = NSTextField(labelWithString: "Draft")
    let newNote = NSButton(title: "New Note", target: nil, action: nil)
    let publish = NSButton(title: "Publish", target: nil, action: nil)
    let list = NSStackView()

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.main!.frame
        window = NSWindow(contentRect: NSRect(x: 160, y: screen.height - 80 - 760, width: 1200, height: 760), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Acme Notes"
        window.appearance = NSAppearance(named: .aqua)
        let root = NSView(frame: window.contentView!.bounds)
        root.wantsLayer = true; root.layer?.backgroundColor = NSColor(white: 0.98, alpha: 1).cgColor
        let side = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 760)); side.wantsLayer = true
        side.layer?.backgroundColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.96, alpha: 1).cgColor
        root.addSubview(side)
        let brand = NSTextField(labelWithString: "Acme Notes"); brand.font = .boldSystemFont(ofSize: 20); brand.frame = NSRect(x: 22, y: 700, width: 200, height: 28); side.addSubview(brand)
        newNote.frame = NSRect(x: 18, y: 650, width: 214, height: 34); newNote.bezelStyle = .rounded; newNote.font = .systemFont(ofSize: 14, weight: .medium)
        newNote.target = self; newNote.action = #selector(addNote); side.addSubview(newNote)
        list.orientation = .vertical; list.alignment = .leading; list.spacing = 10; list.frame = NSRect(x: 22, y: 380, width: 210, height: 250)
        for n in ["Q3 planning", "Hiring loop", "Customer interviews"] { list.addArrangedSubview(label(n)) }
        side.addSubview(list)
        let h = NSTextField(labelWithString: "Title"); h.font = .systemFont(ofSize: 12, weight: .semibold); h.textColor = .secondaryLabelColor; h.frame = NSRect(x: 290, y: 680, width: 200, height: 18); root.addSubview(h)
        title.frame = NSRect(x: 286, y: 630, width: 620, height: 40); title.font = .systemFont(ofSize: 24, weight: .semibold); title.placeholderString = "Untitled"; root.addSubview(title)
        let b = NSTextField(labelWithString: "Body"); b.font = h.font; b.textColor = .secondaryLabelColor; b.frame = NSRect(x: 290, y: 590, width: 200, height: 18); root.addSubview(b)
        body.frame = NSRect(x: 286, y: 300, width: 860, height: 280); body.font = .systemFont(ofSize: 17); body.placeholderString = "Start writing…"
        body.usesSingleLineMode = false; body.cell?.wraps = true; body.cell?.isScrollable = false; root.addSubview(body)
        publish.frame = NSRect(x: 1010, y: 640, width: 140, height: 36); publish.bezelStyle = .rounded; publish.bezelColor = .systemBlue; publish.font = .systemFont(ofSize: 14, weight: .semibold)
        publish.target = self; publish.action = #selector(doPublish); root.addSubview(publish)
        status.frame = NSRect(x: 1010, y: 610, width: 160, height: 20); status.textColor = .secondaryLabelColor; root.addSubview(status)
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        print("{\"kind\":\"ready\"}")
        DispatchQueue.global().async {
            while let line = readLine() { if line == "go" { DispatchQueue.main.async { self.run() } } }
        }
    }
    func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.font = .systemFont(ofSize: 14); return l }
    @objc func addNote() { list.insertArrangedSubview(label("• New note"), at: 0); window.makeFirstResponder(title) }
    @objc func doPublish() { status.stringValue = "Published ✓"; status.textColor = .systemGreen; publish.isEnabled = false }

    /// Global (top-left origin) center of a view.
    func center(_ v: NSView) -> CGPoint {
        let r = v.convert(v.bounds, to: nil)
        let w = window.convertToScreen(r)
        let primaryHeight = NSScreen.screens[0].frame.height
        return CGPoint(x: w.midX, y: primaryHeight - w.midY)
    }
    func glide(to p: CGPoint, duration: Double, then: @escaping () -> Void) {
        let from = CGEvent(source: nil)?.location ?? p
        let start = Date()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { t in
            let f = min(1, Date().timeIntervalSince(start) / duration), e = f * f * (3 - 2 * f)
            CGWarpMouseCursorPosition(CGPoint(x: from.x + (p.x - from.x) * e, y: from.y + (p.y - from.y) * e))
            if f >= 1 { t.invalidate(); then() }
        }
    }
    func emit(_ d: [String: Any]) { print(String(data: try! JSONSerialization.data(withJSONObject: d), encoding: .utf8)!) }
    func click(_ v: NSView, _ label: String, then: @escaping () -> Void) {
        glide(to: center(v), duration: 0.7) {
            let p = self.center(v)
            self.emit(["kind": "click", "global_x": p.x, "global_y": p.y, "label": label])
            (v as? NSButton)?.highlight(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { (v as? NSButton)?.highlight(false); (v as? NSButton)?.performClick(nil); if v is NSTextField { self.window.makeFirstResponder(v) }; then() }
        }
    }
    func type(_ s: String, into f: NSTextField, cps: Double = 14, then: @escaping () -> Void) {
        emit(["kind": "type", "count": s.count, "duration": Double(s.count) / cps])
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 1 / cps, repeats: true) { t in
            i += 1; f.stringValue = String(s.prefix(i))
            if i >= s.count { t.invalidate(); then() }
        }
    }
    func wait(_ s: Double, then: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: then) }

    func run() {
        let orig = CGEvent(source: nil)?.location
        emit(["kind": "mark", "note": "start tour"])
        wait(1.2) {
            self.click(self.newNote, "New Note") {
                self.wait(0.6) {
                    self.click(self.title, "Title") {
                        self.type("Launch checklist", into: self.title) {
                            self.wait(0.5) {
                                self.click(self.body, "Body") {
                                    self.type("1. Record the demo  2. Polish it with Glint  3. Ship it", into: self.body, cps: 18) {
                                        self.emit(["kind": "mark", "note": "thinking pause"])
                                        self.wait(3.0) {
                                            self.click(self.publish, "Publish") {
                                                self.wait(2.0) {
                                                    if let orig { CGWarpMouseCursorPosition(orig) }
                                                    self.emit(["kind": "done"])
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
let tour = Tour()
application.delegate = tour
application.run()
