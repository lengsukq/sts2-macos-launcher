import Foundation

/// Inspects PE32+ (.NET) assemblies and patches pure-IL (`ILONLY`) assemblies whose COFF `Machine`
/// header is `0x8664` (AMD64) to `0xAA64` (ARM64) so macOS Apple Silicon CoreCLR loads them without
/// throwing `FileLoadException: The assembly architecture is not compatible`.
public enum PEAssemblyArchPatcher {
    public static let machineAMD64: UInt16 = 0x8664
    public static let machineARM64: UInt16 = 0xAA64
    private static let pe32PlusMagic: UInt16 = 0x020B
    private static let corFlagsILOnly: UInt32 = 0x0000_0001

    /// Returns `true` if the file at `fileURL` was a PE32+ `ILONLY` assembly with `Machine == 0x8664`
    /// and has been rewritten atomically in-place to `Machine == 0xAA64`.
    @discardableResult
    public static func patchAMD64ILOnlyToARM64(at fileURL: URL) throws -> Bool {
        var data = try Data(contentsOf: fileURL)
        guard patchAMD64ILOnlyToARM64(in: &data) else {
            return false
        }
        try data.write(to: fileURL, options: .atomic)
        return true
    }

    /// Pure in-memory patcher for unit testing and safe atomic writes.
    @discardableResult
    public static func patchAMD64ILOnlyToARM64(in data: inout Data) -> Bool {
        guard data.count >= 0x40 else { return false }
        // DOS header magic "MZ"
        guard data[0] == 0x4D, data[1] == 0x5A else { return false }

        let peOffset = Int(readUInt32LE(data, at: 0x3C))
        guard peOffset >= 0, peOffset + 24 <= data.count else { return false }

        // PE signature "PE\0\0"
        guard data[peOffset] == 0x50,
              data[peOffset + 1] == 0x45,
              data[peOffset + 2] == 0x00,
              data[peOffset + 3] == 0x00 else {
            return false
        }

        let machine = readUInt16LE(data, at: peOffset + 4)
        guard machine == machineAMD64 else { return false }

        let numberOfSections = Int(readUInt16LE(data, at: peOffset + 6))
        let sizeOfOptionalHeader = Int(readUInt16LE(data, at: peOffset + 20))
        let optOffset = peOffset + 24

        // PE32+ optional header must be large enough to include DataDirectory[14] (CLR header)
        guard sizeOfOptionalHeader >= 232, optOffset + sizeOfOptionalHeader <= data.count else {
            return false
        }

        let optMagic = readUInt16LE(data, at: optOffset)
        guard optMagic == pe32PlusMagic else { return false }

        let numRvaAndSizes = readUInt32LE(data, at: optOffset + 108)
        guard numRvaAndSizes > 14 else { return false }

        let clrDirectoryOffset = optOffset + 112 + (14 * 8)
        let clrRva = readUInt32LE(data, at: clrDirectoryOffset)
        let clrSize = readUInt32LE(data, at: clrDirectoryOffset + 4)
        guard clrRva != 0, clrSize >= 20 else { return false }

        let sectionTableOffset = optOffset + sizeOfOptionalHeader
        guard let clrFileOffset = rvaToFileOffset(
            clrRva,
            in: data,
            sectionTableOffset: sectionTableOffset,
            numberOfSections: numberOfSections
        ) else {
            return false
        }

        guard clrFileOffset + 20 <= data.count else { return false }
        let corFlags = readUInt32LE(data, at: clrFileOffset + 16)
        guard (corFlags & corFlagsILOnly) != 0 else { return false }

        // Patch COFF Machine field from 0x8664 (AMD64) to 0xAA64 (ARM64)
        data[peOffset + 4] = UInt8(machineARM64 & 0xFF)
        data[peOffset + 5] = UInt8((machineARM64 >> 8) & 0xFF)
        return true
    }

