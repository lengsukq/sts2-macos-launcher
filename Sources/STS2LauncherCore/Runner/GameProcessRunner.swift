import Foundation

public struct GameSessionResult: Sendable, Equatable {
    public let exitCode: Int32
    public let logFilePath: String
    public let startedAt: Date
    public let finishedAt: Date
}

private final class LineBufferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    /// Scans incoming pipe bytes in O(N) time and compacts the buffer at most once per chunk
    /// so bursty engine output never stalls macOS's 64 KB stdout/stderr pipe.
    func appendAndExtractLines(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)

        var lines: [String] = []
        var cursor = buffer.startIndex
        let end = buffer.endIndex

        while cursor < end, let newlineIndex = buffer[cursor..<end].firstIndex(of: UInt8(ascii: "\n")) {
            let lineSlice = buffer[cursor..<newlineIndex]
            if !lineSlice.isEmpty {
                let trimmedSlice: Data.SubSequence
                if lineSlice.last == UInt8(ascii: "\r") {
                    trimmedSlice = lineSlice.dropLast()
                } else {
                    trimmedSlice = lineSlice
                }
                if !trimmedSlice.isEmpty {
                    lines.append(String(decoding: trimmedSlice, as: UTF8.self))
                }
            }
            cursor = buffer.index(after: newlineIndex)
        }

        if cursor > buffer.startIndex {
            if cursor == end {
                buffer.removeAll(keepingCapacity: true)
            } else {
                buffer = Data(buffer[cursor..<end])
            }
        }
        return lines
    }

    func flushRemaining() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let line = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\r\n"))
        buffer.removeAll()
        return line.isEmpty ? [] : [line]
    }
}

private final class SessionLogWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private let timestampFormatter: ISO8601DateFormatter
    let fileURL: URL

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestampFormatter = formatter

        let fm = FileManager.default
        try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: fileURL.path, contents: nil)
        self.fileHandle = try FileHandle(forWritingTo: fileURL)
    }

    func appendBatch(_ entries: [LogEntry]) {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let fileHandle else { return }

        var payload = String()
        payload.reserveCapacity(entries.count * 96)
        for entry in entries {
            payload.append("[")
            payload.append(timestampFormatter.string(from: entry.timestamp))
            payload.append("] [")
            payload.append(entry.source.rawValue)
            payload.append("] [")
            payload.append(entry.level.label)
            payload.append("] ")
            payload.append(entry.message)
            payload.append("\n")
        }
        try? fileHandle.write(contentsOf: Data(payload.utf8))
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
    }
}

