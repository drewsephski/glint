import Foundation
import ScreenCaptureKit
import Testing

@testable import GlintCapture

/// No test calls TCC or captures real content. Inject both the passive check and the potentially prompting query.
private final class PermissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var granted = false
    private var checks = 0
    private var queries = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var allowed: Bool {
        get { lock.withLock { granted } }
        set { lock.withLock { granted = newValue } }
    }
    var queryCount: Int { lock.withLock { queries } }
    func check() -> Bool {
        lock.withLock {
            checks += 1
            let ready = waiters.filter { checks >= $0.0 }
            waiters.removeAll { checks >= $0.0 }
            for waiter in ready { waiter.1.resume() }
            return granted
        }
    }
    func queried() { lock.withLock { queries += 1 } }
    func waitForChecks(_ count: Int) async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if checks >= count { continuation.resume() } else { waiters.append((count, continuation)) }
            }
        }
    }
}

private func denied(_ access: ScreenRecordingAccess) async -> Bool {
    do {
        _ = try await access.content()
        return false
    } catch CaptureError.permissionDenied { return true } catch { return false }
}

@Test func passiveChecksNeverEnumerateWithoutPermission() async {
    let probe = PermissionProbe()
    let access = ScreenRecordingAccess(preflight: probe.check) {
        probe.queried()
        throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
    }
    for _ in 0..<5 { #expect(await denied(access)) }
    await access.allowRetry()
    #expect(await denied(access))
    #expect(probe.queryCount == 0)
}

@Test func rejectedGrantDoesNotLoopAndExplicitRetryIsBounded() async {
    let probe = PermissionProbe()
    probe.allowed = true
    let access = ScreenRecordingAccess(preflight: probe.check) {
        probe.queried()
        throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
    }
    for _ in 0..<5 { #expect(await denied(access)) }
    #expect(probe.queryCount == 1)
    await access.allowRetry()
    #expect(await denied(access))
    #expect(await denied(access))
    #expect(probe.queryCount == 2)
    probe.allowed = false
    #expect(await denied(access))
    probe.allowed = true
    #expect(await denied(access))
    #expect(probe.queryCount == 3)
}

@Test func concurrentChecksShareOneQueryAndSamePermissionError() async {
    let probe = PermissionProbe()
    probe.allowed = true
    let access = ScreenRecordingAccess(preflight: probe.check) {
        probe.queried()
        await probe.waitForChecks(2)
        throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.userDeclined.rawValue)
    }
    async let first = denied(access)
    async let second = denied(access)
    #expect(await first)
    #expect(await second)
    #expect(probe.queryCount == 1)
}

@Test func unrelatedCaptureErrorsArePreservedAndCanRetry() async {
    let probe = PermissionProbe()
    probe.allowed = true
    let access = ScreenRecordingAccess(preflight: probe.check) {
        probe.queried()
        throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.internalError.rawValue)
    }
    for _ in 0..<2 {
        do {
            _ = try await access.content()
            Issue.record("Expected stream failure")
        } catch {
            #expect((error as NSError).code == SCStreamError.internalError.rawValue)
            #expect(!ScreenRecordingAccess.isPermissionError(error))
        }
    }
    #expect(probe.queryCount == 2)
    #expect(!ScreenRecordingAccess.isPermissionError(NSError(domain: "OtherDomain", code: SCStreamError.userDeclined.rawValue)))
}

@Test func canceledCaptureCheckDoesNotPoisonPermission() async {
    let probe = PermissionProbe()
    probe.allowed = true
    let access = ScreenRecordingAccess(preflight: probe.check) {
        probe.queried()
        throw CancellationError()
    }
    for _ in 0..<2 {
        do {
            _ = try await access.content()
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
    }
    #expect(probe.queryCount == 2)
}

@Test func grantAndRevocationChangeWhetherSourcesAreQueried() async {
    let probe = PermissionProbe()
    let access = ScreenRecordingAccess(preflight: probe.check) {
        probe.queried()
        throw NSError(domain: "TestSourceQuery", code: 1)
    }
    #expect(await denied(access))
    #expect(probe.queryCount == 0)
    probe.allowed = true
    #expect(!(await denied(access)))
    #expect(probe.queryCount == 1)
    probe.allowed = false
    #expect(await denied(access))
    #expect(probe.queryCount == 1)
    probe.allowed = true
    #expect(!(await denied(access)))
    #expect(probe.queryCount == 2)
}
