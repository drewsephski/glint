import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import GlintCore

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Exposes the same tool registry as the CLI, plus documentation resources and a workflow prompt.
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    let service: GlintService
    var author = Author(.agent, "mcp-client")
    private let out: FileHandle
    private let writeLock = NSLock()
    private var negotiatedVersion = MCPServer.protocolVersion
    private var captureClient: CaptureClient?
    private let routeLock = NSLock()
    private let sessionLock = NSLock()
    private var _startedSessions: [String] = []
    /// Recording sessions this connection started (in this process), so they can be finalised if the client leaves.
    public var startedSessions: [String] { sessionLock.withLock { _startedSessions } }
    private var _closed = false
    /// Called with a session that finished starting after the client had already gone (see `markClosed`).
    var onOrphanedSession: (@Sendable (String) -> Void)?

    /// Marks the client gone and returns the sessions it started. A start still in flight reports its session to
    /// `onOrphanedSession` when it completes, so no recording outlives its agent unnoticed.
    func markClosed() -> [String] { sessionLock.withLock { _closed = true; return _startedSessions } }

    public init(service: GlintService = GlintService(), output: FileHandle = .standardOutput) {
        self.service = service
        self.out = output
    }

    func send(_ v: JSONValue) {
        guard var data = try? JSONCoding.compactEncoder.encode(v) else { return }
        data.append(0x0A)
        sendRaw(data)
    }

    /// Writes one already-encoded line. Never raises on a closed pipe or socket.
    func sendRaw(_ data: Data) {
        writeLock.withLock { _ = try? out.write(contentsOf: data) }
    }

    /// Send screen-recording tools to the running Glint app (launching it if needed) so macOS asks for Screen
    /// Recording permission once, for Glint, instead of for every terminal or agent app. See `CaptureBroker`.
    public func enableCaptureForwarding(socketPath: String = CaptureBroker.socketPath, launchApp: Bool = true) {
        guard CaptureBroker.mode != "local" else { return }
        captureClient = CaptureClient(socketPath: socketPath, canLaunch: launchApp, relay: { [weak self] line in self?.sendRaw(line) })
    }

    /// Blocking read loop on a background thread; each request is handled in its own Task so long renders
    /// don't block status calls.
    public func serve(input: FileHandle = .standardInput, onEOF: @escaping @Sendable () -> Void) {
        Thread.detachNewThread { [self] in
            var buffer = Data()
            while true {
                guard let chunk = readAvailable(input) else { break }
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<nl]
                    buffer = Data(buffer[buffer.index(after: nl)...])
                    guard !line.isEmpty, let msg = try? JSONCoding.decoder.decode(JSONValue.self, from: Data(line)) else { continue }
                    Task { await self.handle(msg) }
                }
            }
            onEOF()
        }
    }

    public func handle(_ msg: JSONValue) async {
        guard let method = msg.str("method") else { return }   // responses to our requests: ignore
        let id = msg["id"]
        let params = msg["params"] ?? .object([:])
        if method == "tools/call", let name = params.str("name"), CaptureBroker.forwardedTools.contains(name), let client = captureClient {
            // Once connected, every capture call goes to the app (that's where the session lives). Connect only for
            // calls that can start something, and never while this process owns a local recording.
            // Decisions are serialized: a call that arrives while another one is connecting (launching the app can
            // take seconds) waits for that outcome instead of racing ahead locally.
            let useApp = routeLock.withLock {
                client.isConnected || (CaptureBroker.openingTools.contains(name) && service.session(nil) == nil && client.connect(author: author))
            }
            if useApp, client.forward(msg) { return }
        }
        do {
            let result = try await dispatch(method: method, params: params)
            if let id, let result { send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])) }
        } catch let e as RPCError {
            if let id { send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(e.code)), "message": .string(e.message)])])) }
        } catch {
            if let id { send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32603), "message": .string("\(error)")])])) }
        }
    }

    struct RPCError: Error { var code: Int; var message: String }

    func dispatch(method: String, params: JSONValue) async throws -> JSONValue? {
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?.str("name") { author = Author(.agent, name) }
            if let v = params.str("protocolVersion") { negotiatedVersion = v }
            return .object([
                "protocolVersion": .string(negotiatedVersion),
                "capabilities": .object(["tools": .object(["listChanged": .bool(false)]), "resources": .object([:]), "prompts": .object([:])]),
                "serverInfo": .object(["name": .string("glint"), "title": .string("Glint screen studio"), "version": .string(GlintVersion.string)]),
                "instructions": .string(Docs.serverInstructions),
            ])
        case "notifications/initialized", "notifications/cancelled":
            return nil
        case "ping":
            return .object([:])
        case "tools/list":
            return .object(["tools": .array(ToolRegistry.all().map { t in
                .object(["name": .string(t.name), "title": .string(t.title), "description": .string(t.description + " [risk: \(t.risk.rawValue)]"),
                         "inputSchema": t.schema,
                         "annotations": .object(["title": .string(t.title), "readOnlyHint": .bool(t.readOnly),
                                                 "destructiveHint": .bool(t.risk == .destructive),
                                                 "idempotentHint": .bool(t.readOnly), "openWorldHint": .bool(t.risk == .external)])])
            })])
        case "tools/call":
            guard let name = params.str("name") else { throw RPCError(code: -32602, message: "missing tool name") }
            let token = params["_meta"]?["progressToken"]
            var ctx = ToolContext(author: author, service: service)
            if let token {
                let counter = Counter()
                ctx.progress = { [weak self] msg in
                    let n = counter.next()
                    self?.send(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/progress"),
                                        "params": .object(["progressToken": token, "progress": .number(Double(n)), "message": .string(msg)])]))
                }
            }
            do {
                let output = try await ToolRegistry.call(name, arguments: params["arguments"] ?? .object([:]), context: ctx)
                if name == "glint_record_start", let sid = output.json.str("session_id") {
                    let closed = sessionLock.withLock { _startedSessions.append(sid); return _closed }
                    if closed { onOrphanedSession?(sid) }
                }
                var content: [JSONValue] = [.object(["type": .string("text"), "text": .string(JSONCoding.string(output.json))])]
                for url in output.images { if let img = Self.imageContent(url) { content.append(img) } }
                var result: [String: JSONValue] = ["content": .array(content), "isError": .bool(false)]
                if case .object = output.json { result["structuredContent"] = output.json }
                return .object(result)
            } catch let e as ApprovalError {
                var payload: [String: JSONValue] = ["error": .string(e.description)]
                if case .required(let r) = e {
                    payload["status"] = .string("approval_required")
                    payload["approval_id"] = .string(r.id)
                    payload["summary"] = .string(r.summary)
                    payload["expires_at"] = .string(ISO8601DateFormatter().string(from: r.expiresAt))
                }
                return .object(["content": .array([.object(["type": .string("text"), "text": .string(JSONCoding.string(JSONValue.object(payload)))])]),
                                "structuredContent": .object(payload), "isError": .bool(true)])
            } catch {
                return .object(["content": .array([.object(["type": .string("text"), "text": .string("\(error)")])]), "isError": .bool(true)])
            }
        case "resources/list":
            return .object(["resources": .array(Docs.resources.map { .object(["uri": .string($0.uri), "name": .string($0.name), "mimeType": .string("text/markdown"), "description": .string($0.description)]) })])
        case "resources/read":
            guard let uri = params.str("uri"), let r = Docs.resources.first(where: { $0.uri == uri }) else { throw RPCError(code: -32002, message: "resource not found") }
            return .object(["contents": .array([.object(["uri": .string(r.uri), "mimeType": .string("text/markdown"), "text": .string(r.body())])])])
        case "resources/templates/list":
            return .object(["resourceTemplates": .array([])])
        case "prompts/list":
            return .object(["prompts": .array([.object(["name": .string("polish_recording"), "description": .string("Turn the latest (or a given) recording into a polished product demo and verify it."),
                                                        "arguments": .array([.object(["name": .string("project"), "required": .bool(false)]),
                                                                             .object(["name": .string("target_duration"), "required": .bool(false)])])])])])
        case "prompts/get":
            let project = params["arguments"]?.str("project") ?? "latest"
            let target = params["arguments"]?.str("target_duration")
            return .object(["messages": .array([.object(["role": .string("user"), "content": .object(["type": .string("text"), "text": .string(Docs.polishPrompt(project: project, target: target))])])])])
        default:
            throw RPCError(code: -32601, message: "method not found: \(method)")
        }
    }

    final class Counter: @unchecked Sendable { private var n = 0; private let l = NSLock(); func next() -> Int { l.withLock { n += 1; return n } } }

    /// Images go back to the model as JPEG (≤ 1600 px wide) to keep messages small.
    static func imageContent(_ url: URL) -> JSONValue? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return .object(["type": .string("image"), "data": .string((data as Data).base64EncodedString()), "mimeType": .string("image/jpeg")])
    }
}

/// Whatever bytes are ready on `handle` (blocking until at least one), or nil at EOF or on error.
/// Unlike `FileHandle.read(upToCount:)`, this doesn't wait to fill the buffer, and unlike `availableData` it
/// never raises an Objective-C exception when a socket resets.
func readAvailable(_ handle: FileHandle, max: Int = 65536) -> Data? {
    var buf = [UInt8](repeating: 0, count: max)
    while true {
        let n = buf.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, max) }
        if n > 0 { return Data(buf[0..<n]) }
        if n < 0 && errno == EINTR { continue }
        return nil
    }
}

public enum GlintVersion { public static let string = "0.4.0" }
