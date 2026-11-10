import SwiftUI
import GlintCore

/// One accent (light blue), neutral surfaces, system fonts. Lane colours are the only other hues and they mean one
/// thing each: zoom, cut, speed, caption, voice.
enum Theme {
    static let accent = Color(red: 0.45, green: 0.74, blue: 1.0)          // light blue
    static let accentStrong = Color(red: 0.24, green: 0.60, blue: 0.96)
    static let onAccent = Color(red: 0.04, green: 0.10, blue: 0.18)
    static let canvas = Color(red: 0.082, green: 0.086, blue: 0.098)
    static let panel = Color(red: 0.110, green: 0.115, blue: 0.130)
    static let raised = Color(red: 0.150, green: 0.157, blue: 0.176)
    static let hairline = Color.white.opacity(0.08)
    static let text = Color.white.opacity(0.92)
    static let text2 = Color.white.opacity(0.64)
    static let text3 = Color.white.opacity(0.42)
    static let zoom = accent
    static let cut = Color(red: 0.96, green: 0.42, blue: 0.42)
    static let speed = Color(red: 0.98, green: 0.70, blue: 0.32)
    static let caption = Color(red: 0.40, green: 0.80, blue: 0.70)
    static let voice = Color(red: 0.72, green: 0.62, blue: 1.0)
    static let agent = accent
    static let ok = Color(red: 0.40, green: 0.80, blue: 0.52)

    static func color(_ c: RGBA) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }

    static func time(_ t: Double, precise: Bool = false) -> String {
        let s = max(0, t)
        let m = Int(s) / 60, sec = s - Double(m * 60)
        return precise ? String(format: "%d:%05.2f", m, sec) : String(format: "%d:%02d", m, Int(sec))
    }

    /// Icon for who made an edit: agents are a terminal prompt, Glint's own planners a gear, people a person.
    static func authorIcon(_ kind: Author.Kind) -> String { kind == .agent ? "terminal" : kind == .system ? "gearshape" : "person" }
    static func originIcon(_ o: Origin) -> String { o == .agent ? "terminal" : o == .auto ? "gearshape" : "hand.tap" }
}

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text3) }
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.text2)
            Spacer()
        }
        .padding(.top, 6)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.raised.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Short explanatory text under a control.
struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 11)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true) }
}

/// A slider that edits locally while dragging and commits once on release (one undo step per gesture).
struct CommitSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let onCommit: (Double) -> Void
    @State private var local: Double?
    @State private var lastCommitted: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2)
                Spacer()
                Text(format(local ?? value)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
            }
            Slider(value: Binding(get: { local ?? value }, set: { local = $0 }), in: range) { editing in
                // macOS can report the end of a gesture twice; commit each value once.
                guard !editing, let v = local else { return }
                let out = step.map { (v / $0).rounded() * $0 } ?? v
                local = nil
                guard out != lastCommitted, abs(out - value) > 1e-9 else { return }
                lastCommitted = out
                onCommit(out)
            }
            .controlSize(.small)
            .tint(Theme.accent)
        }
    }
}

struct AuthorBadge: View {
    let author: Author
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: Theme.authorIcon(author.kind)).font(.system(size: 9, weight: .semibold))
            Text(author.kind == .agent ? author.name : author.kind == .user ? "You" : "Glint").font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(author.kind == .agent ? Theme.agent.opacity(0.16) : Color.white.opacity(0.08)))
        .foregroundStyle(author.kind == .agent ? Theme.agent : Theme.text2)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(enabled ? Theme.accent : Theme.accent.opacity(0.35)))
            .foregroundStyle(Theme.onAccent.opacity(enabled ? 1 : 0.7))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
            .foregroundStyle(Theme.text)
    }
}

/// Square icon-only button for toolbars.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.07)))
            .foregroundStyle(Theme.text)
    }
}
