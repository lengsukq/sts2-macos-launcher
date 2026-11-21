import Foundation

public enum ManagedAssemblyFilter {
    /// Non-BCL pure-IL NuGet assemblies whose names happen to start with `System.`
    /// and are required by `sts2.dll` (verified from `sts2.deps.json`).
    private static let allowedNonBclManagedAssemblies: Set<String> = [
        "system.io.hashing.dll"
    ]

    private static let excludedPrefixes: [String] = [
        "system.",
        "microsoft.",
        "godotsharp",
        "api-ms-",
        "ext-ms-",
        "vcruntime",
        "msvcp",
        "ucrtbase",
        "concrt",
        "clretwrc",
        "clrgc",
        "mscordaccore",
        "mscorrc",
        "msquic",
        "steam_api",
        "sentry.native",
        "sentry-native",
        "fmod",
        "crashpad",
        "lib"
    ]

    private static let excludedExactNames: Set<String> = [
        "sts2.dll",
        "mscorlib.dll",
        "netstandard.dll",
        "windowsbase.dll",
        "coreclr.dll",
        "hostfxr.dll",
        "hostpolicy.dll",
        "clrjit.dll",
        "clrgc.dll",
        "clrgcexp.dll",
        "mscordaccore.dll",
        "mscordbi.dll",
        "createdump.exe"
    ]

    /// Filters out platform-specific Windows native binaries and .NET BCL assemblies so they
    /// never overwrite macOS CoreCLR / BCL / GodotSharp files inside `data_sts2_macos_arm64`,
    /// while preserving pure-managed game dependencies (`0Harmony`, `MonoMod.*`, `SmartFormat*`,
    /// `JetBrains.Annotations`, `Steamworks.NET`, `Sentry*.dll`, `Vortice.*`, `SharpGen.*`, etc.).
    public static func isSupplementaryGameManagedDll(fileName: String) -> Bool {
        let lower = fileName.lowercased()
        guard lower.hasSuffix(".dll") else { return false }
        if allowedNonBclManagedAssemblies.contains(lower) {
            return true
        }
        if excludedExactNames.contains(lower) {
            return false
        }
        for prefix in excludedPrefixes where lower.hasPrefix(prefix) {
            return false
        }
        return true
    }
}

public struct WindowsPayloadInspector: Sendable {
    public init() {}

    public func inspectDirectory(at sourceURL: URL, displayName: String? = nil) throws -> WindowsPayloadInfo {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LauncherError(
                title: "Windows 游戏目录不存在",
                detail: "路径 \(sourceURL.path) 不是有效目录。",
                recoverySuggestionText: "请选择包含 SlayTheSpire2.pck（或 sts2.pck）与 data_sts2_windows_* 的文件夹。"
            )
        }

        let resolvedRoot = resolvePayloadRoot(startingAt: sourceURL)
        let pckURL = try locatePrimaryPck(in: resolvedRoot)
        let (dataDirURL, sts2DllURL) = try locateWindowsDataAndCoreAssembly(in: resolvedRoot)
        let sha256 = try FileHasher.sha256Hex(of: sts2DllURL)
        let releaseVersion = parseReleaseVersion(in: resolvedRoot)
        let supplementaryDlls = listSupplementaryManagedDlls(in: dataDirURL)

        let resolvedName = displayName ?? resolvedRoot.lastPathComponent
        let id = makeStablePayloadID(name: resolvedName, sha256: sha256)