    private static func rvaToFileOffset(
        _ rva: UInt32,
        in data: Data,
        sectionTableOffset: Int,
        numberOfSections: Int
    ) -> Int? {
        for index in 0..<numberOfSections {
            let entryOffset = sectionTableOffset + (index * 40)
            guard entryOffset + 40 <= data.count else { return nil }
            let virtualSize = readUInt32LE(data, at: entryOffset + 8)
            let virtualAddress = readUInt32LE(data, at: entryOffset + 12)
            let sizeOfRawData = readUInt32LE(data, at: entryOffset + 16)
            let pointerToRawData = readUInt32LE(data, at: entryOffset + 20)
            let span = max(virtualSize, sizeOfRawData)
            if rva >= virtualAddress, rva < virtualAddress &+ span {
                let offset = pointerToRawData &+ (rva - virtualAddress)
                return Int(offset)
            }
        }
        return nil
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

public struct RuntimeStager: Sendable {
    public init() {}

    public func stage(
        windowsPayload: WindowsPayloadInfo,
        bridgeRuntime: BridgeRuntimeInfo,
        enabledMods: [ModItem],
        configuration: LaunchConfiguration,
        paths: LauncherPaths,
        skipCodeSign: Bool = false
    ) throws -> StagingReport {
        try paths.ensureDirectoriesExist()
        try validateBridgeRuntimeReady(bridgeRuntime)

        let fm = FileManager.default
        let tempParent = paths.stagedDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let tempAppBundle = tempParent.appendingPathComponent(GameConstants.appBundleName, isDirectory: true)
        defer { try? fm.removeItem(at: tempParent) }

        // 1. Clone Godot 4.5.1 Mono template .app, rename release binary to SlayTheSpire2, write Info.plist
        try SystemCommandRunner.cloneOrCopyItem(
            from: URL(fileURLWithPath: bridgeRuntime.godotTemplateAppPath),
            to: tempAppBundle
        )
        try prepareGodotAppShell(
            at: tempAppBundle,
            releaseVersion: windowsPayload.releaseVersion
        )

        var warnings: [String] = []
        if bridgeRuntime.fmodMode == "stub" {
            warnings.append("FMOD 当前为静音兜底模式 (stub)，游戏将可正常运行但无音频输出。")
        } else if bridgeRuntime.fmodMode != "full" {
            warnings.append("未检测到 FMOD 音频组件，游戏将以静音状态运行。")
        }

        let stagedResources = tempAppBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        let stagedMacOS = tempAppBundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let stagedFrameworks = tempAppBundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        let stagedDataDir = stagedResources.appendingPathComponent(GameConstants.macDataDirectoryName, isDirectory: true)

        try fm.createDirectory(at: stagedResources, withIntermediateDirectories: true)
        try fm.createDirectory(at: stagedFrameworks, withIntermediateDirectories: true)

        // 2. APFS clone Windows .pck -> Contents/Resources/SlayTheSpire2.pck
        let targetPckURL = stagedResources.appendingPathComponent(GameConstants.targetPckFileName)
        try replaceFile(at: targetPckURL, with: URL(fileURLWithPath: windowsPayload.pckPath))

        // 2b. Copy release_info.json into Contents/Resources and Contents/MacOS if present
        let winReleaseInfoURL = URL(fileURLWithPath: windowsPayload.rootPath)
            .appendingPathComponent("release_info.json")
        if fm.fileExists(atPath: winReleaseInfoURL.path) {
            try replaceFile(
                at: stagedResources.appendingPathComponent("release_info.json"),
                with: winReleaseInfoURL
            )
            try replaceFile(
                at: stagedMacOS.appendingPathComponent("release_info.json"),
                with: winReleaseInfoURL
            )
        }

        // 2c. Write Godot override.cfg before codesign to disable expensive per-warning C# stack traces
        // and explicitly keep shader & PSO pipeline caches enabled on macOS.
        try writePerformanceOverrideConfig(
            stagedResourcesDir: stagedResources,
            stagedMacOSDir: stagedMacOS
        )

        // 3. Assemble Contents/Resources/data_sts2_macos_arm64/
        let assemblyResult = try assembleDotNetDataDirectory(
            windowsPayload: windowsPayload,
            bridgeRuntime: bridgeRuntime,
            into: stagedDataDir
        )
        warnings.append(contentsOf: assemblyResult.warnings)

        // 4. Deploy GDExtensions (Spine, FMOD) & Native Stubs (Sentry, Steam) into Contents/Frameworks/ and res:// paths
        let nativeDeployResult = try deployGDExtensionsAndStubs(
            bridgeRuntime: bridgeRuntime,
            configuration: configuration,
            stagedFrameworksDir: stagedFrameworks,
            stagedResourcesDir: stagedResources,
            stagedDataDir: stagedDataDir
        )
        warnings.append(contentsOf: nativeDeployResult.warnings)

        // 5. Write steam_appid.txt if enabled
        var wroteSteamAppID = false
        if configuration.writeSteamAppIDFile {
            let steamAppIDURL = stagedMacOS.appendingPathComponent(GameConstants.steamAppIDFileName)
            try Data((GameConstants.steamAppID + "\n").utf8).write(to: steamAppIDURL, options: .atomic)
            wroteSteamAppID = true
        }

        // 6. Sync enabled mods
        let orderedMods = configuration.enableMods
            ? enabledMods.filter(\.isEnabled).sorted(by: { $0.loadOrder < $1.loadOrder })
            : []

        let deployedModIDs = try deployMods(
            orderedMods,
            target: configuration.modDeployTarget,
            stagedMacOSDir: stagedMacOS,
            userModsDir: paths.gameUserModsDirectory
        )

        let finalAppBundle = paths.stagedAppBundle
        let finalExecutable = finalAppBundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(GameConstants.stagedExecutableName)

        let report = StagingReport(
            stagedAppPath: finalAppBundle.path,
            stagedExecutablePath: finalExecutable.path,
            windowsPayloadID: windowsPayload.id,
            windowsSts2Sha256: windowsPayload.sts2DllSha256,
            targetPckPath: finalAppBundle
                .appendingPathComponent("Contents/Resources", isDirectory: true)
                .appendingPathComponent(GameConstants.targetPckFileName).path,
            copiedManagedDlls: assemblyResult.copiedManagedDlls,
            preservedMacNativeCount: assemblyResult.preservedMacNativeCount,
            deployedModIDs: deployedModIDs,
            wroteSteamAppID: wroteSteamAppID,
            didAdHocSign: !skipCodeSign,
            steamApiLinked: nativeDeployResult.steamApiLinked,
            bridgeDllInjected: assemblyResult.bridgeDllInjected,
            fmodMode: bridgeRuntime.fmodMode,
            warnings: warnings
        )

        // Persist staging manifest BEFORE ad-hoc codesign so Contents/Resources stays sealed and valid.
        try persistStagingManifest(report, into: stagedResources)

        // 7. Clear quarantine & ad-hoc codesign
        clearQuarantineIfPresent(at: tempAppBundle)

        if !skipCodeSign {
            try adHocSign(appBundle: tempAppBundle)
        }

        // 8. Atomically swap staged .app into place
        if fm.fileExists(atPath: finalAppBundle.path) {
            try fm.removeItem(at: finalAppBundle)
        }
        try fm.moveItem(at: tempAppBundle, to: finalAppBundle)

        return report
    }

    // MARK: - Validation & Godot App Shell

    private func validateBridgeRuntimeReady(_ bridgeRuntime: BridgeRuntimeInfo) throws {
        guard bridgeRuntime.isLaunchReady else {
            let missingNames = bridgeRuntime.components
                .filter { !$0.isReady && !$0.isOptional }
                .map { "\($0.name)（\($0.detail)）" }
            let detail = missingNames.isEmpty
                ? "自建 BridgeRuntime 目录尚未初始化：\(bridgeRuntime.rootPath)"
                : "以下必需组件未就绪：\n- " + missingNames.joined(separator: "\n- ")
            throw LauncherError(
                title: "自建 macOS 桥接运行时未就绪",
                detail: detail,
                recoverySuggestionText: "请先运行 scripts/setup-bridge-runtime.sh 或在启动器中点击“一键安装/重建桥接运行时”。"
            )
        }
    }

    private func prepareGodotAppShell(at appBundle: URL, releaseVersion: String?) throws {
        let fm = FileManager.default
        let contentsDir = appBundle.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contentsDir.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesDir = contentsDir.appendingPathComponent("Resources", isDirectory: true)

        guard let sourceExecutable = BridgeRuntimeInspector.locateGodotReleaseExecutable(in: appBundle) else {
            throw LauncherError(
                title: "Godot 模板缺少可执行主程序",
                detail: "在 \(macOSDir.path) 中未找到可用的 Godot release 主程序。",
                recoverySuggestionText: "请重新运行 scripts/setup-bridge-runtime.sh 重新解压官方 Godot 4.5.1 Mono macOS 导出模板。"
            )
        }

        let targetExecutable = macOSDir.appendingPathComponent(GameConstants.stagedExecutableName)
        if sourceExecutable.standardizedFileURL != targetExecutable.standardizedFileURL {
            if fm.fileExists(atPath: targetExecutable.path) {
                try fm.removeItem(at: targetExecutable)
            }
            try fm.moveItem(at: sourceExecutable, to: targetExecutable)
        }

        // Remove unused debug/duplicate Godot template executables so codesign stays clean and fast.
        let macOSItems = (try? fm.contentsOfDirectory(
            at: macOSDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for item in macOSItems where item.lastPathComponent != GameConstants.stagedExecutableName {
            let lower = item.lastPathComponent.lowercased()
            if lower.contains("godot_macos") || lower.contains("debug") {
                try? fm.removeItem(at: item)
            }
        }

        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetExecutable.path)

        let versionString = (releaseVersion?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? "1.0.0"

        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": GameConstants.stagedExecutableName,
            "CFBundleIdentifier": GameConstants.stagedBundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": GameConstants.gameDisplayName,
            "CFBundleDisplayName": GameConstants.gameDisplayName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": versionString,
            "CFBundleVersion": versionString,
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": true
        ]

        let iconFile = (try? fm.contentsOfDirectory(atPath: resourcesDir.path))?
            .first(where: { $0.lowercased().hasSuffix(".icns") })
        if let iconFile {
            plist["CFBundleIconFile"] = iconFile
        }

        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try plistData.write(to: contentsDir.appendingPathComponent("Info.plist"), options: .atomic)
    }

    // MARK: - .NET 9 osx-arm64 Assembly & Config Synthesis

    private struct DotNetAssemblyResult {
        let copiedManagedDlls: [String]
        let preservedMacNativeCount: Int
        let bridgeDllInjected: Bool
        let warnings: [String]
    }

    private func assembleDotNetDataDirectory(
        windowsPayload: WindowsPayloadInfo,
        bridgeRuntime: BridgeRuntimeInfo,
        into stagedDataDir: URL
    ) throws -> DotNetAssemblyResult {
        let fm = FileManager.default
        let dotnetSourceDir = URL(fileURLWithPath: bridgeRuntime.dotnetRuntimeDirPath)

        // Start from clean osx-arm64 CoreCLR + BCL + GodotSharp.dll
        try SystemCommandRunner.cloneOrCopyItem(from: dotnetSourceDir, to: stagedDataDir)

        // Ensure GodotSharp.dll is present inside data_sts2_macos_arm64
        let targetGodotSharp = stagedDataDir.appendingPathComponent("GodotSharp.dll")
        let bridgeGodotSharp = URL(fileURLWithPath: bridgeRuntime.godotSharpDllPath)
        if !fm.fileExists(atPath: targetGodotSharp.path), fm.fileExists(atPath: bridgeGodotSharp.path) {
            try replaceFile(at: targetGodotSharp, with: bridgeGodotSharp)
        }

        // Capture any template osx-arm64 runtimepack metadata before removing placeholder project configs
        let templateRuntimePack = extractOsxRuntimePackInfo(in: stagedDataDir)
        let templateDotNetVersion = extractRuntimeConfigVersion(in: stagedDataDir)
            ?? normalizeDotNetVersion(bridgeRuntime.dotnetVersion)

        removePlaceholderHostConfigs(in: stagedDataDir)

        let existingMacEntries = (try? fm.contentsOfDirectory(atPath: stagedDataDir.path)) ?? []
        let preservedNativeCount = existingMacEntries.filter { $0.lowercased().hasSuffix(".dylib") }.count
        let existingLowerSet = Set(existingMacEntries.map { $0.lowercased() })

        var copiedDlls: [String] = []
        var warnings: [String] = []

        // 1. Copy Windows sts2.dll (and sts2.pdb if present) and patch PE32+ AMD64 ILONLY -> ARM64
        let targetSts2Dll = stagedDataDir.appendingPathComponent(GameConstants.coreAssemblyFileName)
        try replaceFile(at: targetSts2Dll, with: URL(fileURLWithPath: windowsPayload.sts2DllPath))
        _ = try? PEAssemblyArchPatcher.patchAMD64ILOnlyToARM64(at: targetSts2Dll)
        copiedDlls.append(GameConstants.coreAssemblyFileName)

        let winDataDir = URL(fileURLWithPath: windowsPayload.dataDirectoryPath)
        let winPdb = winDataDir.appendingPathComponent("sts2.pdb")
        if fm.fileExists(atPath: winPdb.path) {
            try replaceFile(at: stagedDataDir.appendingPathComponent("sts2.pdb"), with: winPdb)
        }

        // 2. Overlay pure-managed game dependencies without EVER overwriting macOS CoreCLR/BCL/GodotSharp
        for dllName in windowsPayload.supplementaryManagedDlls {
            let lower = dllName.lowercased()
            guard ManagedAssemblyFilter.isSupplementaryGameManagedDll(fileName: dllName) else {
                continue
            }
            if existingLowerSet.contains(lower) {
                continue
            }
            let src = winDataDir.appendingPathComponent(dllName)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = stagedDataDir.appendingPathComponent(dllName)
            try replaceFile(at: dst, with: src)
            _ = try? PEAssemblyArchPatcher.patchAMD64ILOnlyToARM64(at: dst)
            copiedDlls.append(dllName)
        }

        // 3. Inject STS2MacBridge.dll
        var bridgeDllInjected = false
        if let bridgePath = bridgeRuntime.bridgeDllPath, fm.fileExists(atPath: bridgePath) {
            let bridgeURL = URL(fileURLWithPath: bridgePath)
            try replaceFile(
                at: stagedDataDir.appendingPathComponent(GameConstants.bridgeAssemblyFileName),
                with: bridgeURL
            )
            let bridgePdb = bridgeURL.deletingPathExtension().appendingPathExtension("pdb")
            if fm.fileExists(atPath: bridgePdb.path) {
                try? replaceFile(
                    at: stagedDataDir.appendingPathComponent("STS2MacBridge.pdb"),
                    with: bridgePdb
                )
            }
            bridgeDllInjected = true
        } else {
            warnings.append("未找到 STS2MacBridge.dll，平台兼容补丁（Sentry/DXGI/Steamworks 映射/Mod 路径）将不会自动注入。")
        }

        // 3b. Install libhostfxr_bridge.dylib shim (renaming original libhostfxr.dylib -> libhostfxr_real.dylib)
        // so embedded Godot CoreCLR triggers DOTNET_STARTUP_HOOKS before loading sts2.dll.
        try installHostfxrBridgeShimIfPresent(
            bridgeRuntime: bridgeRuntime,
            into: stagedDataDir
        )

        // 4. Write osx-arm64 sts2.runtimeconfig.json
        try writeOsxRuntimeConfig(
            dotnetVersion: templateDotNetVersion,
            into: stagedDataDir.appendingPathComponent("sts2.runtimeconfig.json")
        )

        // 5. Transform Windows sts2.deps.json -> macOS osx-arm64 sts2.deps.json
        let winDepsURL = winDataDir.appendingPathComponent("sts2.deps.json")
        try writeOsxDepsJson(
            fromWindowsDeps: winDepsURL,
            stagedDataDir: stagedDataDir,
            dotnetVersion: templateDotNetVersion,
            templateRuntimePack: templateRuntimePack,
            bridgeDllInjected: bridgeDllInjected
        )

        return DotNetAssemblyResult(
            copiedManagedDlls: copiedDlls,
            preservedMacNativeCount: preservedNativeCount,
            bridgeDllInjected: bridgeDllInjected,
            warnings: warnings
        )
    }

    private struct TemplateRuntimePackInfo {
        let key: String
        let version: String
        let payload: [String: Any]
    }

    private func extractOsxRuntimePackInfo(in dataDir: URL) -> TemplateRuntimePackInfo? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.lastPathComponent.lowercased().hasSuffix(".deps.json") && url.lastPathComponent.lowercased() != "sts2.deps.json" {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let targets = root["targets"] as? [String: Any] else {
                continue
            }
            for (_, targetObj) in targets {
                guard let targetDict = targetObj as? [String: Any] else { continue }
                for (libKey, libVal) in targetDict where libKey.lowercased().contains("runtimepack.microsoft.netcore.app.runtime.osx-arm64") {
                    if let payload = libVal as? [String: Any] {
                        let version = libKey.split(separator: "/").last.map(String.init) ?? "9.0.0"
                        return TemplateRuntimePackInfo(key: libKey, version: version, payload: payload)
                    }
                }
            }
        }
        return nil
    }

    private func extractRuntimeConfigVersion(in dataDir: URL) -> String? {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)) ?? []
        for url in items where url.lastPathComponent.lowercased().hasSuffix(".runtimeconfig.json") && url.lastPathComponent.lowercased() != "sts2.runtimeconfig.json" {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let options = root["runtimeOptions"] as? [String: Any],
                  let frameworks = options["includedFrameworks"] as? [[String: Any]],
                  let version = frameworks.first?["version"] as? String,
                  !version.isEmpty else {
                continue
            }
            return version
        }
        return nil
    }

