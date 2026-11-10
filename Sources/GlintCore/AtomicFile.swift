import Foundation

/// Stage beside the destination so the final rename is atomic, even when the source is on another volume.
public enum AtomicFile {
    public static func copy(_ source: URL, to destination: URL, replacing: Bool = true) throws {
        try copy(source, to: destination, replacing: replacing, stage: { try FileManager.default.copyItem(at: $0, to: $1) })
    }

    static func copy(_ source: URL, to destination: URL, replacing: Bool = true, stage: (URL, URL) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".glint-export-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try stage(source, temporary)
        // POSIX rename replaces a file in one filesystem operation; the old file survives every preceding failure.
        let result = replacing ? rename(temporary.path, destination.path) : renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: destination.path])
        }
    }
}
