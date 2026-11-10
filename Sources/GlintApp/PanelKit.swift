import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers
import GlintCore

// Small building blocks shared by the sidebar panels (Media, Captions, Recipe, Jobs, overlay inspectors).

/// File dialogs. Both run modally on the main thread, like the rest of the app's panels.
@MainActor
enum FilePick {
    static let movieTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .video]
    static let audioTypes: [UTType] = [.audio, .mp3, .wav, .aiff, .mpeg4Audio]
    static let subtitleTypes: [UTType] = [UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText, .plainText]

    static func open(_ types: [UTType], multiple: Bool = false, message: String? = nil) -> [URL] {
        let p = NSOpenPanel()
        p.allowedContentTypes = types
        p.allowsMultipleSelection = multiple
        p.canChooseDirectories = false
        p.canChooseFiles = true
        if let message { p.message = message }
        return p.runModal() == .OK ? p.urls : []
    }

    static func save(suggestedName: String, type: UTType? = nil) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = suggestedName
        if let type { p.allowedContentTypes = [type] }
        p.canCreateDirectories = true
        return p.runModal() == .OK ? p.url : nil
    }

    static func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    /// True for files a drop or panel should treat as a movie.
    static func isMovie(_ url: URL) -> Bool {
        guard let t = UTType(filenameExtension: url.pathExtension) else { return false }
        return t.conforms(to: .movie) || t.conforms(to: .video)
    }
}

extension RGBA {
    init(_ c: Color) {
        let n = NSColor(c).usingColorSpace(.sRGB) ?? .white
        self.init(Double(n.redComponent), Double(n.greenComponent), Double(n.blueComponent), Double(n.alphaComponent))
    }
    /// "#RRGGBB", or "#RRGGBBAA" when the colour is translucent (both accepted by edit operations).
    var hexWithAlpha: String {
        a >= 0.999 ? hex : hex + String(format: "%02X", Int((a * 255).rounded()))
    }
}

/// A colour well that commits once the person stops changing it (one undo step, not one per drag tick).
struct ColorField: View {
    let label: String
    let color: RGBA
    var supportsOpacity = false
    let onCommit: (String) -> Void
    @State private var local: Color?
    @State private var pending: Task<Void, Never>?

    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Spacer()
            ColorPicker(label, selection: Binding(get: { local ?? Theme.color(color) }, set: { c in
                local = c
                pending?.cancel()
                pending = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 450_000_000)
                    guard !Task.isCancelled else { return }
                    let v = RGBA(c)
                    local = nil
                    if v.hexWithAlpha != color.hexWithAlpha { onCommit(supportsOpacity ? v.hexWithAlpha : v.hex) }
                }
            }), supportsOpacity: supportsOpacity)
            .labelsHidden()
            .frame(width: 44)
        }
    }
}

/// A time value with nudge buttons and a typed field. Commits once per change.
struct TimeStepper: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    let onCommit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Spacer(minLength: 4)
            Button { commit(value - step) } label: { Image(systemName: "minus").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(MiniButtonStyle()).disabled(value - step < range.lowerBound - 1e-9).help("Earlier by \(step.formatted())s")
            TextField("", text: $text)
                .textFieldStyle(.plain).font(.system(size: 11.5).monospacedDigit()).multilineTextAlignment(.center)
                .frame(width: 62).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline))
                .focused($focused)
                .onSubmit { commitText() }
                .onChange(of: focused) { _, f in if !f { commitText() } }
                .accessibilityLabel(label)
            Button { commit(value + step) } label: { Image(systemName: "plus").font(.system(size: 9, weight: .bold)) }
                .buttonStyle(MiniButtonStyle()).disabled(value + step > range.upperBound + 1e-9).help("Later by \(step.formatted())s")
        }
        .onAppear { text = Self.format(value) }
        .onChange(of: value) { _, v in if !focused { text = Self.format(v) } }
    }

    static func format(_ v: Double) -> String { Theme.time(v, precise: true) }

    /// Accepts "12.5", "0:12.5" or "1:02:03".
    static func parse(_ s: String) -> Double? {
        let parts = s.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0.replacingOccurrences(of: ",", with: ".")) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(where: { $0 == nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    func commitText() {
        guard let v = Self.parse(text) else { text = Self.format(value); return }
        commit(v)
    }

    func commit(_ v: Double) {
        let c = min(range.upperBound, max(range.lowerBound, v))
        text = Self.format(c)
        guard abs(c - value) > 1e-6 else { return }
        onCommit(c)
    }
}

/// A text field that commits on Return or when it loses focus, and follows outside changes while not editing.
struct CommitTextField: View {
    let placeholder: String
    let value: String
    var axis: Axis = .horizontal
    var lineLimit: ClosedRange<Int> = 1...1
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .textFieldStyle(.plain).font(.system(size: 12)).lineLimit(lineLimit)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.well))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.5) : Theme.hairline))
            .focused($focused)
            .onSubmit { commit() }
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onAppear { text = value }
            .onChange(of: value) { _, v in if !focused { text = v } }
    }

    func commit() { if text != value { onCommit(text) } }
}

