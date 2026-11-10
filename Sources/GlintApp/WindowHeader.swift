import AppKit
import SwiftUI

/// Native window interactions for the empty space behind a custom SwiftUI header.
/// Foreground controls keep receiving their own clicks; zoom targets this view's window.
struct WindowHeader: NSViewRepresentable {
    func makeNSView(context: Context) -> HeaderView { HeaderView() }
    func updateNSView(_ view: HeaderView, context: Context) {}

    final class HeaderView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) {
            guard let window, !window.styleMask.contains(.fullScreen) else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}
