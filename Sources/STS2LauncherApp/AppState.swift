import AppKit
import Foundation
import Observation
import STS2LauncherCore

public enum SidebarSection: String, CaseIterable, Identifiable {
    case dashboard
    case payloads
    case mods
    case saves
    case logs

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dashboard: return "概览与启动"
        case .payloads: return "游戏包与运行时"
        case .mods: return "Mod 管理"
        case .saves: return "存档与快照"
        case .logs: return "日志与诊断"
        }
    }

    public var systemImage: String {
        switch self {
        case .dashboard: return "play.rectangle.fill"
        case .payloads: return "shippingbox.fill"
        case .mods: return "puzzlepiece.extension.fill"
        case .saves: return "externaldrive.fill.badge.timemachine"
        case .logs: return "terminal.fill"
        }
    }
}

@MainActor
@Observable
public final class AppState {
    public var selectedSection: SidebarSection = .dashboard
    public var configuration: LaunchConfiguration = LaunchConfiguration()
    public var bridgeRuntime: BridgeRuntimeInfo?
    public var mods: [ModItem] = []
    public var modIssues: [ModValidationIssue] = []
    public var saveSlots: [SaveAccountSlot] = []
    public var saveSnapshots: [SaveSnapshot] = []
    public var logs: [LogEntry] = []
    public var diagnosticFindings: [DiagnosticFinding] = []
    public var lastStagingReport: StagingReport?
    public var lastLogFilePath: String?
    public var lastExitCode: Int32?

    public var isImporting: Bool = false
    public var isDownloadingExtensions: Bool = false
    public var extensionDownloadFraction: Double = 0
    public var extensionDownloadStatusText: String?
    public var isBuildingBridgeRuntime: Bool = false
    public var isStaging: Bool = false
    public var isGameRunning: Bool = false
    public var statusBanner: String?
    public var activeError: LauncherError?

    public let paths: LauncherPaths
    private let configStore: ConfigStore
    private let windowsInspector = WindowsPayloadInspector()
    private let bridgeInspector = BridgeRuntimeInspector()
    private let extensionDownloader = BridgeExtensionDownloader()
    private let stager = RuntimeStager()
    private let modRepository: ModRepository
    private let saveManager: SaveManager
    private let diagnostics = CrashDiagnostics()
    private let processRunner = GameProcessRunner()

    public init(paths: LauncherPaths = LauncherPaths()) {
        self.paths = paths
        self.configStore = ConfigStore(paths: paths)
        self.modRepository = ModRepository(paths: paths)
        self.saveManager = SaveManager(paths: paths)
        reloadAll()
    }

    public var selectedPayload: WindowsPayloadInfo? {
        configuration.selectedPayload
    }

