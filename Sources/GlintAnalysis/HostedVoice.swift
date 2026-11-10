import Foundation
import GlintCore

/// Only a purchaser's access code lives on the Mac. The service holds the ElevenLabs key and enforces usage.
public enum HostedVoice {
    public struct Access: Decodable, Sendable {
        public let purchased: Bool
        public let remaining: Int
    }

    public static var baseURL: URL? {
        let value = ProcessInfo.processInfo.environment["GLINT_VOICE_SERVICE_URL"]
            ?? Bundle.main.object(forInfoDictionaryKey: "GlintVoiceServiceURL") as? String
            ?? bundledServiceURL
        return validatedBaseURL(value)
    }

    /// The bundled CLI is in Contents/Helpers and shares the app's public service URL.
    private static var bundledServiceURL: String? {
        let info = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return plist["GlintVoiceServiceURL"] as? String
    }

    public static func validatedBaseURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), let host = url.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/",
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(host)) else { return nil }
        return url
    }

    public static func validAccessCode(_ value: String) -> Bool {
        value.utf8.count == 70 && value.range(of: "^glint_[a-f0-9]{64}$", options: .regularExpression) != nil
    }

    public static func makeAccessCode() -> String {
        "glint_" + (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    public static func request(_ path: String, method: String = "GET", body: JSONValue? = nil, accessCode: String? = nil) throws -> URLRequest {
        guard let baseURL else { throw VoiceError.badResponse("Voiceover purchases are not available in this build. You can use your own ElevenLabs key in Settings › Narration.") }
        guard let token = accessCode ?? Secrets.get(.voiceAccess), validAccessCode(token) else { throw VoiceError.noKey }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 300
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONCoding.compactEncoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    public static func access(code: String? = nil, reconcile: Bool = false) async throws -> Access {
        var request = try request("v1/access", accessCode: code)
        if reconcile, let url = request.url { request.url = url.appending(queryItems: [URLQueryItem(name: "refresh", value: "true")]) }
        let json = try await ElevenLabs.send(request)
        return try JSONCoding.decoder.decode(Access.self, from: JSONCoding.compactEncoder.encode(json))
    }

    public static func checkout() async throws -> URL {
        let json = try await ElevenLabs.send(try request("v1/checkout", method: "POST"))
        guard let value = json["url"]?.stringValue, let url = URL(string: value),
              url.scheme == "https", url.host == "checkout.stripe.com", url.user == nil, url.password == nil else {
            throw VoiceError.badResponse("Could not open secure checkout. Please try again.")
        }
        return url
    }
}
