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
    case failed(String)
    public var description: String {
        switch self {
        case .permissionDenied: return "Screen Recording permission is missing. Enable it for this app (or your terminal) in System Settings → Privacy & Security → Screen & System Audio Recording."
        case .sourceNotFound(let s): return "Capture source not found: \(s)"
        case .failed(let s): return "Recording failed: \(s)"
        }
    }
}

public enum Sources {
    public static var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    public static func shareable() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        catch {
            if !CGPreflightScreenCaptureAccess() { throw CaptureError.permissionDenied }
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
