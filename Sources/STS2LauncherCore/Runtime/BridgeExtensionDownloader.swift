import Foundation

public struct ExtensionDownloadProgress: Sendable, Equatable {
    public let stage: String
    public let fractionCompleted: Double
    public let detail: String

    public init(stage: String, fractionCompleted: Double, detail: String) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted
        self.detail = detail
    }
}

public struct ExtensionDownloadSummary: Sendable, Equatable {
    public let destinationRootPath: String
    public let spineFrameworkPath: String
    public let fmodFrameworkPath: String
    public let fmodDylibPaths: [String]
}

public enum UpstreamExtensionSources {
    public static let spineArchiveURL = URL(
        string: "https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/4.5.1-stable/spine-godot-extension-4.2-4.5.1-stable.zip"
    )!
    public static let fmodArchiveURL = URL(
        string: "https://github.com/utopia-rise/fmod-gdextension/releases/download/6.1.0-4.5.0/addons.zip"
    )!
}

/// Downloads and installs upstream third-party macOS GDExtensions (Spine 4.2 & FMOD 2.03.06)
/// directly to the user's Application Support directory using only macOS built-in APIs
/// (URLSession, /usr/bin/ditto, /usr/bin/xattr, /usr/bin/codesign) — zero developer tools required.
public struct BridgeExtensionDownloader: Sendable {
    private let spineURL: URL
    private let fmodURL: URL

    public init(
        spineURL: URL = UpstreamExtensionSources.spineArchiveURL,
        fmodURL: URL = UpstreamExtensionSources.fmodArchiveURL
    ) {
        self.spineURL = spineURL
        self.fmodURL = fmodURL
    }