        return WindowsPayloadInfo(
            id: id,
            displayName: resolvedName,
            rootPath: resolvedRoot.path,
            pckPath: pckURL.path,
            pckFileName: pckURL.lastPathComponent,
            pckSizeBytes: FileHasher.fileSizeBytes(of: pckURL),
            dataDirectoryPath: dataDirURL.path,
            sts2DllPath: sts2DllURL.path,
            sts2DllSha256: sha256,
            releaseVersion: releaseVersion,
            supplementaryManagedDlls: supplementaryDlls
        )
    }

    public func importSource(
        at sourceURL: URL,
        into paths: LauncherPaths,
        copyDirectoryIntoStore: Bool = false
    ) throws -> WindowsPayloadInfo {
        try paths.ensureDirectoriesExist()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw LauncherError(
                title: "找不到待导入的游戏包",
                detail: "路径不存在：\(sourceURL.path)",
                recoverySuggestionText: "请确认所选目录或 .zip 压缩包未被移动或删除。"
            )
        }

        if isDir.boolValue {
            let inspected = try inspectDirectory(at: sourceURL)
            guard copyDirectoryIntoStore else {
                return inspected
            }
            let targetDir = paths.payloadsDirectory.appendingPathComponent(inspected.id, isDirectory: true)
            try SystemCommandRunner.cloneOrCopyItem(from: URL(fileURLWithPath: inspected.rootPath), to: targetDir)
            return try inspectDirectory(at: targetDir, displayName: inspected.displayName)
        }

        guard sourceURL.pathExtension.lowercased() == "zip" else {
            throw LauncherError(
                title: "不支持的游戏包格式",
                detail: "目前仅支持文件夹或 .zip 压缩包（收到：\(sourceURL.lastPathComponent)）。",
                recoverySuggestionText: "请将 Windows 版《杀戮尖塔2》目录直接拖入，或打包为 .zip 后再导入。"
            )
        }

        try validateZipSampleIntegrity(at: sourceURL)

        let stagingExtractDir = paths.payloadsDirectory.appendingPathComponent(
            ".extract-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: stagingExtractDir) }

        try SystemCommandRunner.extractZip(at: sourceURL, to: stagingExtractDir)
        let inspectedTemp = try inspectDirectory(
            at: stagingExtractDir,
            displayName: sourceURL.deletingPathExtension().lastPathComponent
        )
        let finalDir = paths.payloadsDirectory.appendingPathComponent(inspectedTemp.id, isDirectory: true)
        if fm.fileExists(atPath: finalDir.path) {
            try fm.removeItem(at: finalDir)
        }
        try fm.moveItem(at: URL(fileURLWithPath: inspectedTemp.rootPath), to: finalDir)
        return try inspectDirectory(at: finalDir, displayName: inspectedTemp.displayName)
    }

    private func resolvePayloadRoot(startingAt url: URL) -> URL {
        let fm = FileManager.default
        if hasPayloadIndicators(in: url) {
            return url
        }

        let children = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let subdirs = children.filter { child in
            child.lastPathComponent != "__MACOSX"
                && ((try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }

        if subdirs.count == 1, hasPayloadIndicators(in: subdirs[0]) {
            return subdirs[0]
        }

        for dir in subdirs where hasPayloadIndicators(in: dir) {
            return dir
        }

        return url
    }

    private func hasPayloadIndicators(in directory: URL) -> Bool {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let hasPck = items.contains { $0.pathExtension.lowercased() == "pck" }
        let hasDataDir = items.contains {
            let name = $0.lastPathComponent.lowercased()
            return name.hasPrefix("data_") && name.contains("windows")
        }
        return hasPck || hasDataDir
    }

    private func locatePrimaryPck(in root: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let pcks = items.filter { $0.pathExtension.lowercased() == "pck" }
        guard !pcks.isEmpty else {
            throw LauncherError(
                title: "缺少 Godot 主资源包 (.pck)",
                detail: "在 \(root.path) 下未找到 SlayTheSpire2.pck 或 sts2.pck。",
                recoverySuggestionText: "请确认导入的是完整的《杀戮尖塔2》Windows 安装目录（而非空文件夹或仅有快捷方式）。"
            )
        }

        let preferredNames = ["slaythespire2.pck", "sts2.pck"]
        if let preferred = pcks.first(where: { preferredNames.contains($0.lastPathComponent.lowercased()) }) {
            return preferred
        }

        return pcks.max(by: { FileHasher.fileSizeBytes(of: $0) < FileHasher.fileSizeBytes(of: $1) })!
    }

    private func locateWindowsDataAndCoreAssembly(in root: URL) throws -> (URL, URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidateDirs = items.filter { url in
            guard ((try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) else {
                return false
            }
            let lower = url.lastPathComponent.lowercased()
            return lower.hasPrefix("data_")
        }

        let orderedDirs = candidateDirs.sorted { lhs, rhs in
            let lWin = lhs.lastPathComponent.lowercased().contains("windows")
            let rWin = rhs.lastPathComponent.lowercased().contains("windows")
            if lWin != rWin { return lWin }
            return lhs.lastPathComponent < rhs.lastPathComponent
        }

        for dir in orderedDirs {
            let dllURL = dir.appendingPathComponent(GameConstants.coreAssemblyFileName)
            if fm.fileExists(atPath: dllURL.path) {
                return (dir, dllURL)
            }
        }

        let directDll = root.appendingPathComponent(GameConstants.coreAssemblyFileName)
        if fm.fileExists(atPath: directDll.path) {
            return (root, directDll)
        }

        throw LauncherError(
            title: "缺少核心游戏程序集 (sts2.dll)",
            detail: "在 \(root.path) 中未找到 data_sts2_windows_*/sts2.dll。",
            recoverySuggestionText: "请确认 Windows 游戏目录包含 data_sts2_windows_x86_64 文件夹且其中存在 sts2.dll。"
        )
    }

    private func listSupplementaryManagedDlls(in dataDirectory: URL) -> [String] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: dataDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .map(\.lastPathComponent)
            .filter { ManagedAssemblyFilter.isSupplementaryGameManagedDll(fileName: $0) }
            .sorted()
    }

    private func parseReleaseVersion(in root: URL) -> String? {
        let releaseInfoURL = root.appendingPathComponent("release_info.json")
        guard let data = try? Data(contentsOf: releaseInfoURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (raw["version"] as? String)
            ?? (raw["release_version"] as? String)
            ?? (raw["build"] as? String)
    }

    private func makeStablePayloadID(name: String, sha256: String) -> String {
        let sanitized = name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9_-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let prefix = sanitized.isEmpty ? "sts2-win" : String(sanitized.prefix(24))
        return "\(prefix)-\(sha256.prefix(8))"
    }

    /// Samples the head, middle, and tail windows of a `.zip` archive before extraction to catch
    /// truncated, sparse, or zero-filled corrupted downloads immediately.
    public func validateZipSampleIntegrity(at zipURL: URL) throws {
        let fileSize = FileHasher.fileSizeBytes(of: zipURL)
        guard fileSize >= 22 else {
            throw LauncherError(
                title: "压缩包损坏或文件为空",
                detail: "\(zipURL.lastPathComponent) 大小仅 \(fileSize) 字节，不是有效的 .zip 压缩包。",
                recoverySuggestionText: "请重新完整下载 Windows 版《杀戮尖塔2》压缩包，或先手动解压后导入文件夹。"
            )
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: zipURL)
        } catch {
            throw LauncherError(
                title: "无法读取压缩包",
                detail: "打开 \(zipURL.lastPathComponent) 失败：\(error.localizedDescription)",
                recoverySuggestionText: "请检查文件权限或确认文件未被其他程序独占锁定。"
            )
        }
        defer { try? handle.close() }

        let windowSize = Int(min(Int64(64 * 1024), fileSize))
        let midOffset = UInt64(max(Int64(0), (fileSize / 2) - Int64(windowSize / 2)))
        let tailOffset = UInt64(max(Int64(0), fileSize - Int64(windowSize)))
        let offsets: [UInt64] = [0, midOffset, tailOffset]

        var totalSampledBytes = 0
        var totalZeroBytes = 0
        var nearAllZeroRegionCount = 0
        var headBytes = Data()

        for (index, offset) in offsets.enumerated() {
            do {
                try handle.seek(toOffset: offset)
                let chunk = try handle.read(upToCount: windowSize) ?? Data()
                if index == 0 {
                    headBytes = chunk
                }
                guard !chunk.isEmpty else { continue }
                var zeroCount = 0
                for byte in chunk where byte == 0 {
                    zeroCount += 1
                }
                totalSampledBytes += chunk.count
                totalZeroBytes += zeroCount
                let regionRatio = Double(zeroCount) / Double(chunk.count)
                if regionRatio >= 0.98 {
                    nearAllZeroRegionCount += 1
                }
            } catch {
                throw LauncherError(
                    title: "压缩包预检读取失败",
                    detail: "抽样读取 \(zipURL.lastPathComponent) 失败：\(error.localizedDescription)",
                    recoverySuggestionText: "请检查磁盘健康状态或重新下载压缩包。"
                )
            }
        }

        let overallZeroRatio = totalSampledBytes > 0
            ? Double(totalZeroBytes) / Double(totalSampledBytes)
            : 1.0
        let zeroPercent = Int((overallZeroRatio * 100.0).rounded())

        let isAllZeroHeader = headBytes.count >= 4
            && headBytes[0] == 0 && headBytes[1] == 0 && headBytes[2] == 0 && headBytes[3] == 0
        let isSeverelyZeroFilled = isAllZeroHeader
            || (fileSize >= 1024 && overallZeroRatio >= 0.90)
            || (fileSize >= 16_384 && nearAllZeroRegionCount >= 2)

        if isSeverelyZeroFilled {
            throw LauncherError(
                title: "压缩包损坏或下载不完整（检测到大量全零数据）",
                detail: "对 \(zipURL.lastPathComponent) 进行前/中/后快速抽样校验失败（零字节占比约 \(zeroPercent)%），文件大概率下载中断或写入损坏。",
                recoverySuggestionText: "请重新完整下载 Windows 版《杀戮尖塔2》压缩包，或确认能手动解压后再导入文件夹。"
            )
        }

        let hasZipSignature = headBytes.count >= 2
            && headBytes[0] == 0x50
            && headBytes[1] == 0x4B
        guard hasZipSignature else {
            throw LauncherError(
                title: "不是有效的 .zip 压缩包",
                detail: "\(zipURL.lastPathComponent) 文件头缺少标准 ZIP 标识（PK），可能已损坏或格式不匹配。",
                recoverySuggestionText: "请确认导入的是标准 .zip 压缩包，或手动解压后直接选择游戏文件夹。"
            )
        }
    }
}