    public var bridgeRuntimeRootURL: URL {
        if let customPath = normalizedCustomBridgePath {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        if let activeRoot = bridgeRuntime?.rootPath, !activeRoot.isEmpty {
            return URL(fileURLWithPath: activeRoot, isDirectory: true)
        }
        return paths.bridgeRuntimeDirectory
    }

    public var writableBridgeRuntimeRootURL: URL {
        if let customPath = normalizedCustomBridgePath {
            return URL(fileURLWithPath: customPath, isDirectory: true)
        }
        return paths.bridgeRuntimeDirectory
    }

    public var isUsingBundledBridgeRuntime: Bool {
        guard !hasCustomBridgeRuntimePath,
              let bundled = paths.bundledBridgeRuntimeDirectory?.standardizedFileURL.path,
              let activeRoot = bridgeRuntime?.rootPath else {
            return false
        }
        return URL(fileURLWithPath: activeRoot).standardizedFileURL.path == bundled
    }

    public var isMitCoreReady: Bool {
        guard let components = bridgeRuntime?.components, !components.isEmpty else {
            return false
        }
        let mitCorePrefixes = ["Godot ", ".NET ", "Native Bridges", "STS2MacBridge"]
        return mitCorePrefixes.allSatisfy { prefix in
            components.first(where: { $0.name.hasPrefix(prefix) })?.isReady == true
        }
    }

    public var needsUpstreamExtensionsOnly: Bool {
        isMitCoreReady && !(bridgeRuntime?.isLaunchReady ?? false)
    }

    public var canUpgradeFmodToFull: Bool {
        isMitCoreReady
            && (bridgeRuntime?.isLaunchReady == true)
            && (bridgeRuntime?.fmodMode.lowercased() != "full")
    }

    public var hasCustomBridgeRuntimePath: Bool {
        normalizedCustomBridgePath != nil
    }

    public var enabledModCount: Int {
        configuration.enableMods ? mods.filter(\.isEnabled).count : 0
    }

    public var blockingModErrors: [ModValidationIssue] {
        modIssues.filter { $0.severity == .error }
    }

    public var canLaunchGame: Bool {
        selectedPayload != nil
            && (bridgeRuntime?.isLaunchReady == true)
            && !isDownloadingExtensions
            && !isBuildingBridgeRuntime
            && !isStaging
            && !isGameRunning
    }

    public func reloadAll() {
        do {
            try paths.ensureDirectoriesExist()
            configuration = try configStore.load()
            refreshBridgeRuntime()
            reloadMods()
            reloadSaves()
        } catch {
            presentError(error)
        }
    }

    public func persistConfiguration() {
        do {
            try configStore.save(configuration)
        } catch {
            presentError(error)
        }
    }

    public func refreshBridgeRuntime() {
        bridgeRuntime = bridgeInspector.inspect(
            paths: paths,
            customRootPath: normalizedCustomBridgePath
        )
    }

    public func reinspectBridgeRuntimeWithStatus() {
        refreshBridgeRuntime()
        guard let runtime = bridgeRuntime else { return }
        let readyCount = runtime.components.filter(\.isReady).count
        let totalCount = runtime.components.count
        statusBanner = runtime.isLaunchReady
            ? "桥接运行时检测通过：\(readyCount)/\(totalCount) 组件就绪（FMOD：\(BridgeDisplayFormatter.fmodModeLabel(runtime.fmodMode))）。"
            : "桥接运行时尚未完整就绪：\(readyCount)/\(totalCount) 组件就绪，请安装或重建缺失组件。"
    }

    public func setCustomBridgeRuntimeDirectory(url: URL) {
        configuration.bridgeRuntimeCustomPath = url.standardizedFileURL.path
        persistConfiguration()
        refreshBridgeRuntime()
        if bridgeRuntime?.isLaunchReady == true {
            statusBanner = "已关联自定义桥接运行时目录：\(url.lastPathComponent)"
        } else {
            statusBanner = "已切换桥接运行时目录至 \(url.lastPathComponent)，部分必需组件尚未就绪。"
        }
    }

    public func resetBridgeRuntimeDirectory() {
        configuration.bridgeRuntimeCustomPath = nil
        persistConfiguration()
        refreshBridgeRuntime()
        statusBanner = "已恢复默认桥接运行时目录。"
    }

    public func downloadUpstreamExtensions() {
        guard !isDownloadingExtensions && !isBuildingBridgeRuntime else { return }
        guard !isStaging && !isGameRunning else {
            statusBanner = "请先等待游戏合成或运行结束后再下载上游扩展。"
            return
        }

        let targetPaths = self.paths
        let customRoot = self.normalizedCustomBridgePath
        let downloader = self.extensionDownloader

        isDownloadingExtensions = true
        extensionDownloadFraction = 0.02
        extensionDownloadStatusText = "正在连接官方上游扩展源…"
        statusBanner = "正在从官方上游源自动下载 Spine 4.2 与 FMOD 2.03.06 扩展…"
        appendLog(LogEntry(
            source: .launcher,
            level: .info,
            message: "开始下载官方上游 GDExtension（Spine 4.2 + FMOD 2.03.06），目标目录：\(writableBridgeRuntimeRootURL.path)"
        ))

        Task {
            do {
                let summary = try await Task.detached(priority: .userInitiated) {
                    try await downloader.downloadAndInstall(
                        into: targetPaths,
                        customRootPath: customRoot
                    ) { progress in
                        Task { @MainActor in
                            self.extensionDownloadFraction = progress.fractionCompleted
                            self.extensionDownloadStatusText = progress.detail
                            self.statusBanner = "[\(progress.stage)] \(progress.detail)"
                        }
                    }
                }.value

                self.isDownloadingExtensions = false
                self.extensionDownloadFraction = 1.0
                self.extensionDownloadStatusText = nil
                self.refreshBridgeRuntime()

                let ready = self.bridgeRuntime?.isLaunchReady == true
                let message = ready
                    ? "Spine 4.2 与 FMOD 2.03.06 扩展安装完成，桥接运行时已全部就绪！"
                    : "扩展已下载至 \(summary.destinationRootPath)，请检查其余桥接组件状态。"
                self.statusBanner = message
                self.appendLog(LogEntry(
                    source: .launcher,
                    level: ready ? .info : .warning,
                    message: "\(message)（Spine: \(summary.spineFrameworkPath)，FMOD: \(summary.fmodDylibPaths.count) 个核心库）"
                ))
            } catch {
                self.isDownloadingExtensions = false
                self.extensionDownloadFraction = 0
                self.extensionDownloadStatusText = nil
                self.statusBanner = nil
                self.appendLog(LogEntry(
                    source: .launcher,
                    level: .error,
                    message: "下载官方上游扩展失败：\(error.localizedDescription)"
                ))
                self.presentError(error)
            }
        }
    }

    public func setupBridgeRuntime() {
        guard !isBuildingBridgeRuntime && !isDownloadingExtensions else { return }
        guard !isStaging && !isGameRunning else {
            statusBanner = "请先等待游戏合成或运行结束后再重建桥接运行时。"
            return
        }
        guard let scriptURL = findSetupBridgeScriptURL() else {
            activeError = LauncherError(
                title: "未找到开发者构建脚本",
                detail: "无法定位 scripts/setup-bridge-runtime.sh。",
                recoverySuggestionText: "普通用户无需此脚本，请直接点击“下载官方 Spine & FMOD 扩展”；开发者请在项目工作区根目录运行 ./scripts/setup-bridge-runtime.sh。"
            )
            return
        }

        let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
        let targetRuntimeDir = writableBridgeRuntimeRootURL
        let windowsDataDir = selectedPayload?.dataDirectoryPath
        isBuildingBridgeRuntime = true
        statusBanner = "正在一键搭建/重建自建 macOS 桥接运行时…"
        appendLog(LogEntry(
            source: .launcher,
            level: .info,
            message: "开始执行桥接运行时构建脚本：\(scriptURL.path)（目标目录：\(targetRuntimeDir.path)）"
        ))

        let batcher = PendingLogBatcher { batch in
            self.appendLogBatch(batch)
            if let lastLine = batch.last(where: { !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.message {
                let compact = lastLine.trimmingCharacters(in: .whitespacesAndNewlines)
                self.statusBanner = "桥接构建：\(String(compact.prefix(100)))"
            }
        }

        Task {
            do {
                let exitCode = try await Task.detached(priority: .userInitiated) {
                    try await BridgeSetupRunner.run(
                        scriptURL: scriptURL,
                        workingDirectory: repoRoot,
                        outputDirectory: targetRuntimeDir,
                        windowsDataDirectory: windowsDataDir
                    ) { source, line in
                        batcher.enqueue(LogEntry(
                            source: source,
                            level: CrashDiagnostics.inferLogLevel(from: line, source: source),
                            message: line
                        ))
                    }
                }.value

                let remaining = batcher.flushNow()
                if !remaining.isEmpty {
                    self.appendLogBatch(remaining)
                }

                self.isBuildingBridgeRuntime = false
                self.refreshBridgeRuntime()

                if exitCode == 0 {
                    let ready = self.bridgeRuntime?.isLaunchReady == true
                    let message = ready
                        ? "自建 macOS 桥接运行时构建完成，所有必需组件已就绪。"
                        : "构建脚本已退出（0），但部分组件仍未通过校验，请检查组件详情或日志。"
                    self.statusBanner = message
                    self.appendLog(LogEntry(
                        source: .launcher,
                        level: ready ? .info : .warning,
                        message: message
                    ))
                } else {
                    self.statusBanner = "桥接运行时构建失败（退出码 \(exitCode)），请查看“日志与诊断”。"
                    self.appendLog(LogEntry(
                        source: .launcher,
                        level: .error,
                        message: "桥接运行时构建脚本失败，退出码：\(exitCode)"
                    ))
                    self.selectedSection = .logs
                    self.presentError(LauncherError(
                        title: "桥接运行时构建失败",
                        detail: "scripts/setup-bridge-runtime.sh 退出码为 \(exitCode)。",
                        recoverySuggestionText: "已在“日志与诊断”记录完整构建输出，请排查网络或依赖问题后重试。"
                    ))
                }
            } catch {
                self.isBuildingBridgeRuntime = false
                self.statusBanner = nil
                self.appendLog(LogEntry(
                    source: .launcher,
                    level: .error,
                    message: "启动桥接构建脚本失败：\(error.localizedDescription)"
                ))
                self.presentError(error)
            }
        }
    }

    public func importWindowsPayload(from url: URL, copyIntoStore: Bool) {
        isImporting = true
        statusBanner = "正在检验并导入 \(url.lastPathComponent)…"
        let paths = self.paths
        let inspector = self.windowsInspector

        Task.detached(priority: .userInitiated) {
            do {
                let info = try inspector.importSource(
                    at: url,
                    into: paths,
                    copyDirectoryIntoStore: copyIntoStore
                )
                await MainActor.run {
                    self.isImporting = false
                    self.upsertPayload(info)
                    self.statusBanner = "已导入 Windows 游戏包：\(info.displayName) (\(info.shortHash))"
                }
            } catch {
                await MainActor.run {
                    self.isImporting = false
                    self.statusBanner = nil
                    self.presentError(error)
                }
            }
        }
    }

    public func selectPayload(id: String) {
        configuration.selectedPayloadID = id
        persistConfiguration()
    }

    public func removePayload(_ payload: WindowsPayloadInfo) {
        configuration.payloads.removeAll(where: { $0.id == payload.id })
        if configuration.selectedPayloadID == payload.id {
            configuration.selectedPayloadID = configuration.payloads.first?.id
        }
        persistConfiguration()
        statusBanner = "已从列表移除 \(payload.displayName)（未删除你外部原目录文件）。"
    }

    public func reloadMods() {
        do {
            mods = try modRepository.loadMods()
            modIssues = modRepository.validate(mods: mods)
        } catch {
            presentError(error)
        }
    }

    public func importMod(from url: URL) {
        do {
            let imported = try modRepository.importMod(from: url)
            reloadMods()
            statusBanner = "已导入 Mod：\(imported.displayName)"
        } catch {
            presentError(error)
        }
    }

    public func setModEnabled(_ modID: String, enabled: Bool) {
        guard let idx = mods.firstIndex(where: { $0.id == modID }) else { return }
        mods[idx].isEnabled = enabled
        saveModOrderAndRevalidate()
    }

    public func moveMod(id: String, offset: Int) {
        guard let currentIndex = mods.firstIndex(where: { $0.id == id }) else { return }
        let targetIndex = currentIndex + offset
        guard mods.indices.contains(targetIndex) else { return }
        let item = mods.remove(at: currentIndex)
        mods.insert(item, at: targetIndex)
        for index in mods.indices {
            mods[index].loadOrder = index
        }
        saveModOrderAndRevalidate()
    }

    public func deleteMod(_ mod: ModItem) {
        do {
            try modRepository.deleteMod(mod)
            reloadMods()
            statusBanner = "已删除 Mod：\(mod.displayName)"
        } catch {
            presentError(error)
        }
    }

    public func reloadSaves() {
        saveSlots = saveManager.discoverAccountSlots()
        saveSnapshots = saveManager.listSnapshots()
    }

    public func createSaveSnapshot(slot: SaveAccountSlot, bucket: SaveBucket, note: String) {
        do {
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            let snap = try saveManager.createSnapshot(
                for: slot,
                bucket: bucket,
                note: trimmed.isEmpty ? "手动备份" : trimmed
            )
            reloadSaves()
            statusBanner = "已创建快照 \(snap.id)（共 \(snap.fileCount) 个文件）。"
        } catch {
            presentError(error)
        }
    }

    public func transferSaves(slot: SaveAccountSlot, from source: SaveBucket, to target: SaveBucket) {
        do {
            let backup = try saveManager.transfer(slot: slot, from: source, to: target)
            reloadSaves()
            statusBanner = "已完成 \(source.displayName) → \(target.displayName) 转移（目标原存档已备份为 \(backup.id)）。"
        } catch {
            presentError(error)
        }
    }

    public func restoreSnapshot(_ snapshot: SaveSnapshot) {
        guard let slot = saveSlots.first(where: { $0.id == snapshot.accountSlotID }) else {
            activeError = LauncherError(
                title: "未找到对应账号槽位",
                detail: "账号槽位 \(snapshot.accountSlotID) 当前不存在。",
                recoverySuggestionText: "请先确认该账号目录是否存在于 ~/Library/Application Support/SlayTheSpire2/ 下。"
            )
            return
        }
        do {
            let backup = try saveManager.restoreSnapshot(snapshot, to: slot)
            reloadSaves()
            statusBanner = "已恢复快照 \(snapshot.id)（恢复前当前存档已备份为 \(backup.id)）。"
        } catch {
            presentError(error)
        }
    }

    public func launchGame() {
        guard !isBuildingBridgeRuntime && !isDownloadingExtensions else {
            statusBanner = isDownloadingExtensions
                ? "正在下载官方 Spine & FMOD 扩展，请等待完成后再启动游戏。"
                : "正在构建自建桥接运行时，请等待构建完成后再启动游戏。"
            return
        }
        guard let payload = selectedPayload else {
            activeError = LauncherError(
                title: "尚未选择 Windows 游戏包",
                detail: "请先导入一个有效的 Windows 版《杀戮尖塔2》目录或 .zip 压缩包。",
                recoverySuggestionText: "在概览页拖入或切换到“游戏包与运行时”页面完成导入。"
            )
            return
        }
        guard let runtime = bridgeRuntime, runtime.isLaunchReady else {
            let suggestion = needsUpstreamExtensionsOnly
                ? "内置 MIT 核心已就绪，请点击“一键下载官方 Spine & FMOD 扩展”完成补齐（无需安装任何开发工具）。"
                : "请切换到“游戏包与运行时”页面下载扩展或重建缺失组件。"
            activeError = LauncherError(
                title: "自建 macOS 桥接运行时尚未就绪",
                detail: "需要就绪 Godot 4.5.1 Mono、.NET 9 osx-arm64、Spine 4.2、FMOD 2.03.06、Native Bridges 与 STS2MacBridge。",
                recoverySuggestionText: suggestion
            )
            return
        }

        isStaging = true
        logs = []
        diagnosticFindings = []
        lastExitCode = nil
        statusBanner = "正在合成自建桥接运行沙盒…"

        let currentMods = mods
        let currentConfig = configuration
        let currentPaths = paths
        let stager = self.stager
        let runner = self.processRunner
        let diagnostics = self.diagnostics

        Task {
            do {
                let report = try await Task.detached(priority: .userInitiated) {
                    try stager.stage(
                        windowsPayload: payload,
                        bridgeRuntime: runtime,
                        enabledMods: currentMods,
                        configuration: currentConfig,
                        paths: currentPaths
                    )
                }.value

                self.lastStagingReport = report
                self.isStaging = false
                self.isGameRunning = true
                self.statusBanner = "合成完成，游戏运行中…"
                let steamLabel = report.steamApiLinked ? "Steamworks 已链接" : "Steamworks 未配置"
                let bridgeLabel = report.bridgeDllInjected ? "STS2MacBridge 已注入" : "STS2MacBridge 未注入"
                let fmodLabel = BridgeDisplayFormatter.fmodModeLabel(report.fmodMode)
                self.appendLog(LogEntry(
                    source: .launcher,
                    level: .info,
                    message: "桥接沙盒合成完成：覆写 \(report.copiedManagedDlls.joined(separator: ", "))，\(bridgeLabel)，\(steamLabel)，FMOD \(fmodLabel)，部署 \(report.deployedModIDs.count) 个 Mod。"
                ))

                let batcher = PendingLogBatcher { batch in
                    self.appendLogBatch(batch)
                }

                let session = try await runner.launch(
                    stagedReport: report,
                    configuration: currentConfig,
                    paths: currentPaths,
                    onLogBatch: { batch in
                        batcher.enqueue(contentsOf: batch)
                    }
                )

                let remaining = batcher.flushNow()
                if !remaining.isEmpty {
                    self.appendLogBatch(remaining)
                }

                self.isGameRunning = false
                self.lastExitCode = session.exitCode
                self.lastLogFilePath = session.logFilePath
                self.diagnosticFindings = diagnostics.analyze(exitCode: session.exitCode, entries: self.logs)
                self.statusBanner = session.exitCode == 0
                    ? "游戏已正常退出。"
                    : "游戏异常退出（退出码 \(session.exitCode)），请查看“日志与诊断”。"
                if session.exitCode != 0 {
                    self.selectedSection = .logs
                }
            } catch {
                self.isStaging = false
                self.isGameRunning = false
                self.statusBanner = nil
                self.presentError(error)
            }
        }
    }

    public func stopGame() {
        processRunner.terminate()
        statusBanner = "已发送终止信号给游戏进程…"
    }

    public func clearLogs() {
        logs.removeAll()
        diagnosticFindings.removeAll()
        lastExitCode = nil
    }

    public func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public func openDirectoryInFinder(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    private var normalizedCustomBridgePath: String? {
        let trimmed = configuration.bridgeRuntimeCustomPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }

    private func findSetupBridgeScriptURL() -> URL? {
        let fm = FileManager.default
        let scriptRelativePath = "scripts/setup-bridge-runtime.sh"
        var searchRoots: [URL] = []

        if let resourceURL = Bundle.main.resourceURL {
            searchRoots.append(resourceURL)
        }
        searchRoots.append(contentsOf: ancestorDirectories(
            startingAt: URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true),
            maxLevels: 5
        ))
        searchRoots.append(contentsOf: ancestorDirectories(
            startingAt: Bundle.main.bundleURL,
            maxLevels: 6
        ))
        if let executableDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            searchRoots.append(contentsOf: ancestorDirectories(startingAt: executableDir, maxLevels: 6))
        }
        searchRoots.append(contentsOf: ancestorDirectories(
            startingAt: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
            maxLevels: 5
        ))

        for root in searchRoots {
            let candidate = root.appendingPathComponent(scriptRelativePath)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private func ancestorDirectories(startingAt url: URL, maxLevels: Int) -> [URL] {
        var result: [URL] = []
        var current = url.standardizedFileURL
        for _ in 0...maxLevels {
            result.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        return result
    }

    private func upsertPayload(_ info: WindowsPayloadInfo) {
        if let idx = configuration.payloads.firstIndex(where: { $0.id == info.id }) {
            configuration.payloads[idx] = info
        } else {
            configuration.payloads.insert(info, at: 0)
        }
        configuration.selectedPayloadID = info.id
        persistConfiguration()
    }

    private func saveModOrderAndRevalidate() {
        do {
            try modRepository.saveState(for: mods)
            modIssues = modRepository.validate(mods: mods)
        } catch {
            presentError(error)
        }
    }

    private func appendLog(_ entry: LogEntry) {
        appendLogBatch([entry])
    }

    private func appendLogBatch(_ batch: [LogEntry]) {
        guard !batch.isEmpty else { return }
        logs.append(contentsOf: batch)
        // Cap live UI ring buffer to keep scrolling responsive on verbose sessions; full log is persisted on disk.
        if logs.count > 5_000 {
            logs.removeFirst(logs.count - 5_000)
        }
    }

    private func presentError(_ error: Error) {
        if let launcherError = error as? LauncherError {
            activeError = launcherError
        } else {
            activeError = LauncherError(
                title: "操作未能完成",
                detail: error.localizedDescription,
                recoverySuggestionText: "请检查磁盘权限与路径有效性后重试。"
            )
        }
    }
}

enum BridgeDisplayFormatter {
    static func fmodModeLabel(_ mode: String) -> String {
        switch mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "full":
            return "完整音频"
        case "stub":
            return "静音兜底"
        case "unknown", "":
            return "未检测"
        default:
            return "静音兜底 (\(mode))"
        }
    }

    static func fmodModeSymbol(_ mode: String) -> String {
        mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "full"
            ? "speaker.wave.2.fill"
            : "speaker.slash.fill"
    }
}

private final class PendingLogBatcher: @unchecked Sendable {
    private static let maxBufferedEntries = 5_000
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private var flushScheduled = false
    private let onFlush: @MainActor @Sendable ([LogEntry]) -> Void

    init(onFlush: @escaping @MainActor @Sendable ([LogEntry]) -> Void) {
        self.onFlush = onFlush
    }

    func enqueue(_ entry: LogEntry) {
        enqueue(contentsOf: [entry])
    }

    func enqueue(contentsOf newEntries: [LogEntry]) {
        guard !newEntries.isEmpty else { return }
        let shouldSchedule: Bool
        lock.lock()
        entries.append(contentsOf: newEntries)
        if entries.count > Self.maxBufferedEntries {
            entries.removeFirst(entries.count - Self.maxBufferedEntries)
        }
        if flushScheduled {
            shouldSchedule = false
        } else {
            flushScheduled = true
            shouldSchedule = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            let batch = self.drain()
            if !batch.isEmpty {
                self.onFlush(batch)
            }
        }
    }

    func flushNow() -> [LogEntry] {
        drain()
    }

    private func drain() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let batch = entries
        entries.removeAll(keepingCapacity: true)
        flushScheduled = false
        return batch
    }
}

private final class LineStreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func appendAndExtractLines(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newlineIndex)
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            let line = String(decoding: lineData, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if !line.isEmpty {
                lines.append(line)
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

private enum BridgeSetupRunner {
    static func run(
        scriptURL: URL,
        workingDirectory: URL,
        outputDirectory: URL,
        windowsDataDirectory: String?,
        onOutput: @escaping @Sendable (LogStreamSource, String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["bash", scriptURL.path, "--output-dir", outputDirectory.path]
        process.currentDirectoryURL = workingDirectory

        var env = ProcessInfo.processInfo.environment
        // Bundled .app processes do not inherit Homebrew PATH entries from shell profiles.
        let requiredPathEntries = [
            "/opt/homebrew/opt/dotnet@9/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin"
        ]
        let existingEntries = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            .split(separator: ":")
            .map(String.init)
        let mergedEntries = requiredPathEntries.filter { !existingEntries.contains($0) } + existingEntries
        env["PATH"] = mergedEntries.joined(separator: ":")
        if let windowsDataDirectory, !windowsDataDirectory.isEmpty, env["STS2_WIN_DATA_DIR"] == nil {
            env["STS2_WIN_DATA_DIR"] = windowsDataDirectory
        }
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = LineStreamBuffer()
        let stderrBuffer = LineStreamBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in stdoutBuffer.appendAndExtractLines(data) {
                onOutput(.stdout, line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            for line in stderrBuffer.appendAndExtractLines(data) {
                onOutput(.stderr, line)
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { terminated in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil

                let tailOut = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                for line in stdoutBuffer.appendAndExtractLines(tailOut) + stdoutBuffer.flushRemaining() {
                    onOutput(.stdout, line)
                }

                let tailErr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                for line in stderrBuffer.appendAndExtractLines(tailErr) + stderrBuffer.flushRemaining() {
                    onOutput(.stderr, line)
                }

                continuation.resume(returning: terminated.terminationStatus)
            }

            do {
                try process.run()
            } catch {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: LauncherError(
                    title: "无法启动桥接构建脚本",
                    detail: error.localizedDescription,
                    recoverySuggestionText: "请确认脚本路径及 bash 权限正常后重试。"
                ))
            }
        }
    }
}