    public func downloadAndInstall(
        into paths: LauncherPaths,
        customRootPath: String? = nil,
        onProgress: @escaping @Sendable (ExtensionDownloadProgress) -> Void = { _ in }
    ) async throws -> ExtensionDownloadSummary {
        try paths.ensureDirectoriesExist()
        let fm = FileManager.default
        let targetRoot = resolveDestinationRoot(paths: paths, customRootPath: customRootPath)
        let gdextRoot = targetRoot.appendingPathComponent("gdextensions", isDirectory: true)
        let workDir = fm.temporaryDirectory.appendingPathComponent("sts2-ext-dl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: gdextRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // 1. Download & install Spine 4.2 macOS template_release framework
        onProgress(ExtensionDownloadProgress(
            stage: "Spine 4.2",
            fractionCompleted: 0.05,
            detail: "正在从 Esoteric Software 官方源下载 Spine 4.2 GDExtension…"
        ))
        let spineZip = workDir.appendingPathComponent("spine.zip")
        try await downloadFile(from: spineURL, to: spineZip) { frac in
            onProgress(ExtensionDownloadProgress(
                stage: "Spine 4.2",
                fractionCompleted: 0.05 + frac * 0.25,
                detail: "正在下载 Spine 4.2 (\(Int(frac * 100))%)…"
            ))
        }

        onProgress(ExtensionDownloadProgress(
            stage: "Spine 4.2",
            fractionCompleted: 0.32,
            detail: "正在提取 Spine macOS arm64 框架…"
        ))
        let spineExtractDir = workDir.appendingPathComponent("spine-extract", isDirectory: true)
        try SystemCommandRunner.extractZip(at: spineZip, to: spineExtractDir)
        let installedSpinePath = try installSpineFramework(from: spineExtractDir, into: gdextRoot)

        // 2. Download & install FMOD 2.03.06 macOS template_release framework + core dylibs
        onProgress(ExtensionDownloadProgress(
            stage: "FMOD 2.03.06",
            fractionCompleted: 0.40,
            detail: "正在从 utopia-rise/fmod-gdextension 官方源下载 FMOD 2.03.06…"
        ))
        let fmodZip = workDir.appendingPathComponent("fmod-addons.zip")
        try await downloadFile(from: fmodURL, to: fmodZip) { frac in
            onProgress(ExtensionDownloadProgress(
                stage: "FMOD 2.03.06",
                fractionCompleted: 0.40 + frac * 0.45,
                detail: "正在下载 FMOD 2.03.06 (\(Int(frac * 100))%)…"
            ))
        }

        onProgress(ExtensionDownloadProgress(
            stage: "FMOD 2.03.06",
            fractionCompleted: 0.88,
            detail: "正在提取 macOS FMOD 框架与音频动态库（自动过滤非 macOS 文件）…"
        ))
        let fmodExtractDir = workDir.appendingPathComponent("fmod-extract", isDirectory: true)
        try SystemCommandRunner.extractZip(at: fmodZip, to: fmodExtractDir)
        let (installedFmodFw, installedFmodDylibs) = try installFmodAssets(from: fmodExtractDir, into: gdextRoot)

        onProgress(ExtensionDownloadProgress(
            stage: "完成",
            fractionCompleted: 1.0,
            detail: "Spine 4.2 与 FMOD 2.03.06 扩展已安装并校验通过。"
        ))

        return ExtensionDownloadSummary(
            destinationRootPath: targetRoot.path,
            spineFrameworkPath: installedSpinePath,
            fmodFrameworkPath: installedFmodFw,
            fmodDylibPaths: installedFmodDylibs
        )
    }

    private func resolveDestinationRoot(paths: LauncherPaths, customRootPath: String?) -> URL {
        if let customRootPath, !customRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: customRootPath, isDirectory: true).standardizedFileURL
        }
        return paths.bridgeRuntimeDirectory
    }

    private func downloadFile(
        from remoteURL: URL,
        to localURL: URL,
        onFraction: @escaping @Sendable (Double) -> Void
    ) async throws {
        if remoteURL.isFileURL {
            try SystemCommandRunner.cloneOrCopyItem(from: remoteURL, to: localURL)
            onFraction(1.0)
            return
        }

        let delegate = StreamingDownloadDelegate(destinationURL: localURL, onFraction: onFraction)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        try await delegate.run(session: session, remoteURL: remoteURL)
        onFraction(1.0)
    }

    private func installSpineFramework(from extractDir: URL, into gdextRoot: URL) throws -> String {
        guard let found = findFirst(in: extractDir, matching: {
            $0.lastPathComponent == "libspine_godot.macos.template_release.framework"
        }) else {
            throw LauncherError(
                title: "未在 Spine 压缩包中找到 macOS 框架",
                detail: "解压目录中缺少 libspine_godot.macos.template_release.framework。",
                recoverySuggestionText: "请稍后重试下载，或通过脚本手动检查上游归档结构。"
            )
        }

        let destDir = gdextRoot.appendingPathComponent("spine", isDirectory: true)
        let destFramework = destDir.appendingPathComponent(found.lastPathComponent, isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try SystemCommandRunner.cloneOrCopyItem(from: found, to: destFramework)
        clearQuarantineAndSign(destFramework, deep: true)

        guard let binary = BridgeRuntimeInspector.locateMachOBinary(in: destFramework),
              BridgeRuntimeInspector.detectArchitectures(of: binary).contains("arm64") else {
            throw LauncherError(
                title: "Spine 框架架构校验失败",
                detail: "提取的 \(destFramework.lastPathComponent) 不包含 arm64 切片。",
                recoverySuggestionText: "请确认下载源完整未损坏后重试。"
            )
        }
        return destFramework.path
    }

    private func installFmodAssets(from extractDir: URL, into gdextRoot: URL) throws -> (String, [String]) {
        guard let foundFw = findFirst(in: extractDir, matching: {
            $0.lastPathComponent == "libGodotFmod.macos.template_release.framework"
        }) else {
            throw LauncherError(
                title: "未在 FMOD 压缩包中找到 macOS 框架",
                detail: "解压目录中缺少 libGodotFmod.macos.template_release.framework。",
                recoverySuggestionText: "请确认上游 Release 完整后重试。"
            )
        }

        guard let foundFmod = findFirst(in: extractDir, matching: { $0.lastPathComponent == "libfmod.dylib" }),
              let foundStudio = findFirst(in: extractDir, matching: { $0.lastPathComponent == "libfmodstudio.dylib" }) else {
            throw LauncherError(
                title: "未在 FMOD 压缩包中找到核心音频库",
                detail: "缺少 libfmod.dylib 或 libfmodstudio.dylib。",
                recoverySuggestionText: "请确认下载的是包含 macOS 音频库的 fmod-gdextension 6.1.0-4.5.0 发布包。"
            )
        }

        let destDir = gdextRoot.appendingPathComponent("fmod", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: destDir.path) {
            try fm.removeItem(at: destDir)
        }
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)

        let destFw = destDir.appendingPathComponent(foundFw.lastPathComponent, isDirectory: true)
        let destFmod = destDir.appendingPathComponent("libfmod.dylib")
        let destStudio = destDir.appendingPathComponent("libfmodstudio.dylib")

        try SystemCommandRunner.cloneOrCopyItem(from: foundFw, to: destFw)
        try SystemCommandRunner.cloneOrCopyItem(from: foundFmod, to: destFmod)
        try SystemCommandRunner.cloneOrCopyItem(from: foundStudio, to: destStudio)

        clearQuarantineAndSign(destFmod, deep: false)
        clearQuarantineAndSign(destStudio, deep: false)
        clearQuarantineAndSign(destFw, deep: true)

        guard let fwBin = BridgeRuntimeInspector.locateMachOBinary(in: destFw),
              BridgeRuntimeInspector.detectArchitectures(of: fwBin).contains("arm64"),
              BridgeRuntimeInspector.detectArchitectures(of: destFmod).contains("arm64"),
              BridgeRuntimeInspector.detectArchitectures(of: destStudio).contains("arm64") else {
            throw LauncherError(
                title: "FMOD 动态库架构校验失败",
                detail: "提取的 FMOD 框架或核心 dylib 缺少 arm64 架构。",
                recoverySuggestionText: "请重试下载或检查上游发布包。"
            )
        }

        return (destFw.path, [destFmod.path, destStudio.path])
    }

    private func findFirst(in directory: URL, matching predicate: (URL) -> Bool) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let url as URL in enumerator {
            if predicate(url) {
                return url
            }
        }
        return nil
    }

    private func clearQuarantineAndSign(_ url: URL, deep: Bool) {
        _ = try? SystemCommandRunner.run(
            executablePath: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", url.path]
        )
        var signArgs = ["--force"]
        if deep {
            signArgs.append("--deep")
        }
        signArgs.append(contentsOf: ["--sign", "-", url.path])
        _ = try? SystemCommandRunner.run(
            executablePath: "/usr/bin/codesign",
            arguments: signArgs
        )
    }
}

