import Foundation
import Darwin
import GlintCore

/// Agents record through Glint.app, not through the process that hosts the MCP server.
///
/// macOS grants Screen Recording to the *responsible* process: for `glint mcp` that is the terminal, Codex or
/// Claude, so each of those would have to be granted Screen Recording separately, under its own name. Instead, the MCP server forwards the
/// tools that touch the screen to the running Glint app over a user-only Unix socket. The app runs them with the
/// same tool registry and approval store, so permission is granted once, to Glint, and the recording shows up in the
/// app (banner, menu bar, Stop button) while the agent drives it. Everything else (editing, rendering, inspection)
/// still runs in the MCP process.
public enum CaptureBroker {
    /// Tools that need Screen Recording permission or own a live recording session.
    public static let forwardedTools: Set<String> = ["glint_list_sources", "glint_record_start", "glint_record_status",
                                                     "glint_record_mark", "glint_record_action", "glint_record_stop",
                                                     "glint_record_pause", "glint_record_resume", "glint_record_preflight"]
    /// Tools that may start talking to the app (the others follow wherever the session lives). Preflight opens it
    /// because the permission it checks is the app's.
    static let openingTools: Set<String> = ["glint_list_sources", "glint_record_start", "glint_record_preflight"]

    /// `<support>/agent.sock`, or, when that would exceed the 104-byte socket path limit, a socket in the per-user
    /// temporary folder macOS creates with mode 0700 (`/var/folders/…/T/`), never a shared directory like /tmp.
    public static var socketPath: String {
        let support = GlintPaths.support
        let p = support.appendingPathComponent("agent.sock").path
        if p.utf8.count < 100 { return p }
        return userTempDirectory() + "glint-\(String(fnv1a(support.path), radix: 16)).sock"
    }

    static func userTempDirectory() -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        let dir = n > 0 ? String(cString: buf) : NSTemporaryDirectory()
        return dir.hasSuffix("/") ? dir : dir + "/"
    }

    /// Stable across processes (Swift's Hasher is seeded per process).
    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return h
    }

    /// `local` keeps capture in the MCP process (the old behaviour); anything else forwards when the app is reachable.
    static var mode: String { ProcessInfo.processInfo.environment["GLINT_CAPTURE"] ?? "app" }
}

// MARK: - Socket plumbing

enum UnixSocket {
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func configure(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    static func connect(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        configure(fd)
        let r = withAddress(path) { Darwin.connect(fd, $0, $1) } ?? -1
        if r != 0 { close(fd); return nil }
        return fd
    }

    static func listen(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServiceError.invalid("socket() failed: \(errno)") }
        configure(fd)
        let old = umask(0o077)
        let r = withAddress(path) { bind(fd, $0, $1) } ?? -1
        umask(old)
        guard r == 0 else { let e = errno; close(fd); throw ServiceError.invalid("Couldn't bind \(path): \(String(cString: strerror(e)))") }
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else { close(fd); throw ServiceError.invalid("listen() failed: \(errno)") }
        return fd
    }

    /// Connects only to a socket owned by this user (checked before connecting) and served by this user (checked
    /// after), so another account can't stand in for Glint.
    static func connectVerified(_ path: String) -> Int32? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFSOCK, st.st_uid == getuid() else { return nil }
        guard let fd = connect(path) else { return nil }
        guard peerIsSameUser(fd) else { close(fd); return nil }
        return fd
    }

    /// Only the same user may talk to the app.
    static func peerIsSameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }
}

// MARK: - App side

/// Accepts MCP connections from `glint mcp` processes and serves the forwarded tools in the app.
public final class CaptureHost: @unchecked Sendable {
    let service: GlintService
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var ownedPath: String?
    private var connections: [ObjectIdentifier: (server: MCPServer, fd: Int32)] = [:]

    nonisolated(unsafe) private static weak var _current: CaptureHost?
    private static let currentLock = NSLock()
    /// The host running in this process, if any.
    public static var current: CaptureHost? { currentLock.withLock { _current } }