public final class GameProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?

    public init() {}

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeProcess?.isRunning == true
    }

    public func terminate() {
        lock.lock()
        let process = activeProcess
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    public static func buildLaunchEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        stagedReport: StagingReport,
        configuration: LaunchConfiguration,
        paths: LauncherPaths
    ) -> [String: String] {
        var environment = baseEnvironment
        let fm = FileManager.default
        let stagedAppURL = URL(fileURLWithPath: stagedReport.stagedAppPath)
        let stagedDataDir = stagedAppURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent(GameConstants.macDataDirectoryName, isDirectory: true)
        let stagedFrameworksDir = stagedAppURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)

        let bridgeDllURL = stagedDataDir.appendingPathComponent(GameConstants.bridgeAssemblyFileName)
        if stagedReport.bridgeDllInjected || fm.fileExists(atPath: bridgeDllURL.path) {
            environment["DOTNET_STARTUP_HOOKS"] = bridgeDllURL.path
        }

        environment["STS2_BRIDGE_HUD"] = configuration.enableInGameOverlay ? "1" : "0"

        let frameworksSteamDylib = stagedFrameworksDir.appendingPathComponent("libsteam_api.dylib")
        let dataSteamDylib = stagedDataDir.appendingPathComponent("libsteam_api.dylib")
        if fm.fileExists(atPath: frameworksSteamDylib.path) {
            environment["STS2_BRIDGE_STEAM_DYLIB"] = frameworksSteamDylib.path
        } else if fm.fileExists(atPath: dataSteamDylib.path) {
            environment["STS2_BRIDGE_STEAM_DYLIB"] = dataSteamDylib.path
        }

        if configuration.enableMods {
            let modsDir: URL
            switch configuration.modDeployTarget {
            case .bundleOnly:
                modsDir = stagedAppURL
                    .appendingPathComponent("Contents/MacOS", isDirectory: true)
                    .appendingPathComponent(GameConstants.modsFolderName, isDirectory: true)
            case .userDataOnly, .both:
                modsDir = paths.gameUserModsDirectory
            }
            environment["STS2_BRIDGE_MODS_DIR"] = modsDir.path
        } else {
            environment.removeValue(forKey: "STS2_BRIDGE_MODS_DIR")
        }

        if configuration.disableDotNetWriteXorExecute {
            environment["DOTNET_EnableWriteXorExecute"] = "0"
        }

        return environment
    }

    public func launch(
        stagedReport: StagingReport,
        configuration: LaunchConfiguration,
        paths: LauncherPaths,
        onLog: @escaping @Sendable (LogEntry) -> Void
    ) async throws -> GameSessionResult {
        try await launch(
            stagedReport: stagedReport,
            configuration: configuration,
            paths: paths,
            onLogBatch: { batch in
                for entry in batch {
                    onLog(entry)
                }
            }
        )
    }

    public func launch(
        stagedReport: StagingReport,
        configuration: LaunchConfiguration,
        paths: LauncherPaths,
        onLogBatch: @escaping @Sendable ([LogEntry]) -> Void
    ) async throws -> GameSessionResult {
        try paths.ensureDirectoriesExist()
        let executableURL = URL(fileURLWithPath: stagedReport.stagedExecutablePath)
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LauncherError(
                title: "Staged 主程序不可执行",
                detail: "路径 \(executableURL.path) 缺少可执行权限或不存在。",
                recoverySuggestionText: "请重新执行合成，并确认自建 BridgeRuntime 中的 Godot 模板完好。"
            )
        }

        let startedAt = Date()
        let logFileURL = makeSessionLogFileURL(in: paths.logsDirectory, startedAt: startedAt)
        let logWriter = try SessionLogWriter(fileURL: logFileURL)

        let emitBatch: @Sendable ([LogEntry]) -> Void = { entries in
            guard !entries.isEmpty else { return }
            logWriter.appendBatch(entries)
            onLogBatch(entries)
        }

        let emitSingle: @Sendable (LogStreamSource, LogLevel, String) -> Void = { source, level, message in
            emitBatch([LogEntry(source: source, level: level, message: message)])
        }

        let process = Process()
        process.executableURL = executableURL
        process.currentDirectoryURL = executableURL.deletingLastPathComponent()
        process.arguments = configuration.resolvedLaunchArguments()

        let environment = Self.buildLaunchEnvironment(
            stagedReport: stagedReport,
            configuration: configuration,
            paths: paths
        )
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = LineBufferBox()
        let stderrBuffer = LineBufferBox()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = stdoutBuffer.appendAndExtractLines(data)
            guard !lines.isEmpty else { return }
            let now = Date()
            let entries = lines.map { line in
                LogEntry(timestamp: now, source: .stdout, level: CrashDiagnostics.inferLogLevel(from: line, source: .stdout), message: line)
            }
            emitBatch(entries)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let lines = stderrBuffer.appendAndExtractLines(data)
            guard !lines.isEmpty else { return }
            let now = Date()
            let entries = lines.map { line in
                LogEntry(timestamp: now, source: .stderr, level: CrashDiagnostics.inferLogLevel(from: line, source: .stderr), message: line)
            }
            emitBatch(entries)
        }

        var startupEntries: [LogEntry] = [
            LogEntry(source: .launcher, level: .info, message: "正在启动 Staged 游戏进程：\(executableURL.path)")
        ]
        if let args = process.arguments, !args.isEmpty {
            startupEntries.append(LogEntry(source: .launcher, level: .info, message: "启动参数：\(args.joined(separator: " "))"))
        }
        if let hookPath = environment["DOTNET_STARTUP_HOOKS"] {
            startupEntries.append(LogEntry(source: .launcher, level: .info, message: "已注入 DOTNET_STARTUP_HOOKS=\(hookPath)"))
        }
        startupEntries.append(LogEntry(
            source: .launcher,
            level: .info,
            message: "桥接环境：STEAM_API=\(stagedReport.steamApiLinked ? "linked" : "unconfigured") HUD=\(environment["STS2_BRIDGE_HUD"] ?? "1") FMOD=\(stagedReport.fmodMode)"
        ))
        if let modsDir = environment["STS2_BRIDGE_MODS_DIR"] {
            startupEntries.append(LogEntry(source: .launcher, level: .info, message: "桥接 Mod 目录：\(modsDir)"))
        }
        emitBatch(startupEntries)

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { [weak self] terminated in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let tailOutLines = stdoutBuffer.appendAndExtractLines(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    + stdoutBuffer.flushRemaining()
                if !tailOutLines.isEmpty {
                    let now = Date()
                    emitBatch(tailOutLines.map { line in
                        LogEntry(timestamp: now, source: .stdout, level: CrashDiagnostics.inferLogLevel(from: line, source: .stdout), message: line)
                    })
                }

                let tailErrLines = stderrBuffer.appendAndExtractLines(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    + stderrBuffer.flushRemaining()
                if !tailErrLines.isEmpty {
                    let now = Date()
                    emitBatch(tailErrLines.map { line in
                        LogEntry(timestamp: now, source: .stderr, level: CrashDiagnostics.inferLogLevel(from: line, source: .stderr), message: line)
                    })
                }

                let finishedAt = Date()
                let status = terminated.terminationStatus
                emitSingle(.launcher, status == 0 ? .info : .error, "游戏进程已退出，退出码：\(status)")
                logWriter.close()

                self?.clearActiveProcess()
                continuation.resume(returning: GameSessionResult(
                    exitCode: status,
                    logFilePath: logFileURL.path,
                    startedAt: startedAt,
                    finishedAt: finishedAt
                ))
            }

            do {
                setActiveProcess(process)
                try process.run()
            } catch {
                clearActiveProcess()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                logWriter.close()
                continuation.resume(throwing: LauncherError(
                    title: "无法启动游戏进程",
                    detail: error.localizedDescription,
                    recoverySuggestionText: "请确认 Staged .app 已正确重签且未被 macOS 安全策略拦截。"
                ))
            }
        }
    }

    private func setActiveProcess(_ process: Process) {
        lock.lock()
        activeProcess = process
        lock.unlock()
    }

    private func clearActiveProcess() {
        lock.lock()
        activeProcess = nil
        lock.unlock()
    }

    private func makeSessionLogFileURL(in directory: URL, startedAt: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return directory.appendingPathComponent("session-\(formatter.string(from: startedAt)).log")
    }
}