private final class StreamingDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destinationURL: URL
    private let onFraction: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var didMoveFile = false
    private var moveError: Error?
    private var lastReportedPercent = -1

    init(destinationURL: URL, onFraction: @escaping @Sendable (Double) -> Void) {
        self.destinationURL = destinationURL
        self.onFraction = onFraction
    }

    func run(session: URLSession, remoteURL: URL) async throws {
        let task = session.downloadTask(with: remoteURL)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                lock.lock()
                continuation = cont
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let frac = min(1.0, max(0.0, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
        let pct = Int(frac * 100)
        lock.lock()
        let shouldReport = pct != lastReportedPercent
        if shouldReport {
            lastReportedPercent = pct
        }
        lock.unlock()
        if shouldReport {
            onFraction(frac)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let urlText = downloadTask.originalRequest?.url?.absoluteString ?? "unknown"
            lock.lock()
            moveError = LauncherError(
                title: "上游服务器返回错误",
                detail: "\(urlText) 返回 HTTP \(http.statusCode)。",
                recoverySuggestionText: "请稍后重试，或检查网络是否能正常访问 GitHub / AWS S3。"
            )
            lock.unlock()
            return
        }

        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
            lock.lock()
            didMoveFile = true
            lock.unlock()
        } catch {
            lock.lock()
            moveError = error
            lock.unlock()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let capturedMoveError = moveError
        let moved = didMoveFile
        lock.unlock()

        guard let cont else { return }

        if let error {
            let urlText = task.originalRequest?.url?.host ?? task.originalRequest?.url?.absoluteString ?? "upstream"
            cont.resume(throwing: LauncherError(
                title: "下载上游扩展失败",
                detail: "无法下载 \(urlText)：\(error.localizedDescription)",
                recoverySuggestionText: "请检查网络连接或代理设置后重试。"
            ))
            return
        }

        if let capturedMoveError {
            cont.resume(throwing: capturedMoveError)
            return
        }

        if !moved {
            cont.resume(throwing: LauncherError(
                title: "上游扩展下载不完整",
                detail: "下载任务已结束，但未能落盘至 \(destinationURL.lastPathComponent)。",
                recoverySuggestionText: "请检查磁盘空间后重试。"
            ))
            return
        }

        cont.resume(returning: ())
    }
}
