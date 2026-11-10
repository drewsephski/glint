import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import GlintCore

public struct CaptureSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case display, window }
    public var kind: Kind
    public var id: UInt32
    public var name: String
    public var app: String?
    public var bundleID: String?
    /// Frame in global points, top-left origin.
    public var frame: [Double]
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var scale: Double
    public var isMain: Bool?
}

public enum CaptureError: Error, CustomStringConvertible {
    case permissionDenied
    case sourceNotFound(String)
    case cameraDenied
    case cameraNotFound(String)
    case microphoneDenied
    case failed(String)
    public var description: String {
        switch self {
        case .permissionDenied:
            if Bundle.main.bundleURL.pathExtension == "app" {
                let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "Glint"
                return "Screen Recording access is unavailable to \(name). Check this copy in System Settings › Privacy & Security › Screen & System Audio Recording, then check again. If already enabled, reopen the app; a different copy or changed signing identity can have a different grant. You can also choose content with the System picker. App: \(Bundle.main.bundleURL.path)"
            }
            return "Screen Recording access is unavailable to this process. Check the app running glint (your terminal or agent app) in System Settings › Privacy & Security › Screen & System Audio Recording, then restart that app if needed."
        case .sourceNotFound(let s): return "Capture source not found: \(s)"
        case .cameraDenied:
            if Bundle.main.bundleURL.pathExtension == "app" {
                return "Glint isn't allowed to use the camera. Turn on Glint in System Settings › Privacy & Security › Camera, or record without the camera."
            }
            return "This process isn't allowed to use the camera. Turn on Camera for the app running glint (your terminal or agent app) in System Settings › Privacy & Security › Camera, or record without the camera."
        case .cameraNotFound(let s):
            if s.isEmpty { return "No camera found. Connect one, or record without the camera." }
            let names = Cameras.list().map { "\($0.name) (\($0.id))" }
            return "Camera not found: \(s). " + (names.isEmpty ? "No cameras are connected; record without the camera." : "Available: \(names.joined(separator: ", ")). `glint sources --cameras` lists them.")
        case .microphoneDenied:
            if Bundle.main.bundleURL.pathExtension == "app" {
                return "Glint isn't allowed to use the microphone. Turn on Glint in System Settings › Privacy & Security › Microphone, or record without the microphone."
            }
            return "This process isn't allowed to use the microphone. Turn on Microphone for the app running glint (your terminal or agent app) in System Settings › Privacy & Security › Microphone, or record without the microphone."
        case .failed(let s): return "Recording failed: \(s)"
        }
    }
}

public enum Sources {
    public static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Only call for an explicit user retry, never on activation or from agent polling.
    public static func retryScreenRecordingAccess() async { await ScreenRecordingAccess.shared.allowRetry() }

    public static func shareable() async throws -> SCShareableContent {
        do { return try await ScreenRecordingAccess.shared.content() }
        catch {
            if error is CancellationError { throw error }
            if let error = error as? CaptureError { throw error }
            if ScreenRecordingAccess.isPermissionError(error) { throw CaptureError.permissionDenied }
            throw CaptureError.failed(error.localizedDescription)
        }
    }

    static func pixelSize(_ displayID: CGDirectDisplayID) -> (Int, Int, Double) {
        let bounds = CGDisplayBounds(displayID)
        if let mode = CGDisplayCopyDisplayMode(displayID) {
            let s = Double(mode.pixelWidth) / max(1, bounds.width)
            return (mode.pixelWidth, mode.pixelHeight, s)
        }
        return (Int(bounds.width), Int(bounds.height), 1)
    }

    public static func list() async throws -> [CaptureSource] {
        let content = try await shareable()
        let main = CGMainDisplayID()
        var out: [CaptureSource] = content.displays.map { d in
            let b = CGDisplayBounds(d.displayID)
            let (pw, ph, s) = pixelSize(d.displayID)
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == d.displayID }?.localizedName ?? "Display \(d.displayID)"
            return CaptureSource(kind: .display, id: d.displayID, name: name, app: nil, bundleID: nil,
                                 frame: [b.origin.x, b.origin.y, b.width, b.height], pixelWidth: pw, pixelHeight: ph, scale: s, isMain: d.displayID == main)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for w in content.windows where w.isOnScreen && w.windowLayer == 0 && w.frame.width >= 120 && w.frame.height >= 80 && w.owningApplication?.processID != ownPID {
            let scale = NSScreen.screens.first { $0.frame.intersects(w.frame) }?.backingScaleFactor ?? 2
            out.append(CaptureSource(kind: .window, id: w.windowID, name: w.title?.isEmpty == false ? w.title! : (w.owningApplication?.applicationName ?? "Window"),
                                     app: w.owningApplication?.applicationName, bundleID: w.owningApplication?.bundleIdentifier,
                                     frame: [w.frame.origin.x, w.frame.origin.y, w.frame.width, w.frame.height],
                                     pixelWidth: Int(w.frame.width * scale), pixelHeight: Int(w.frame.height * scale), scale: Double(scale), isMain: nil))
        }
        return out
    }
}
