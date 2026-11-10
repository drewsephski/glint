import SwiftUI
import AppKit
import GlintCore
import GlintAgent

/// First-run setup, four short steps: what Glint does, Screen Recording, agents, and a first thing to do.
/// Every step can be skipped; Home has the same controls afterwards. The step survives a relaunch, because turning on
/// Screen Recording needs one.
struct OnboardingView: View {
    let app: AppModel
    @State private var step: Step
    @State private var forward = true

    enum Step: Int, CaseIterable { case welcome, permission, agents, ready }
    static let stepKey = "GlintOnboardingStep"

    init(app: AppModel) {
        self.app = app
        _step = State(initialValue: Step(rawValue: UserDefaults.standard.integer(forKey: Self.stepKey)) ?? .welcome)
    }

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                ZStack {
                    Group {
                        switch step {
                        case .welcome: WelcomeStep(next: { go(.permission) })
                        case .permission: PermissionStep(model: app.agents, next: { go(.agents) })
                        case .agents: AgentsStep(model: app.agents, next: { go(.ready) })
                        case .ready: ReadyStep(app: app)
                        }
                    }
                    .id(step)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 28 : -28)),
                                            removal: .opacity.combined(with: .offset(x: forward ? -28 : 28))))
                }
                .frame(width: 540)
                Spacer(minLength: 20)
                footer
            }
        }
        .onAppear { app.agents.refresh() }
    }

    var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s == step ? Theme.accent : Color.white.opacity(s.rawValue < step.rawValue ? 0.32 : 0.12))
                        .frame(width: s == step ? 22 : 6, height: 6)
                }
            }
            .accessibilityElement().accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
            HStack {
                if let previous = Step(rawValue: step.rawValue - 1) {
                    Button { go(previous) } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(LinkButtonStyle())
                }
                Spacer()
                if step != .ready { Button("Skip setup") { app.finishOnboarding() }.buttonStyle(LinkButtonStyle()) }
            }
        }
        .padding(.horizontal, 28).padding(.bottom, 24)
    }

    func go(_ s: Step) {
        forward = s.rawValue > step.rawValue
        UserDefaults.standard.set(s.rawValue, forKey: Self.stepKey)
        withAnimation(.smooth(duration: 0.38)) { step = s }
    }
}

/// Title and one paragraph, centred; shared by every step.
private struct StepHeading: View {
    let title: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.system(size: 26, weight: .semibold)).tracking(-0.4).foregroundStyle(Theme.text)
            Text(text).font(.system(size: 13.5)).foregroundStyle(Theme.text2).multilineTextAlignment(.center).lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
        }
    }
}

private struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        VStack(spacing: 28) {
            DemoLoop().frame(width: 460)
            StepHeading(title: "Welcome to Glint",
                        text: "Record your screen once. Glint zooms in on what you click, cuts the pauses and steadies the cursor. Your coding agent can do the editing with you.")
            Button("Get Started", action: next).buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
        }
    }
}

private struct PermissionStep: View {
    let model: AgentsModel
    let next: () -> Void
    @State private var asked = false
    var body: some View {
        let allowed = model.screenRecordingAllowed
        VStack(spacing: 26) {
            IconTile(systemName: "rectangle.dashed.badge.record", size: 56, tint: allowed ? Theme.ok : Theme.accent)
            StepHeading(title: "Allow screen recording",
                        text: "macOS asks before any app can record the screen. Glint records only when you press Record or approve an agent's request.")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Screen & System Audio Recording").font(.system(size: 13, weight: .semibold))
                        Text("System Settings, Privacy & Security").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    Spacer(minLength: 12)
                    StatusPill(text: allowed ? "Allowed" : "Not allowed yet", tint: allowed ? Theme.ok : Theme.text3)
                }
                if asked && !allowed {
                    Divider().overlay(Theme.hairline)
                    HStack(spacing: 10) {
                        Text("Turned it on? macOS applies the change once Glint reopens. Setup continues from this step.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 12)
                        Button("Quit & Reopen") { AppModel.relaunch() }.buttonStyle(GhostButtonStyle())
                    }
                }
            }
            .padding(14).frame(width: 440).surface()
            VStack(spacing: 6) {
                if allowed {
                    Button("Continue", action: next).buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                } else {
                    Button("Allow Screen Recording") { asked = true; model.requestScreenRecording() }
                        .buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                    Button("Not now", action: next).buttonStyle(LinkButtonStyle())
                }
            }
        }
        .animation(.smooth(duration: 0.3), value: allowed)
        .animation(.smooth(duration: 0.3), value: asked)
    }
}

