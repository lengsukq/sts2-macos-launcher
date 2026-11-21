import CryptoKit
import Foundation

public struct CommandOutput: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum SystemCommandRunner {
    public static func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL? = nil
    ) throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw LauncherError(
                title: "系统命令启动失败",
                detail: "无法执行 \(executablePath) \(arguments.joined(separator: " "))：\(error.localizedDescription)",
                recoverySuggestionText: "请确认系统工具存在且具备执行权限。"
            )
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CommandOutput(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdoutData, as: UTF8.self),
            stderr: String(decoding: stderrData, as: UTF8.self)
        )
    }

    public static func extractZip(at zipURL: URL, to destinationDirectory: URL) throws {
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let result = try run(
            executablePath: "/usr/bin/ditto",
            arguments: ["-xk", zipURL.path, destinationDirectory.path]
        )
        guard result.exitCode == 0 else {
            throw LauncherError(
                title: "解压压缩包失败",
                detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "ditto 退出码 \(result.exitCode)"
                    : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                recoverySuggestionText: "请确认压缩包完整且未损坏，或先手动解压后以文件夹形式导入。"
            )
        }
    }

    /// Uses APFS copy-on-write cloning (`cp -cR`) when available so staging a large `.app`
    /// completes quickly without doubling disk usage, and falls back cleanly on non-APFS volumes.
    public static func cloneOrCopyItem(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        let cloneResult = try run(
            executablePath: "/bin/cp",
            arguments: ["-cR", source.path, destination.path]
        )
        if cloneResult.exitCode == 0 {
            return
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }
}

public enum FileHasher {
    private static let chunkSize = 1024 * 1024

    public static func sha256Hex(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func fileSizeBytes(of fileURL: URL) -> Int64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}
