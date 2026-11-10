import Foundation

/// Runs the providers' documented native installers, without requiring Homebrew, npm, or a terminal.
public enum SubscriptionInstaller {
    public static func install(_ provider: SubscriptionProvider, progress: @Sendable (String) -> Void) async throws {
        if provider.chatAgent.cliPath != nil { return }
        progress("Downloading \(provider.toolTitle)…")
        let url = URL(string: provider == .claude ? "https://claude.ai/install.sh" : "https://chatgpt.com/codex/install.sh")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
            response.url?.scheme == "https", !data.isEmpty, data.count < 2_000_000,
            let script = String(data: data, encoding: .utf8), script.hasPrefix("#!")
        else {
            throw AgentSetupError("Couldn't download the official installer. Check your connection and try again.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("glint-install-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("install.sh")
        try data.write(to: file, options: .atomic)
        progress("Installing \(provider.toolTitle)…")
        try await runScript(file, shell: provider == .claude ? "/bin/bash" : "/bin/sh")
        try Task.checkCancellation()
        guard provider.chatAgent.cliPath != nil else {
            throw AgentSetupError(
                "The installer finished, but Glint couldn't find \(provider.toolTitle). Check the provider's installation help, then try Check Again.")
        }
    }

    /// A supervised process tree ensures cancelling setup also stops the installer's downloads and children.
    static func runScript(_ file: URL, shell: String, timeout: TimeInterval = 600) async throws {
        let process = Process()
        SubscriptionProcessTree.configure(process, path: shell, arguments: [file.path])
        process.currentDirectoryURL = file.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        do {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw AgentSetupError("Installation timed out. Check your connection and try again.") }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try Task.checkCancellation()
            guard process.terminationStatus == 0 else {
                throw AgentSetupError("Installation didn't finish. Check your connection and available disk space, then retry or open installation help.")
            }
        } catch {
            SubscriptionProcessTree.stop(process)
            while process.isRunning {
                await Task.detached { try? await Task.sleep(nanoseconds: 20_000_000) }.value
            }
            throw error
        }
    }
}