private struct AgentsStep: View {
    let model: AgentsModel
    let next: () -> Void
    var body: some View {
        VStack(spacing: 26) {
            IconTile(systemName: "terminal", size: 56, tint: Theme.accent)
            StepHeading(title: "Connect your agents",
                        text: "Claude Code, Codex and Claude Desktop can record, edit, narrate and render with Glint. They propose changes, and recording waits for your approval.")
            VStack(spacing: 0) {
                ForEach(Array(AgentClient.allCases.enumerated()), id: \.element) { i, c in
                    if i > 0 { Divider().overlay(Theme.hairline) }
                    row(c)
                }
            }
            .frame(width: 440).surface()
            VStack(spacing: 8) {
                Button("Continue", action: next).buttonStyle(PrimaryButtonStyle(large: true)).keyboardShortcut(.defaultAction)
                if let problem = model.locationProblem {
                    Text(problem).font(.system(size: 11.5)).foregroundStyle(Theme.speed).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
                } else {
                    Text("You can connect or disconnect agents later on Home.").font(.system(size: 11.5)).foregroundStyle(Theme.text3)
                }
            }
        }
    }

    func row(_ c: AgentClient) -> some View {
        let status = model.statuses.first { $0.client == c }
        let busy = model.busy.contains(c)
        return HStack(spacing: 12) {
            IconTile(systemName: c.symbol, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.title).font(.system(size: 13, weight: .semibold))
                if let m = model.messages[c], m.isError {
                    Text(m.text).font(.system(size: 11)).foregroundStyle(Theme.cut).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(c.scope).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if busy || status == nil {
                ProgressView().controlSize(.small)
            } else if status?.isConnected == true {
                StatusPill(text: "Connected", tint: Theme.ok)
            } else if model.connectable.contains(c) {
                Button("Connect") { model.connect(c) }.buttonStyle(GhostButtonStyle()).disabled(model.locationProblem != nil)
            } else {
                StatusPill(text: status?.state == .notInstalled ? "Not installed" : "Unavailable")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

private struct ReadyStep: View {
    let app: AppModel
    var body: some View {
        VStack(spacing: 28) {
            GlintMark(size: 56)
            StepHeading(title: "Make your first video", text: "Start with your own screen, or open a short sample to try the editor first.")
            HStack(spacing: 14) {
                ChoiceTile(systemImage: "record.circle", title: "Record your screen", text: "Pick a display or a window.", keys: "⇧⌘R") {
                    app.finishOnboarding(); app.showRecordSheet = true
                }
                ChoiceTile(systemImage: "play.rectangle", title: "Open the demo project", text: "A sample take, already edited.", keys: nil) {
                    app.finishOnboarding(); app.createDemo()
                }
            }
            Button("Go to my projects") { app.finishOnboarding() }.buttonStyle(LinkButtonStyle())
        }
    }
}

private struct ChoiceTile: View {
    let systemImage: String
    let title: String
    let text: String
    let keys: String?
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    IconTile(systemName: systemImage, size: 36, tint: hover ? Theme.accent : Theme.text2)
                    Spacer()
                    if let keys { Keycap(keys) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(text).font(.system(size: 12)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16).frame(width: 250, height: 132, alignment: .topLeading)
            .surface(radius: 14, fill: hover ? Theme.raised : Theme.panel, border: hover ? Theme.accent.opacity(0.55) : Theme.hairline)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .offset(y: hover ? -2 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.16), value: hover)
    }
}

extension AgentClient {
    var symbol: String {
        switch self {
        case .claudeCode: "terminal"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .claudeDesktop: "macwindow"
        }
    }
}

// MARK: - The welcome illustration

/// A small screen where the cursor clicks three things and the picture zooms in on each, with the matching zoom
/// blocks on a timeline underneath: what Glint does to a take. Holds still when Reduce Motion is on.
struct DemoLoop: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let targets = [UnitPoint(x: 0.31, y: 0.34), UnitPoint(x: 0.84, y: 0.15), UnitPoint(x: 0.64, y: 0.73)]
    private static let cycle = 3.0
    private static let clickAt = 0.9

    struct Pose { var index: Int; var cursor: UnitPoint; var zoom: Double; var ripple: Double? }

    static func pose(at t: Double) -> Pose {
        let i = Int(t / cycle) % targets.count
        let u = t - Double(Int(t / cycle)) * cycle
        let from = targets[(i + targets.count - 1) % targets.count], to = targets[i]
        let m = smooth(u / clickAt)
        let cursor = UnitPoint(x: from.x + (to.x - from.x) * m, y: from.y + (to.y - from.y) * m)
        let zoom = u < 2.3 ? smooth((u - clickAt - 0.05) / 0.55) : 1 - smooth((u - 2.3) / 0.55)
        let r = (u - clickAt) / 0.5
        return Pose(index: i, cursor: cursor, zoom: zoom, ripple: r >= 0 && r <= 1 ? r : nil)
    }

    static func smooth(_ x: Double) -> Double { let c = min(1, max(0, x)); return c * c * (3 - 2 * c) }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let total = Self.cycle * Double(Self.targets.count)
            let t = reduceMotion ? 1.7 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
            let pose = Self.pose(at: t)
            VStack(spacing: 10) {
                GeometryReader { g in
                    let w = g.size.width, h = g.size.height
                    let target = Self.targets[pose.index]
                    ZStack(alignment: .topLeading) {
                        MockScreen(targets: Self.targets, active: pose.zoom > 0.02 ? pose.index : nil)
                        if let r = pose.ripple {
                            Circle().strokeBorder(Theme.accent.opacity(1 - r), lineWidth: 1.5)
                                .frame(width: 10 + 34 * r, height: 10 + 34 * r)
                                .position(x: target.x * w, y: target.y * h)
                        }
                        CursorShape().fill(.white)
                            .overlay(CursorShape().stroke(Color.black.opacity(0.75), lineWidth: 1))
                            .frame(width: 12, height: 18)
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .offset(x: pose.cursor.x * w, y: pose.cursor.y * h)
                    }
                    .frame(width: w, height: h)
                    .scaleEffect(1 + 0.75 * pose.zoom, anchor: target)
                }
                .aspectRatio(16 / 9.4, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hairlineStrong))
                .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                MiniTimeline(progress: t / total, active: pose.zoom > 0.02 ? pose.index : nil,
                             blocks: Self.targets.indices.map { i in
                                 ((Double(i) * Self.cycle + Self.clickAt) / total, (Double(i) * Self.cycle + 2.85) / total)
                             })
                    .frame(height: 24)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Grey blocks standing in for an app window; the three targets are its buttons.
private struct MockScreen: View {
    let targets: [UnitPoint]
    let active: Int?
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                Theme.panel
                Rectangle().fill(Color.white.opacity(0.025)).frame(width: w * 0.2)
                ForEach(0..<6, id: \.self) { k in
                    block(0.035, 0.14 + 0.09 * Double(k), k % 2 == 0 ? 0.13 : 0.095, 0.03, k == 1 ? 0.16 : 0.07, w, h)
                }
                block(0.25, 0.11, 0.26, 0.05, 0.16, w, h)
                block(0.25, 0.2, 0.4, 0.028, 0.07, w, h)
                block(0.25, 0.46, 0.28, 0.42, 0.045, w, h, radius: 6)
                block(0.27, 0.5, 0.16, 0.03, 0.1, w, h)
                block(0.27, 0.57, 0.22, 0.024, 0.06, w, h)
                block(0.27, 0.63, 0.19, 0.024, 0.06, w, h)
                block(0.56, 0.46, 0.38, 0.42, 0.045, w, h, radius: 6)
                block(0.58, 0.5, 0.2, 0.03, 0.1, w, h)
                block(0.58, 0.57, 0.3, 0.024, 0.06, w, h)
                ForEach(Array(targets.enumerated()), id: \.offset) { i, p in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(active == i ? Theme.accent : Color.white.opacity(0.14))
                        .frame(width: w * 0.12, height: h * 0.07)
                        .position(x: p.x * w, y: p.y * h)
                }
            }
        }
    }

    func block(_ x: Double, _ y: Double, _ bw: Double, _ bh: Double, _ opacity: Double, _ w: Double, _ h: Double, radius: Double = 3) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.white.opacity(opacity))
            .frame(width: bw * w, height: bh * h).offset(x: x * w, y: y * h)
    }
}

private struct MiniTimeline: View {
    let progress: Double
    let active: Int?
    let blocks: [(Double, Double)]
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.04))
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.hairline)
                ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Theme.accent.opacity(active == i ? 0.95 : 0.3))
                        .frame(width: (b.1 - b.0) * w, height: h - 10)
                        .offset(x: b.0 * w, y: 5)
                }
                Capsule().fill(Color.white.opacity(0.9)).frame(width: 2, height: h).offset(x: progress * (w - 2))
            }
        }
    }
}

/// An arrow pointer with its tip at the top-left corner.
struct CursorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 12, sy = rect.height / 18
        let points: [(CGFloat, CGFloat)] = [(0, 0), (0, 15.5), (3.9, 12), (6.7, 18), (9, 17), (6.3, 11.2), (11.6, 11.2)]
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + points[0].0 * sx, y: rect.minY + points[0].1 * sy))
        for q in points.dropFirst() { p.addLine(to: CGPoint(x: rect.minX + q.0 * sx, y: rect.minY + q.1 * sy)) }
        p.closeSubpath()
        return p
    }
}