    public init(service: GlintService) { self.service = service }

    /// Agents connected right now, by the name their client reported.
    public var clients: [String] { lock.withLock { connections.values.map(\.server.author.name) } }

    public func start(socketPath: String = CaptureBroker.socketPath) throws {
        let dir = URL(fileURLWithPath: socketPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if let fd = UnixSocket.connect(socketPath) { close(fd); throw ServiceError.invalid("Another Glint is already serving agents at \(socketPath).") }
        unlink(socketPath)
        let fd = try UnixSocket.listen(socketPath)
        lock.withLock { listenFD = fd; ownedPath = socketPath }
        Self.currentLock.withLock { Self._current = self }
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                guard let self else { close(c); return }
                guard UnixSocket.peerIsSameUser(c) else { close(c); continue }
                UnixSocket.configure(c)
                self.serve(c)
            }
        }
    }

    /// Stops accepting, closes every connection (their sessions are finalised) and removes the socket only if this
    /// host created it.
    public func stop() {
        let (fd, path, open) = lock.withLock { () -> (Int32, String?, [Int32]) in
            let r = (listenFD, ownedPath, connections.values.map(\.fd))
            listenFD = -1; ownedPath = nil
            return r
        }
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd) }
        if let path { unlink(path) }
        for c in open { shutdown(c, SHUT_RDWR) }   // readers see EOF and clean up
        Self.currentLock.withLock { if Self._current === self { Self._current = nil } }
    }

    private func serve(_ fd: Int32) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let server = MCPServer(service: service, output: handle)
        let key = ObjectIdentifier(server)
        let service = service
        let stopSession: @Sendable (String) -> Void = { id in
            Task { if service.session(id) != nil { _ = try? await service.stopRecording(id) } }
        }
        server.onOrphanedSession = stopSession
        lock.withLock { connections[key] = (server, fd) }
        server.serve(input: handle) { [weak self] in
            _ = self?.lock.withLock { self?.connections.removeValue(forKey: key) }
            // The agent went away mid-recording: finish the take so nothing is lost (as the CLI does for local takes).
            for id in server.markClosed() { stopSession(id) }
            _ = handle
        }
    }
}

// MARK: - MCP-process side

/// Forwards capture tool calls from `glint mcp` to the app and relays the replies back to the agent.
///
/// Request IDs are remapped (`glint-<n>`) on the way out and restored on the way back, so an agent's IDs can never
/// collide with the broker's own handshake. Each connection has a generation; a reader that outlives its connection
/// can't disturb a newer one.
final class CaptureClient: @unchecked Sendable {
    private struct Connection { let handle: FileHandle; let generation: Int }
    private let lock = NSLock()
    private let connectLock = NSLock()
    private var connection: Connection?
    private var generation = 0
    private var nextID = 0
    /// Outgoing ID → (generation, the agent's original ID).
    private var pending: [String: (Int, JSONValue)] = [:]
    private let relay: @Sendable (Data) -> Void
    private let socketPath: String
    private let canLaunch: Bool

    init(socketPath: String = CaptureBroker.socketPath, canLaunch: Bool = true, relay: @escaping @Sendable (Data) -> Void) {
        self.socketPath = socketPath; self.canLaunch = canLaunch; self.relay = relay
    }

    var isConnected: Bool { lock.withLock { connection != nil } }

