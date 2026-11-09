import SwiftUI
import GlintCore

enum Theme {
    static let accent = Color(red: 0.55, green: 0.42, blue: 1.0)
    static let accent2 = Color(red: 1.0, green: 0.48, blue: 0.42)
    static let brand = LinearGradient(colors: [accent, accent2], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.094)
    static let panel = Color(red: 0.105, green: 0.11, blue: 0.13)
    static let raised = Color(red: 0.145, green: 0.15, blue: 0.175)
    static let hairline = Color.white.opacity(0.07)
    static let text2 = Color.white.opacity(0.62)
    static let text3 = Color.white.opacity(0.4)
    static let zoom = Color(red: 0.55, green: 0.45, blue: 1.0)
    static let cut = Color(red: 1.0, green: 0.35, blue: 0.38)
    static let speed = Color(red: 1.0, green: 0.66, blue: 0.25)
    static let caption = Color(red: 0.3, green: 0.78, blue: 0.68)
    static let agent = Color(red: 0.42, green: 0.75, blue: 1.0)

    static func color(_ c: RGBA) -> Color { Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }

    static func time(_ t: Double, precise: Bool = false) -> String {
        let s = max(0, t)
        let m = Int(s) / 60, sec = s - Double(m * 60)
        return precise ? String(format: "%d:%05.2f", m, sec) : String(format: "%d:%02d", m, Int(sec))
    }
}

struct SectionHeader: View {
    let title: String
    var systemImage: String?
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text3) }
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.text3)
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2)
                Spacer()
                Text(format(local ?? value)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text3)
            }
            Slider(value: Binding(get: { local ?? value }, set: { local = $0 }), in: range) { editing in
                if !editing, let v = local { onCommit(step.map { (v / $0).rounded() * $0 } ?? v); local = nil }
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
            Image(systemName: author.kind == .agent ? "sparkles" : author.kind == .system ? "gearshape" : "person.fill")
                .font(.system(size: 9, weight: .bold))
            Text(author.kind == .agent ? author.name : author.kind == .user ? "You" : "Glint").font(.system(size: 10.5, weight: .medium))
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(author.kind == .agent ? Theme.agent.opacity(0.18) : Color.white.opacity(0.08)))
        .foregroundStyle(author.kind == .agent ? Theme.agent : Theme.text2)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(Theme.brand))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .shadow(color: Theme.accent.opacity(0.35), radius: 8, y: 2)
    }
}

struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.14 : 0.08)))
            .foregroundStyle(.white.opacity(0.9))
    }
}
