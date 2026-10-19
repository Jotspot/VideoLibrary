import Foundation
import Observation

/// Status and one-click install/update for the external tools (yt-dlp,
/// ffmpeg, Deno). They stay system installs managed by Homebrew — see
/// CLAUDE.md — so this just drives `brew` on the user's behalf.
@Observable
@MainActor
final class ToolsService {
    static let shared = ToolsService()

    struct Tool: Identifiable, Sendable {
        let name: String
        let purpose: String
        let versionArguments: [String]
        var path: String?
        var version: String?
        var id: String { name }
        var isInstalled: Bool { path != nil }
    }

    private(set) var tools: [Tool] = [
        Tool(name: "yt-dlp", purpose: "Downloads videos", versionArguments: ["--version"]),
        Tool(name: "ffmpeg", purpose: "Merges video and audio", versionArguments: ["-version"]),
        Tool(name: "deno", purpose: "Solves YouTube's player challenges", versionArguments: ["--version"])
    ]
    private(set) var isChecking = false
    private(set) var isUpdating = false
    private(set) var log = ""
    private(set) var lastResult: Result?
    private(set) var lastChecked: Date?

    enum Result: Equatable {
        case success(String)
        case failure(String)
    }

    var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    var missingTools: [Tool] { tools.filter { !$0.isInstalled } }

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false; lastChecked = Date() }

        var updated = tools
        for index in updated.indices {
            let tool = updated[index]
            let path = YtDlpService.findExecutable(named: tool.name)
            updated[index].path = path
            updated[index].version = nil
            guard let path else { continue }
            let output = await Self.run(path, tool.versionArguments, environment: Self.environment).output
            updated[index].version = Self.parseVersion(output, tool: tool.name)
        }
        tools = updated
    }

    /// Installs anything missing and upgrades everything else.
    func updateAll() async {
        guard !isUpdating else { return }
        guard let brewPath else {
            lastResult = .failure("Homebrew isn't installed. Install it from brew.sh, then come back and click Update All.")
            return
        }
        isUpdating = true
        lastResult = nil
        log = ""
        defer { isUpdating = false }

        await refresh()
        let missing = tools.filter { !$0.isInstalled }.map(\.name)
        let installed = tools.filter(\.isInstalled).map(\.name)

        var failed = false
        if !missing.isEmpty {
            failed = await runBrew(brewPath, ["install"] + missing) != 0 || failed
        }
        if !installed.isEmpty {
            failed = await runBrew(brewPath, ["upgrade"] + installed) != 0 || failed
        }

        await refresh()
        if failed {
            lastResult = .failure("Homebrew reported a problem. See the log below for details.")
        } else {
            let summary = tools.compactMap { tool in tool.version.map { "\(tool.name) \($0)" } }
            lastResult = .success("Everything is up to date: " + summary.joined(separator: ", ") + ".")
        }
    }

    private func runBrew(_ brewPath: String, _ arguments: [String]) async -> Int32 {
        appendLog("$ brew \(arguments.joined(separator: " "))\n")
        let result = await Self.run(brewPath, arguments, environment: Self.environment) { [weak self] chunk in
            Task { @MainActor in self?.appendLog(chunk) }
        }
        appendLog("\n")
        return result.status
    }

    private func appendLog(_ text: String) {
        log += text
        if log.count > 40_000 { log = String(log.suffix(30_000)) }
    }

    nonisolated private static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a minimal PATH.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        return env
    }

    nonisolated private static func parseVersion(_ output: String, tool: String) -> String? {
        let firstLine = output.split(separator: "\n").first.map(String.init) ?? ""
        switch tool {
        case "ffmpeg":
            // "ffmpeg version 8.0 Copyright ..."
            let parts = firstLine.split(separator: " ")
            return parts.count > 2 ? String(parts[2]) : nil
        case "deno":
            // "deno 2.5.0 (stable, release, aarch64-apple-darwin)"
            let parts = firstLine.split(separator: " ")
            return parts.count > 1 ? String(parts[1]) : nil
        default:
            return firstLine.isEmpty ? nil : firstLine
        }
    }

    nonisolated private static func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String],
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            final class Buffer: @unchecked Sendable {
                let lock = NSLock()
                var text = ""
                func append(_ chunk: String) { lock.lock(); text += chunk; lock.unlock() }
                var value: String { lock.lock(); defer { lock.unlock() }; return text }
            }
            let buffer = Buffer()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
                buffer.append(chunk)
                onOutput?(chunk)
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                let rest = pipe.fileHandleForReading.readDataToEndOfFile()
                if let chunk = String(data: rest, encoding: .utf8), !chunk.isEmpty {
                    buffer.append(chunk)
                    onOutput?(chunk)
                }
                continuation.resume(returning: (process.terminationStatus, buffer.value))
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}