    /// Connects to the app, launching it in the background when it isn't running. Returns false when unreachable.
    /// Concurrent callers wait for one attempt instead of each opening a connection.
    func connect(author: Author, launchTimeout: TimeInterval = 20) -> Bool {
        connectLock.withLock {
            if isConnected { return true }
            var fd = UnixSocket.connectVerified(socketPath)
            if fd == nil, canLaunch, launchApp() {
                let deadline = Date().addingTimeInterval(launchTimeout)
                while fd == nil && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.2)
                    fd = UnixSocket.connectVerified(socketPath)
                }
            }
            guard let fd else { return false }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let gen = lock.withLock { generation += 1; return generation }
            let conn = Connection(handle: handle, generation: gen)
            let hello: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .string("glint-hello-\(gen)"), "method": .string("initialize"),
                                            "params": .object(["protocolVersion": .string(MCPServer.protocolVersion),
                                                               "clientInfo": .object(["name": .string(author.name), "version": .string(GlintVersion.string)]),
                                                               "capabilities": .object([:])])])
            guard Self.write(hello, to: handle) else { try? handle.close(); return false }
            lock.withLock { connection = conn }
            Thread.detachNewThread { [weak self] in self?.readLoop(conn) }
            return true
        }
    }

    /// Sends one JSON-RPC request under a fresh ID; the reply is relayed with the agent's ID restored.
    func forward(_ msg: JSONValue) -> Bool {
        guard case .object(var obj) = msg else { return false }
        let prepared = lock.withLock { () -> (Connection, String?)? in
            guard let c = connection else { return nil }
            guard let original = obj["id"] else { return (c, nil) }
            nextID += 1
            let out = "glint-\(nextID)"
            pending[out] = (c.generation, original)
            return (c, out)
        }
        guard let (conn, outID) = prepared else { return false }
        if let outID { obj["id"] = .string(outID) }
        if Self.write(.object(obj), to: conn.handle) { return true }
        if let outID { _ = lock.withLock { pending.removeValue(forKey: outID) } }
        return false
    }

    private static func write(_ v: JSONValue, to handle: FileHandle) -> Bool {
        guard var data = try? JSONCoding.compactEncoder.encode(v) else { return false }
        data.append(0x0A)
        return (try? handle.write(contentsOf: data)) != nil
    }

    private func readLoop(_ conn: Connection) {
        var buffer = Data()
        while let chunk = readAvailable(conn.handle) {
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<nl])
                buffer = Data(buffer[buffer.index(after: nl)...])
                guard case .object(var obj)? = try? JSONCoding.decoder.decode(JSONValue.self, from: line) else { continue }
                if let id = obj["id"] {
                    guard let key = id.stringValue, let original = lock.withLock({ pending.removeValue(forKey: key) })?.1 else { continue }   // our handshake, or unknown
                    obj["id"] = original
                }
                if var d = try? JSONCoding.compactEncoder.encode(JSONValue.object(obj)) { d.append(0x0A); relay(d) }
            }
        }
        // The app quit or the connection broke: answer whatever was in flight on it so the agent isn't left waiting.
        let orphaned = lock.withLock { () -> [JSONValue] in
            if connection?.generation == conn.generation { connection = nil }
            let mine = pending.filter { $0.value.0 == conn.generation }
            for k in mine.keys { pending.removeValue(forKey: k) }
            return mine.values.map(\.1)
        }
        try? conn.handle.close()
        for id in orphaned {
            let reply: JSONValue = .object(["jsonrpc": .string("2.0"), "id": id, "result": .object([
                "content": .array([.object(["type": .string("text"), "text": .string("Glint quit while handling this call. Open Glint and try again; a recording in progress was saved.")])]),
                "isError": .bool(true)])])
            if var d = try? JSONCoding.compactEncoder.encode(reply) { d.append(0x0A); relay(d) }
        }
    }

    func disconnect() {
        let c = lock.withLock { () -> Connection? in let c = connection; connection = nil; return c }
        if let c { shutdown(c.handle.fileDescriptor, SHUT_RDWR) }   // its reader answers anything pending
    }

    /// Opens the Glint.app this CLI ships in, without bringing it to the front.
    private func launchApp() -> Bool {
        guard let app = AgentSetup.appBundle(containing: AgentSetup.helperPath()) else { return false }
        let env = ProcessInfo.processInfo.environment
        var args = ["-g"]
        let isolated = ["GLINT_HOME", "GLINT_PROJECTS"].filter { env[$0] != nil }
        if !isolated.isEmpty { args.append("-n") }          // a different support folder needs its own instance
        for k in isolated { args += ["--env", "\(k)=\(env[k]!)"] }
        args += [app.path, "--args", "-GlintBackground", "YES"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
