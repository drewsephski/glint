import SwiftUI
@preconcurrency import AVFoundation
import GlintCore
import GlintCapture

/// Live picture from a capture session, filling its frame and mirrored like the facecam's default.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        let v = MirroredPreviewView()
        v.layer = layer
        v.wantsLayer = true
        v.mirror()
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        guard let layer = v.layer as? AVCaptureVideoPreviewLayer else { return }
        if layer.session !== session { layer.session = session }
        (v as? MirroredPreviewView)?.mirror()
    }
}

private final class MirroredPreviewView: NSView {
    /// The connection only exists once the session has an input, so this is called again on every update.
    func mirror() {
        guard let c = (layer as? AVCaptureVideoPreviewLayer)?.connection, c.isVideoMirroringSupported else { return }
        c.automaticallyAdjustsVideoMirroring = false
        c.isVideoMirrored = true
    }
    override var mouseDownCanMoveWindow: Bool { true }
}

/// The camera shown in the record sheet before a take, so you can check the framing. It is its own session: the
/// recording opens the camera again when it starts.
@MainActor @Observable
final class CameraPreviewModel {
    let session = AVCaptureSession()
    private(set) var devices: [CameraDevice] = []
    private(set) var showing: String?
    /// Bumped when the picture changes, so the preview view re-applies mirroring to the new connection.
    private(set) var generation = 0
    private let queue = DispatchQueue(label: "glint.camera.preview", qos: .userInitiated)

    func refreshDevices() { devices = Cameras.list() }

    /// The ID to record with: the chosen camera if it is still connected, else the system's preferred one (nil).
    func resolved(_ id: String) -> String? { devices.contains { $0.id == id } ? id : nil }

    func show(deviceID: String?) {
        let key = deviceID ?? ""
        guard showing != key else { return }
        showing = key
        let s = session
        queue.async {
            guard let device = Cameras.device(id: deviceID), let input = try? AVCaptureDeviceInput(device: device) else { return }
            s.beginConfiguration()
            for i in s.inputs { s.removeInput(i) }
            if s.canAddInput(input) { s.addInput(input) }
            s.commitConfiguration()
            if !s.isRunning { s.startRunning() }
            Task { @MainActor in self.generation += 1 }
        }
    }

    func stop() {
        showing = nil
        let s = session
        queue.async {
            if s.isRunning { s.stopRunning() }
            for i in s.inputs { s.removeInput(i) }
        }
    }
}

/// Picks the corner of the canvas the facecam sits in.
struct CornerPicker: View {
    let selection: FacecamStyle.Corner
    let onSelect: (FacecamStyle.Corner) -> Void

    var body: some View {
        Grid(horizontalSpacing: 3, verticalSpacing: 3) {
            GridRow { cell(.topLeft, "Top left", .topLeading); cell(.topRight, "Top right", .topTrailing) }
            GridRow { cell(.bottomLeft, "Bottom left", .bottomLeading); cell(.bottomRight, "Bottom right", .bottomTrailing) }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func cell(_ corner: FacecamStyle.Corner, _ label: String, _ alignment: Alignment) -> some View {
        let on = corner == selection
        return RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(on ? Color.white.opacity(0.13) : Color.clear)
            .frame(width: 34, height: 22)
            .overlay(alignment: alignment) { Circle().fill(on ? Theme.accent : Theme.text3).frame(width: 7, height: 7).padding(4) }
            .contentShape(Rectangle())
            .onTapGesture { if !on { onSelect(corner) } }
            .help(label)
            .accessibilityLabel(label)
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
