import SwiftUI
import GlintCore

/// One accent (light blue), neutral surfaces, system fonts. Lane colours are the only other hues and they mean one
/// thing each: zoom, cut, speed, caption, voice.
enum Theme {
    static let accent = Color(red: 0.45, green: 0.74, blue: 1.0)          // light blue
    static let accentStrong = Color(red: 0.24, green: 0.60, blue: 0.96)
    static let onAccent = Color(red: 0.04, green: 0.10, blue: 0.18)
    // Three surface levels: the window, panels resting on it, and controls raised from a panel.
    static let canvas = Color(red: 0.063, green: 0.067, blue: 0.078)
    static let panel = Color(red: 0.094, green: 0.098, blue: 0.114)
    static let raised = Color(red: 0.137, green: 0.143, blue: 0.163)
    static let well = Color.black.opacity(0.26)
    static let hairline = Color.white.opacity(0.075)
    static let hairlineStrong = Color.white.opacity(0.14)
    static let text = Color.white.opacity(0.93)
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
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised.opacity(0.5)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }
}

extension View {
    /// A panel resting on the window: filled, hairline border, a soft shadow underneath.
    func surface(radius: CGFloat = 12, fill: Color = Theme.panel, border: Color = Theme.hairline) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill).shadow(color: .black.opacity(0.22), radius: 10, y: 4))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border))
    }
}

/// Tracks the pointer for a control's hover state (button styles can't hold state themselves).
struct Hoverable<Content: View>: View {
    @State private var hover = false
    @ViewBuilder var content: (Bool) -> Content
    var body: some View { content(hover).onHover { hover = $0 } }
}

/// The app's mark: a light-blue tile, a dark screen, one dot.
struct GlintMark: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(Theme.accent)
            RoundedRectangle(cornerRadius: size * 0.11, style: .continuous).fill(Theme.onAccent)
                .frame(width: size * 0.62, height: size * 0.42)
            Circle().fill(Theme.accent).frame(width: size * 0.14, height: size * 0.14)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A symbol on a small raised tile; the leading element of rows and empty states.
struct IconTile: View {
    let systemName: String
    var size: CGFloat = 32
    var tint: Color = Theme.text2
    var body: some View {
        Image(systemName: systemName).font(.system(size: size * 0.42, weight: .medium)).foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(Color.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// A state in a few words: a dot and a label on a tinted capsule. Muted states stay grey.
struct StatusPill: View {
    let text: String
    var tint: Color = Theme.text3
    var body: some View {
        let muted = tint == Theme.text3
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(muted ? Theme.text3 : tint)
        }
        .padding(.horizontal, 7).padding(.vertical, 2.5)
        .background(Capsule().fill(muted ? Color.white.opacity(0.05) : tint.opacity(0.12)))
        .fixedSize()
    }
}

/// A keyboard shortcut drawn as keys.
struct Keycap: View {
    let keys: String
    init(_ keys: String) { self.keys = keys }
    var body: some View {
        Text(keys).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// The label of a pull-down menu, drawn like a ghost button (menus don't take button styles).
struct MenuChip: View {
    var title: String?
    var systemImage: String?
    @State private var hover = false
    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 12, weight: .semibold)) }
            if let title { Text(title).font(.system(size: 12.5, weight: .medium)) }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, title == nil ? 0 : 11).frame(minWidth: 28).frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(hover ? 0.11 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.hairline))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

/// A segmented control whose selection slides between segments.
struct Segmented<T: Hashable>: View {
    let items: [(value: T, title: String)]
    @Binding var selection: T
    var compact = false
    @Namespace private var ns
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection
                Text(item.title)
                    .font(.system(size: compact ? 11.5 : 12, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Theme.text : Theme.text2).lineLimit(1)
                    .frame(maxWidth: .infinity).frame(height: compact ? 22 : 26)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.13))
                                .matchedGeometryEffect(id: "selection", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.snappy(duration: 0.22)) { selection = item.value } }
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
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
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: large ? 10 : 8, style: .continuous)
        Hoverable { hover in
            configuration.label
                .font(.system(size: large ? 14 : 13, weight: .semibold))
                .padding(.horizontal, large ? 22 : 14).frame(height: large ? 38 : 30)
                .background(shape.fill(enabled ? Theme.accent : Theme.accent.opacity(0.3)))
                .overlay(shape.fill(Color.white.opacity(enabled && hover ? 0.16 : 0)))
                .overlay(shape.strokeBorder(Color.white.opacity(enabled ? 0.2 : 0.04), lineWidth: 0.5))
                .foregroundStyle(Theme.onAccent.opacity(enabled ? 1 : 0.6))
                .shadow(color: .black.opacity(enabled ? 0.28 : 0), radius: 2, y: 1)
                .contentShape(shape)
                .scaleEffect(configuration.isPressed ? 0.975 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

struct GhostButtonStyle: ButtonStyle {
    var large = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: large ? 10 : 7, style: .continuous)
        Hoverable { hover in
            configuration.label
                .font(.system(size: large ? 14 : 12.5, weight: .medium))
                .padding(.horizontal, large ? 20 : 11).frame(height: large ? 38 : 28)
                .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.15 : hover && enabled ? 0.11 : 0.06)))
                .overlay(shape.strokeBorder(Theme.hairline))
                .foregroundStyle(Theme.text)
                .opacity(enabled ? 1 : 0.45)
                .contentShape(shape)
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// Square icon-only button for toolbars.
struct IconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Hoverable { hover in
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 28, height: 28)
                .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.15 : hover && enabled ? 0.11 : 0.06)))
                .overlay(shape.strokeBorder(Theme.hairline))
                .foregroundStyle(Theme.text)
                .opacity(enabled ? 1 : 0.4)
                .contentShape(shape)
                .animation(.easeOut(duration: 0.12), value: hover)
        }
    }
}

/// Text-only button for the quiet way out of a step ("Not now", "Skip").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Hoverable { hover in
            configuration.label
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hover ? Theme.text : Theme.text2)
                .padding(.horizontal, 8).frame(height: 28)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.7 : 1)
        }
    }
}