/// Tiny square button for steppers and row actions.
struct MiniButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        Hoverable { hover in
            configuration.label
                .frame(width: 20, height: 20)
                .background(shape.fill(Color.white.opacity(configuration.isPressed ? 0.15 : hover && enabled ? 0.11 : 0.06)))
                .overlay(shape.strokeBorder(Theme.hairline))
                .foregroundStyle(Theme.text)
                .opacity(enabled ? 1 : 0.35)
                .contentShape(shape)
        }
    }
}

/// A quiet text action in a section header ("Re-analyze", "Add").
struct HeaderAction: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
                Text(title)
            }
        }
        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accent)
    }
}

/// A selectable list row: tinted when selected, faint on hover.
struct ListRow<Content: View>: View {
    var selected = false
    var tint: Color = Theme.accent
    let action: () -> Void
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? tint.opacity(0.14) : hover ? Color.white.opacity(0.045) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(selected ? tint.opacity(0.35) : Color.clear))
            .contentShape(Rectangle())
            .onTapGesture(perform: action)
            .onHover { hover = $0 }
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small tag (scene name, kind) on a row.
struct Tag: View {
    let text: String
    var tint: Color = Theme.text2
    init(_ text: String, tint: Color = Theme.text2) { self.text = text; self.tint = tint }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .background(Capsule().fill(tint == Theme.text2 ? Color.white.opacity(0.07) : tint.opacity(0.14)))
            .foregroundStyle(tint)
            .fixedSize()
    }
}

/// An inline error under a control, dismissable.
struct InlineError: View {
    let text: String
    var onDismiss: (() -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(Theme.cut).padding(.top, 1)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.system(size: 8.5, weight: .bold)) }.buttonStyle(.plain).foregroundStyle(Theme.text3)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.cut.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.cut.opacity(0.22)))
    }
}

/// Shown while a slow step runs: a spinner and what's happening.
struct WorkingRow: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
        }
    }
}

/// Wraps its children onto as many lines as needed (transcript words).
struct FlowLayout: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { y += line + lineSpacing; x = 0; line = 0 }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { y += line + lineSpacing; x = bounds.minX; line = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

/// A frame of a movie file at a file time, loaded off the main thread.
struct MovieThumb: View {
    let url: URL
    let time: Double
    var width: CGFloat = 64
    var height: CGFloat = 40
    @State private var image: CGImage?
    var body: some View {
        ZStack {
            Theme.raised
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
            else { Image(systemName: "film").font(.system(size: 11)).foregroundStyle(Theme.text3) }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Theme.hairline))
        .task(id: "\(url.path)@\(time)") {
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            g.maximumSize = CGSize(width: width * 3, height: height * 3)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
            g.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
            image = try? await g.image(at: CMTime(seconds: time, preferredTimescale: 600)).image
        }
    }
}

extension String {
    /// A stable, readable identifier from a title: "Invite a teammate" → "invite-a-teammate".
    var slug: String {
        let folded = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var out = ""
        var dash = false
        for ch in folded {
            if ch.isLetter && ch.isASCII || ch.isNumber && ch.isASCII { out.append(ch); dash = false }
            else if !dash, !out.isEmpty { out.append("-"); dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }
}
