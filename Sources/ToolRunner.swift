import Foundation

/// Thin wrapper around Process for running sips/ffmpeg synchronously
/// (callers are expected to be on a background queue).

struct ToolResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ToolError: LocalizedError {
    case launchFailed(String, String)
    case commandFailed(tool: String, status: Int32, stderr: String)
    case toolNotFound(String)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let tool, let reason):
            return "Could not launch \(tool): \(reason)"
        case .commandFailed(let tool, let status, let stderr):
            let detail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
            return "\(tool) failed (exit \(status)). \(detail)"
        case .toolNotFound(let tool):
            return "\(tool) not found. Install it with: brew install \(tool)"
        }
    }
}

enum ToolRunner {
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ToolError.launchFailed(launchPath, error.localizedDescription)
        }

        // Read concurrently so a chatty tool (ffmpeg) can't fill the pipe and deadlock.
        var outData = Data()
        let errQueue = DispatchQueue(label: "toolrunner.stderr")
        var errData = Data()
        errQueue.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errQueue.sync {}

        let result = ToolResult(
            status: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
        if result.status != 0 {
            let tool = URL(fileURLWithPath: launchPath).lastPathComponent
            throw ToolError.commandFailed(tool: tool, status: result.status, stderr: result.stderr)
        }
        return result
    }

    /// Locate a binary, checking Homebrew locations first since GUI apps
    /// don't inherit the shell PATH.
    static func find(_ name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        // Last resort: ask a login shell, which has the user's PATH.
        if let result = try? run("/bin/zsh", ["-lc", "command -v \(name)"]) {
            let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }
}