    private func removePlaceholderHostConfigs(in dataDir: URL) {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil)) ?? []
        for url in items {
            let lower = url.lastPathComponent.lowercased()
            if (lower.hasSuffix(".deps.json") || lower.hasSuffix(".runtimeconfig.json"))
                && !lower.hasPrefix("sts2.") {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func normalizeDotNetVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".")
        if parts.count >= 3 {
            return trimmed
        }
        if parts.count == 2 {
            return "\(trimmed).0"
        }
        return "9.0.0"
    }

    private func writeOsxRuntimeConfig(dotnetVersion: String, into destinationURL: URL) throws {
        let config: [String: Any] = [
            "runtimeOptions": [
                "tfm": "net9.0",
                "includedFrameworks": [
                    [
                        "name": "Microsoft.NETCore.App",
                        "version": dotnetVersion
                    ]
                ],
                "configProperties": [
                    "System.Reflection.Metadata.MetadataUpdater.IsSupported": false,
                    "System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization": false
                ]
            ]
        ]

        let data = try JSONSerialization.data(
            withJSONObject: config,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: destinationURL, options: .atomic)
    }

    private func writeOsxDepsJson(
        fromWindowsDeps winDepsURL: URL,
        stagedDataDir: URL,
        dotnetVersion: String,
        templateRuntimePack: TemplateRuntimePackInfo?,
        bridgeDllInjected: Bool
    ) throws {
        let fm = FileManager.default
        let stagedFiles = Set(((try? fm.contentsOfDirectory(atPath: stagedDataDir.path)) ?? []))
        let stagedFilesLower = Dictionary(
            stagedFiles.map { ($0.lowercased(), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let targetName = ".NETCoreApp,Version=v9.0/osx-arm64"
        let runtimePackVersion = templateRuntimePack?.version ?? dotnetVersion
        let runtimePackName = "runtimepack.Microsoft.NETCore.App.Runtime.osx-arm64"
        let runtimePackKey = "\(runtimePackName)/\(runtimePackVersion)"

        var newTargetsForOsx: [String: Any] = [:]
        var newLibraries: [String: Any] = [:]
        var declaredManagedFilesLower: Set<String> = [
            GameConstants.coreAssemblyFileName.lowercased()
        ]

        if let data = try? Data(contentsOf: winDepsURL),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let oldTargets = root["targets"] as? [String: Any] ?? [:]
            let oldWinTargetDict: [String: Any] = oldTargets
                .first(where: { $0.key.contains("/") })?
                .value as? [String: Any] ?? [:]

            for (entryKey, entryValue) in oldWinTargetDict {
                if entryKey.lowercased().contains("runtimepack.microsoft.netcore.app.runtime.win") {
                    continue
                }
                guard var entryDict = entryValue as? [String: Any] else { continue }

                // Strip all Windows native segments
                entryDict.removeValue(forKey: "native")
                entryDict.removeValue(forKey: "runtimeTargets")

                // Remap runtimepack dependency on sts2 entry
                if var deps = entryDict["dependencies"] as? [String: Any] {
                    let winPackKeys = deps.keys.filter {
                        $0.lowercased().contains("runtimepack.microsoft.netcore.app.runtime.win")
                    }
                    for winKey in winPackKeys {
                        deps.removeValue(forKey: winKey)
                    }
                    if entryKey.lowercased().hasPrefix("sts2/") {
                        deps[runtimePackName] = runtimePackVersion
                    }
                    entryDict["dependencies"] = deps
                }

                // Prune runtime entries whose DLL does not exist in stagedDataDir
                if let runtimeMap = entryDict["runtime"] as? [String: Any] {
                    var filteredRuntime: [String: Any] = [:]
                    for (assetPath, assetMeta) in runtimeMap {
                        let fileName = URL(fileURLWithPath: assetPath).lastPathComponent
                        if stagedFilesLower[fileName.lowercased()] != nil {
                            filteredRuntime[assetPath] = assetMeta
                            declaredManagedFilesLower.insert(fileName.lowercased())
                        }
                    }
                    if filteredRuntime.isEmpty {
                        entryDict.removeValue(forKey: "runtime")
                    } else {
                        entryDict["runtime"] = filteredRuntime
                    }
                }

                newTargetsForOsx[entryKey] = entryDict
            }

            if let oldLibs = root["libraries"] as? [String: Any] {
                for (libKey, libVal) in oldLibs {
                    if libKey.lowercased().contains("runtimepack.microsoft.netcore.app.runtime.win") {
                        continue
                    }
                    newLibraries[libKey] = libVal
                }
            }
        } else {
            // Minimal fallback when Windows payload has no sts2.deps.json
            newTargetsForOsx["sts2/0.1.0"] = [
                "dependencies": [
                    runtimePackName: runtimePackVersion
                ],
                "runtime": [
                    GameConstants.coreAssemblyFileName: [:] as [String: Any]
                ]
            ]
            newLibraries["sts2/0.1.0"] = [
                "type": "project",
                "serviceable": false,
                "sha512": ""
            ]
        }

        if bridgeDllInjected {
            declaredManagedFilesLower.insert(GameConstants.bridgeAssemblyFileName.lowercased())
            newTargetsForOsx["STS2MacBridge/1.0.0"] = [
                "runtime": [
                    GameConstants.bridgeAssemblyFileName: [:] as [String: Any]
                ]
            ]
            newLibraries["STS2MacBridge/1.0.0"] = [
                "type": "reference",
                "serviceable": false,
                "sha512": ""
            ]
        }

        // Build osx-arm64 runtimepack entry from template or actual files in stagedDataDir
        let osxRuntimePackPayload: [String: Any]
        if let templateRuntimePack {
            osxRuntimePackPayload = filterRuntimePackPayload(
                templateRuntimePack.payload,
                existingFilesLower: stagedFilesLower,
                excludingManagedLower: declaredManagedFilesLower
            )
        } else {
            var runtimeDict: [String: Any] = [:]
            var nativeDict: [String: Any] = [:]
            for file in stagedFiles.sorted() {
                let lower = file.lowercased()
                if lower.hasSuffix(".dll"), !declaredManagedFilesLower.contains(lower) {
                    runtimeDict[file] = [:] as [String: Any]
                } else if lower.hasSuffix(".dylib") {
                    nativeDict[file] = [:] as [String: Any]
                }
            }
            osxRuntimePackPayload = [
                "runtime": runtimeDict,
                "native": nativeDict
            ]
        }

        newTargetsForOsx[runtimePackKey] = osxRuntimePackPayload
        newLibraries[runtimePackKey] = [
            "type": "runtimepack",
            "serviceable": false,
            "sha512": ""
        ]

        let finalDeps: [String: Any] = [
            "runtimeTarget": [
                "name": targetName,
                "signature": ""
            ],
            "compilationOptions": [:] as [String: Any],
            "targets": [
                ".NETCoreApp,Version=v9.0": [:] as [String: Any],
                targetName: newTargetsForOsx
            ],
            "libraries": newLibraries,
            "runtimes": [
                "osx-arm64": ["osx", "unix", "any", "base"]
            ]
        ]

        let outputData = try JSONSerialization.data(
            withJSONObject: finalDeps,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try outputData.write(to: stagedDataDir.appendingPathComponent("sts2.deps.json"), options: .atomic)
    }

    private func filterRuntimePackPayload(
        _ payload: [String: Any],
        existingFilesLower: [String: String],
        excludingManagedLower: Set<String>
    ) -> [String: Any] {
        var filtered: [String: Any] = [:]
        if let runtimeMap = payload["runtime"] as? [String: Any] {
            var kept: [String: Any] = [:]
            for (assetPath, meta) in runtimeMap {
                let fileNameLower = URL(fileURLWithPath: assetPath).lastPathComponent.lowercased()
                if existingFilesLower[fileNameLower] != nil && !excludingManagedLower.contains(fileNameLower) {
                    kept[assetPath] = meta
                }
            }
            filtered["runtime"] = kept
        }
        if let nativeMap = payload["native"] as? [String: Any] {
            var kept: [String: Any] = [:]
            for (assetPath, meta) in nativeMap {
                let fileNameLower = URL(fileURLWithPath: assetPath).lastPathComponent.lowercased()
                if existingFilesLower[fileNameLower] != nil {
                    kept[assetPath] = meta
                }
            }
            filtered["native"] = kept
        }
        return filtered
    }

    // MARK: - GDExtensions & Native Stubs Deployment

    private struct NativeDeployResult {
        let steamApiLinked: Bool
        let warnings: [String]
    }

    private func deployGDExtensionsAndStubs(
        bridgeRuntime: BridgeRuntimeInfo,
        configuration: LaunchConfiguration,
        stagedFrameworksDir: URL,
        stagedResourcesDir: URL,
        stagedDataDir: URL
    ) throws -> NativeDeployResult {
        let fm = FileManager.default
        var warnings: [String] = []

        // 1. Spine 4.2 GDExtension (Contents/Frameworks + res://addons/spine/macos/)
        if let spinePath = bridgeRuntime.spineFrameworkPath, fm.fileExists(atPath: spinePath) {
            let sourceURL = URL(fileURLWithPath: spinePath)
            let fwDestURL = stagedFrameworksDir.appendingPathComponent("libspine_godot.macos.template_release.framework")
            let resSpineDir = stagedResourcesDir.appendingPathComponent("addons/spine/macos", isDirectory: true)
            try fm.createDirectory(at: resSpineDir, withIntermediateDirectories: true)
            let resDestURL = resSpineDir.appendingPathComponent("libspine_godot.macos.template_release.framework")

            if sourceURL.pathExtension.lowercased() == "framework" {
                try SystemCommandRunner.cloneOrCopyItem(from: sourceURL, to: fwDestURL)
                try SystemCommandRunner.cloneOrCopyItem(from: sourceURL, to: resDestURL)
            } else {
                try wrapDylibAsFramework(
                    dylibURL: sourceURL,
                    frameworkName: "libspine_godot.macos.template_release",
                    in: stagedFrameworksDir
                )
                try SystemCommandRunner.cloneOrCopyItem(from: fwDestURL, to: resDestURL)
            }
        } else {
            warnings.append("Spine 扩展缺失，角色骨骼动画可能无法渲染。")
        }

        // 2. FMOD GDExtension & Core/Studio dylibs (Contents/Frameworks + res://addons/fmod/libs/macos/)
        let resFmodDir = stagedResourcesDir.appendingPathComponent("addons/fmod/libs/macos", isDirectory: true)
        if let fmodFwPath = bridgeRuntime.fmodFrameworkPath, fm.fileExists(atPath: fmodFwPath) {
            let sourceURL = URL(fileURLWithPath: fmodFwPath)
            try fm.createDirectory(at: resFmodDir, withIntermediateDirectories: true)
            let fwDestURL = stagedFrameworksDir.appendingPathComponent("libGodotFmod.macos.template_release.framework")
            let resDestURL = resFmodDir.appendingPathComponent("libGodotFmod.macos.template_release.framework")

            if sourceURL.pathExtension.lowercased() == "framework" {
                try SystemCommandRunner.cloneOrCopyItem(from: sourceURL, to: fwDestURL)
                try SystemCommandRunner.cloneOrCopyItem(from: sourceURL, to: resDestURL)
            } else {
                try wrapDylibAsFramework(
                    dylibURL: sourceURL,
                    frameworkName: "libGodotFmod.macos.template_release",
                    in: stagedFrameworksDir
                )
                try SystemCommandRunner.cloneOrCopyItem(from: fwDestURL, to: resDestURL)
                try replaceFile(
                    at: stagedFrameworksDir.appendingPathComponent("libGodotFmod.macos.template_release.dylib"),
                    with: sourceURL
                )
            }
        }

        for dylibPath in bridgeRuntime.fmodDylibPaths where fm.fileExists(atPath: dylibPath) {
            let sourceURL = URL(fileURLWithPath: dylibPath)
            try replaceFile(
                at: stagedFrameworksDir.appendingPathComponent(sourceURL.lastPathComponent),
                with: sourceURL
            )
            try fm.createDirectory(at: resFmodDir, withIntermediateDirectories: true)
            try replaceFile(
                at: resFmodDir.appendingPathComponent(sourceURL.lastPathComponent),
                with: sourceURL
            )
        }

        // 3. Sentry GDExtension & dependency stubs (Contents/Frameworks + res://addons/sentry/bin/macos/)
        let resSentryDir = stagedResourcesDir.appendingPathComponent("addons/sentry/bin/macos", isDirectory: true)
        if let sentryStubPath = bridgeRuntime.sentryStubDylibPath, fm.fileExists(atPath: sentryStubPath) {
            let sourceURL = URL(fileURLWithPath: sentryStubPath)
            try replaceFile(
                at: stagedFrameworksDir.appendingPathComponent("libsentry.macos.release.dylib"),
                with: sourceURL
            )
            try fm.createDirectory(at: resSentryDir, withIntermediateDirectories: true)
            try replaceFile(
                at: resSentryDir.appendingPathComponent("libsentry.macos.release.dylib"),
                with: sourceURL
            )
        }
        if let sentryDepPath = bridgeRuntime.sentryDepDylibPath, fm.fileExists(atPath: sentryDepPath) {
            let sourceURL = URL(fileURLWithPath: sentryDepPath)
            try replaceFile(
                at: stagedFrameworksDir.appendingPathComponent("libSentry.dylib"),
                with: sourceURL
            )
            try fm.createDirectory(at: resSentryDir, withIntermediateDirectories: true)
            try replaceFile(
                at: resSentryDir.appendingPathComponent("libSentry.dylib"),
                with: sourceURL
            )
        }

        // 4. Optional legitimate macOS Steamworks runtime library (user-provided libsteam_api.dylib)
        var steamApiLinked = false
        let resolvedSteamApiPath = [configuration.customSteamApiDylibPath, bridgeRuntime.steamApiDylibPath]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && fm.fileExists(atPath: $0) }

        if let steamApiPath = resolvedSteamApiPath {
            let sourceURL = URL(fileURLWithPath: steamApiPath)
            let steamNames = ["libsteam_api.dylib", "libsteam_api64.dylib"]
            for steamName in steamNames {
                try replaceFile(
                    at: stagedFrameworksDir.appendingPathComponent(steamName),
                    with: sourceURL
                )
                // Also place next to managed assemblies so CoreCLR P/Invoke resolves steam_api / steam_api64 directly
                try replaceFile(
                    at: stagedDataDir.appendingPathComponent(steamName),
                    with: sourceURL
                )
            }
            steamApiLinked = true
        } else {
            warnings.append("未配置 macOS libsteam_api.dylib；若导入的是 Steam 版本并需连接本地 Steam 客户端，请在设置中指定 libsteam_api.dylib 路径。")
        }

        return NativeDeployResult(steamApiLinked: steamApiLinked, warnings: warnings)
    }

    private func wrapDylibAsFramework(
        dylibURL: URL,
        frameworkName: String,
        in frameworksDir: URL
    ) throws {
        let fm = FileManager.default
        let frameworkDir = frameworksDir.appendingPathComponent("\(frameworkName).framework", isDirectory: true)
        let resourcesDir = frameworkDir.appendingPathComponent("Resources", isDirectory: true)
        if fm.fileExists(atPath: frameworkDir.path) {
            try fm.removeItem(at: frameworkDir)
        }
        try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

        let binaryDest = frameworkDir.appendingPathComponent(frameworkName)
        try replaceFile(at: binaryDest, with: dylibURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryDest.path)

        let plist: [String: Any] = [
            "CFBundleExecutable": frameworkName,
            "CFBundleIdentifier": "io.github.lengsukq.sts2-mac-bridge.\(frameworkName)",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": frameworkName,
            "CFBundlePackageType": "FMWK",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1.0.0"
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: resourcesDir.appendingPathComponent("Info.plist"), options: .atomic)
    }

    // MARK: - Helpers

    private func writePerformanceOverrideConfig(
        stagedResourcesDir: URL,
        stagedMacOSDir: URL
    ) throws {
        let overrideText = """
        [debug]

        settings/gdscript/always_track_call_stacks=false

        [rendering]

        shader_compiler/shader_cache/enabled=true
        shader_compiler/shader_cache/compress=true
        rendering_device/pipeline_cache/enable=true
        """ + "\n"
        let data = Data(overrideText.utf8)
        try data.write(to: stagedResourcesDir.appendingPathComponent("override.cfg"), options: .atomic)
        try data.write(to: stagedMacOSDir.appendingPathComponent("override.cfg"), options: .atomic)
    }

    private func installHostfxrBridgeShimIfPresent(
        bridgeRuntime: BridgeRuntimeInfo,
        into stagedDataDir: URL
    ) throws {
        let fm = FileManager.default
        var candidates: [URL] = [
            URL(fileURLWithPath: bridgeRuntime.rootPath)
                .appendingPathComponent("stubs/libhostfxr_bridge.dylib")
        ]
        if let sentryStubPath = bridgeRuntime.sentryStubDylibPath {
            candidates.append(
                URL(fileURLWithPath: sentryStubPath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("libhostfxr_bridge.dylib")
            )
        }

        guard let shimSource = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
            return
        }

        let stagedHostfxr = stagedDataDir.appendingPathComponent("libhostfxr.dylib")
        let stagedHostfxrReal = stagedDataDir.appendingPathComponent("libhostfxr_real.dylib")
        guard fm.fileExists(atPath: stagedHostfxr.path) else {
            return
        }

        if fm.fileExists(atPath: stagedHostfxrReal.path) {
            try fm.removeItem(at: stagedHostfxrReal)
        }
        try fm.moveItem(at: stagedHostfxr, to: stagedHostfxrReal)
        try replaceFile(at: stagedHostfxr, with: shimSource)
    }

    private func replaceFile(at destination: URL, with source: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try SystemCommandRunner.cloneOrCopyItem(from: source, to: destination)
    }

    private func deployMods(
        _ mods: [ModItem],
        target: ModDeployTarget,
        stagedMacOSDir: URL,
        userModsDir: URL
    ) throws -> [String] {
        var targetDirs: [URL] = []
        switch target {
        case .both:
            targetDirs = [stagedMacOSDir.appendingPathComponent(GameConstants.modsFolderName, isDirectory: true), userModsDir]
        case .userDataOnly:
            targetDirs = [userModsDir]
        case .bundleOnly:
            targetDirs = [stagedMacOSDir.appendingPathComponent(GameConstants.modsFolderName, isDirectory: true)]
        }

        let fm = FileManager.default
        let markerFileName = ".sts2_launcher_managed"
        let legacyOrderFileName = "sts2_launcher_mod_order.json"

        for destinationModsDir in targetDirs {
            try fm.createDirectory(at: destinationModsDir, withIntermediateDirectories: true)

            // Clean up legacy order file inside mods/ so STS2's ModManager never tries to parse it as a ModManifest.
            let legacyOrderFile = destinationModsDir.appendingPathComponent(legacyOrderFileName)
            if fm.fileExists(atPath: legacyOrderFile.path) {
                try? fm.removeItem(at: legacyOrderFile)
            }

            let existing = (try? fm.contentsOfDirectory(
                at: destinationModsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            // Only remove subdirectories previously managed by this launcher so user manual files stay safe.
            for dir in existing {
                let marker = dir.appendingPathComponent(markerFileName)
                if fm.fileExists(atPath: marker.path) {
                    try fm.removeItem(at: dir)
                }
            }

            for mod in mods {
                let targetModDir = destinationModsDir.appendingPathComponent(mod.folderName, isDirectory: true)
                try SystemCommandRunner.cloneOrCopyItem(
                    from: URL(fileURLWithPath: mod.folderPath),
                    to: targetModDir
                )
                try Data(mod.id.utf8).write(
                    to: targetModDir.appendingPathComponent(markerFileName),
                    options: .atomic
                )
            }
        }

        return mods.map(\.id)
    }

    private func clearQuarantineIfPresent(at appBundle: URL) {
        _ = try? SystemCommandRunner.run(
            executablePath: "/usr/bin/xattr",
            arguments: ["-dr", "com.apple.quarantine", appBundle.path]
        )
    }

    private func adHocSign(appBundle: URL) throws {
        let fm = FileManager.default
        let dataDir = appBundle.appendingPathComponent("Contents/Resources/\(GameConstants.macDataDirectoryName)", isDirectory: true)
        let addonsDir = appBundle.appendingPathComponent("Contents/Resources/addons", isDirectory: true)
        let frameworksDir = appBundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)

        // Sign embedded .dylib files inside data_sts2_macos_arm64 first so strict verification passes.
        if let dataItems = try? fm.contentsOfDirectory(at: dataDir, includingPropertiesForKeys: nil) {
            for item in dataItems where item.pathExtension.lowercased() == "dylib" {
                try signSingleBinary(at: item)
            }
        }

        // Sign mirrored GDExtension dylibs & frameworks under Contents/Resources/addons/
        if fm.fileExists(atPath: addonsDir.path),
           let enumerator = fm.enumerator(at: addonsDir, includingPropertiesForKeys: nil) {
            var nestedDylibs: [URL] = []
            var nestedFrameworks: [URL] = []
            for case let itemURL as URL in enumerator {
                let ext = itemURL.pathExtension.lowercased()
                if ext == "framework" {
                    nestedFrameworks.append(itemURL)
                    enumerator.skipDescendants()
                } else if ext == "dylib" {
                    nestedDylibs.append(itemURL)
                }
            }
            for item in nestedDylibs {
                try signSingleBinary(at: item)
            }
            for item in nestedFrameworks {
                try signSingleBinary(at: item)
            }
        }

        // Sign individual .dylibs and .framework bundles inside Contents/Frameworks/
        if let fwItems = try? fm.contentsOfDirectory(at: frameworksDir, includingPropertiesForKeys: nil) {
            for item in fwItems where item.pathExtension.lowercased() == "dylib" {
                try signSingleBinary(at: item)
            }
            for item in fwItems where item.pathExtension.lowercased() == "framework" {
                try signSingleBinary(at: item)
            }
        }

        let result = try SystemCommandRunner.run(
            executablePath: "/usr/bin/codesign",
            arguments: ["--force", "--deep", "--sign", "-", appBundle.path]
        )
        guard result.exitCode == 0 else {
            throw LauncherError(
                title: "Staged 应用重签失败",
                detail: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                dataSafetyNote: "原始游戏包与 BridgeRuntime 均未改动，本次合成已安全中止。",
                recoverySuggestionText: "请确认 Xcode Command Line Tools 已安装（codesign 可用），并检查磁盘权限。"
            )
        }
    }

    private func signSingleBinary(at url: URL) throws {
        let result = try SystemCommandRunner.run(
            executablePath: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", url.path]
        )
        guard result.exitCode == 0 else {
            throw LauncherError(
                title: "内置动态库重签失败",
                detail: "签名 \(url.lastPathComponent) 失败：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                dataSafetyNote: "原始游戏包与 BridgeRuntime 均未改动，本次合成已安全中止。",
                recoverySuggestionText: "请检查 BridgeRuntime 内动态库完整性并重新运行搭建脚本。"
            )
        }
    }

    private func persistStagingManifest(_ report: StagingReport, into resourcesDir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let manifestURL = resourcesDir.appendingPathComponent(GameConstants.stagingManifestFileName)
        try data.write(to: manifestURL, options: .atomic)
    }
}
