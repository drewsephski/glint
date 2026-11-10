import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Listing sources can itself prompt. All passive callers (UI, preflight and agents) go through this gate.
/// Coalesce concurrent queries, and stop retrying a rejected grant until the person explicitly checks again
/// or we observe permission being revoked and granted. A Settings checkbox isn't proof that this build can capture.
actor ScreenRecordingAccess {
    static let shared = ScreenRecordingAccess()

    private let preflight: () -> Bool
    private let fetch: () async throws -> SCShareableContent
    private var pending: Task<SCShareableContent, Error>?
    private var rejectedGrant = false

    init(
        preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        fetch: @escaping () async throws -> SCShareableContent = {
            try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
    ) {
        self.preflight = preflight
        self.fetch = fetch
    }

    func allowRetry() {
        // Do not invalidate a query while its result is still being delivered to other callers.
        guard pending == nil else { return }
        rejectedGrant = false
    }

    func content() async throws -> SCShareableContent {
        guard preflight() else {
            rejectedGrant = false
            throw CaptureError.permissionDenied
        }
        guard !rejectedGrant else { throw CaptureError.permissionDenied }
        if let pending { return try await pending.value }
        let task = Task {
            do { return try await fetch() } catch {
                if Self.isPermissionError(error) { throw CaptureError.permissionDenied }
                throw error
            }
        }
        pending = task
        defer { pending = nil }
        do { return try await task.value } catch {
            if case CaptureError.permissionDenied = error {
                rejectedGrant = true
                throw CaptureError.permissionDenied
            }
            // In particular, cancellation and failures of picker-authorized streams aren't permission denials.
            throw error
        }
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.userDeclined.rawValue
    }
}
