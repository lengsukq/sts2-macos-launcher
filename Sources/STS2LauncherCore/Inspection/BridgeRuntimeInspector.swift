import Foundation

private struct BridgeRuntimeManifestFile: Decodable {
    let godotVersion: String?
    let dotnetVersion: String?
    let spineVersion: String?
    let fmodVersion: String?
    let fmodMode: String?
    let godotTemplateAppPath: String?
    let dotnetRuntimeDirPath: String?
    let godotSharpDllPath: String?
    let spineFrameworkPath: String?
    let fmodFrameworkPath: String?
    let fmodDylibPaths: [String]?
    let sentryStubDylibPath: String?
    let sentryDepDylibPath: String?
    let steamApiDylibPath: String?
    let hostfxrBridgeDylibPath: String?
    let bridgeDllPath: String?
}

public struct BridgeRuntimeInspector: Sendable {
    public init() {}

    public func inspect(paths: LauncherPaths, customRootPath: String? = nil) -> BridgeRuntimeInfo {
        let userRootURL = resolvePrimaryRootDirectory(paths: paths, customRootPath: customRootPath)
        let bundledRootURL: URL? = isNonEmpty(customRootPath) ? nil : paths.bundledBridgeRuntimeDirectory
        let userManifest = loadManifest(at: userRootURL.appendingPathComponent(GameConstants.bridgeManifestFileName))
        let bundledManifest = bundledRootURL.flatMap {
            loadManifest(at: $0.appendingPathComponent(GameConstants.bridgeManifestFileName))
        }

        let effectiveRootURL = resolveEffectiveRootURL(
            userRootURL: userRootURL,
            bundledRootURL: bundledRootURL,
            userManifest: userManifest,
            bundledManifest: bundledManifest
        )

        let godotVersion = nonEmpty(userManifest?.godotVersion) ?? nonEmpty(bundledManifest?.godotVersion) ?? "4.5.1-stable"
        let dotnetVersion = nonEmpty(userManifest?.dotnetVersion) ?? nonEmpty(bundledManifest?.dotnetVersion) ?? "9.0"
        let spineVersion = nonEmpty(userManifest?.spineVersion) ?? nonEmpty(bundledManifest?.spineVersion) ?? "4.2"
        let fmodVersion = nonEmpty(userManifest?.fmodVersion) ?? nonEmpty(bundledManifest?.fmodVersion) ?? "2.03.06"

        let godotTemplateAppPath = existingResolvedPath(userManifest?.godotTemplateAppPath, relativeTo: userRootURL)
            ?? discoverGodotTemplateApp(in: userRootURL)
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.godotTemplateAppPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { discoverGodotTemplateApp(in: $0) }
            ?? effectiveRootURL.appendingPathComponent("godot-template/macos_template.app").path

        let dotnetRuntimeDirPath = existingResolvedPath(userManifest?.dotnetRuntimeDirPath, relativeTo: userRootURL)
            ?? existingPath(userRootURL.appendingPathComponent("dotnet-osx-arm64"))
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.dotnetRuntimeDirPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { existingPath($0.appendingPathComponent("dotnet-osx-arm64")) }
            ?? effectiveRootURL.appendingPathComponent("dotnet-osx-arm64").path

        let godotSharpDllPath = existingResolvedPath(userManifest?.godotSharpDllPath, relativeTo: userRootURL)
            ?? discoverGodotSharpDll(in: userRootURL, dotnetRuntimeDirPath: dotnetRuntimeDirPath)
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.godotSharpDllPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { discoverGodotSharpDll(in: $0, dotnetRuntimeDirPath: dotnetRuntimeDirPath) }
            ?? URL(fileURLWithPath: dotnetRuntimeDirPath).appendingPathComponent("GodotSharp.dll").path

        let spineFrameworkPath = existingResolvedPath(userManifest?.spineFrameworkPath, relativeTo: userRootURL)
            ?? discoverSpineFramework(in: userRootURL)
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.spineFrameworkPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { discoverSpineFramework(in: $0) }

        let userFullFmodFramework = existingResolvedPath(userManifest?.fmodFrameworkPath, relativeTo: userRootURL)
            ?? discoverRealFmodFramework(in: userRootURL)
        let bundledFullFmodFramework = bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.fmodFrameworkPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { discoverRealFmodFramework(in: $0) }
        let userStubFmodFramework = existingPath(userRootURL.appendingPathComponent("stubs/libGodotFmod.stub.dylib"))
        let bundledStubFmodFramework = bundledRootURL.flatMap { existingPath($0.appendingPathComponent("stubs/libGodotFmod.stub.dylib")) }

        let userHasRealFmod = (userFullFmodFramework != nil && !(userFullFmodFramework!.lowercased().contains("stub")))
        let fmodFrameworkPath: String?
        if userHasRealFmod {
            fmodFrameworkPath = userFullFmodFramework
        } else if let bundledFull = bundledFullFmodFramework, !bundledFull.lowercased().contains("stub") {
            fmodFrameworkPath = bundledFull
        } else {
            fmodFrameworkPath = userFullFmodFramework ?? userStubFmodFramework ?? bundledFullFmodFramework ?? bundledStubFmodFramework
        }

        let userManifestDylibs = (userManifest?.fmodDylibPaths ?? [])
            .compactMap { existingResolvedPath($0, relativeTo: userRootURL) }
        let userDiscoveredDylibs = discoverFmodDylibs(in: userRootURL)
        let bundledManifestDylibs = bundledRootURL.map { root in
            (bundledManifest?.fmodDylibPaths ?? []).compactMap { existingResolvedPath($0, relativeTo: root) }
        } ?? []
        let bundledDiscoveredDylibs = bundledRootURL.map { discoverFmodDylibs(in: $0) } ?? []

        let fmodDylibPaths: [String]
        if !userManifestDylibs.isEmpty {
            fmodDylibPaths = userManifestDylibs
        } else if !userDiscoveredDylibs.isEmpty {
            fmodDylibPaths = userDiscoveredDylibs
        } else if !bundledManifestDylibs.isEmpty {
            fmodDylibPaths = bundledManifestDylibs
        } else {
            fmodDylibPaths = bundledDiscoveredDylibs
        }

        let sentryStubDylibPath = existingResolvedPath(userManifest?.sentryStubDylibPath, relativeTo: userRootURL)
            ?? existingPath(userRootURL.appendingPathComponent("stubs/libsentry.macos.release.dylib"))
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.sentryStubDylibPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { existingPath($0.appendingPathComponent("stubs/libsentry.macos.release.dylib")) }

        let sentryDepDylibPath = existingResolvedPath(userManifest?.sentryDepDylibPath, relativeTo: userRootURL)
            ?? existingPath(userRootURL.appendingPathComponent("stubs/libSentry.dylib"))
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.sentryDepDylibPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { existingPath($0.appendingPathComponent("stubs/libSentry.dylib")) }

        let steamApiDylibPath = existingResolvedPath(userManifest?.steamApiDylibPath, relativeTo: userRootURL)
            ?? existingPath(userRootURL.appendingPathComponent("steam/libsteam_api.dylib"))
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.steamApiDylibPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { existingPath($0.appendingPathComponent("steam/libsteam_api.dylib")) }

        let hostfxrBridgePath = existingResolvedPath(userManifest?.hostfxrBridgeDylibPath, relativeTo: userRootURL)
            ?? existingPath(userRootURL.appendingPathComponent("stubs/libhostfxr_bridge.dylib"))
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.hostfxrBridgeDylibPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { existingPath($0.appendingPathComponent("stubs/libhostfxr_bridge.dylib")) }

        let bridgeDllPath = existingResolvedPath(userManifest?.bridgeDllPath, relativeTo: userRootURL)
            ?? existingPath(userRootURL.appendingPathComponent("bridge/\(GameConstants.bridgeAssemblyFileName)"))
            ?? existingPath(userRootURL.appendingPathComponent(GameConstants.bridgeAssemblyFileName))
            ?? bundledRootURL.flatMap { existingResolvedPath(bundledManifest?.bridgeDllPath, relativeTo: $0) }
            ?? bundledRootURL.flatMap { existingPath($0.appendingPathComponent("bridge/\(GameConstants.bridgeAssemblyFileName)")) }

        let explicitFmodMode: String? = (userHasRealFmod || !userDiscoveredDylibs.isEmpty)
            ? nil
            : (nonEmpty(userManifest?.fmodMode) ?? nonEmpty(bundledManifest?.fmodMode))
        let inferredFmodMode = inferFmodMode(
            manifestMode: explicitFmodMode,
            fmodFrameworkPath: fmodFrameworkPath,
            fmodDylibPaths: fmodDylibPaths
        )

        let components: [BridgeComponentState] = [
            inspectGodotComponent(version: godotVersion, appPath: godotTemplateAppPath),
            inspectDotNetComponent(
                version: dotnetVersion,
                runtimeDirPath: dotnetRuntimeDirPath,
                godotSharpDllPath: godotSharpDllPath
            ),
            inspectSpineComponent(version: spineVersion, frameworkPath: spineFrameworkPath),
            inspectFmodComponent(
                version: fmodVersion,
                fmodMode: inferredFmodMode,
                frameworkPath: fmodFrameworkPath,
                dylibPaths: fmodDylibPaths
            ),
            inspectNativeStubsComponent(
                sentryStubPath: sentryStubDylibPath,
                sentryDepPath: sentryDepDylibPath,
                hostfxrBridgePath: hostfxrBridgePath
            ),
            inspectBridgeAssemblyComponent(bridgeDllPath: bridgeDllPath)
        ]

        return BridgeRuntimeInfo(
            rootPath: effectiveRootURL.path,
            godotVersion: godotVersion,
            dotnetVersion: dotnetVersion,
            spineVersion: spineVersion,
            fmodVersion: fmodVersion,
            fmodMode: inferredFmodMode,
            godotTemplateAppPath: godotTemplateAppPath,
            dotnetRuntimeDirPath: dotnetRuntimeDirPath,
            godotSharpDllPath: godotSharpDllPath,
            spineFrameworkPath: spineFrameworkPath,
            fmodFrameworkPath: fmodFrameworkPath,
            fmodDylibPaths: fmodDylibPaths,
            sentryStubDylibPath: sentryStubDylibPath,
            sentryDepDylibPath: sentryDepDylibPath,
            steamApiDylibPath: steamApiDylibPath,
            bridgeDllPath: bridgeDllPath,
            components: components
        )
    }

    // MARK: - Component Checks

    private func inspectGodotComponent(version: String, appPath: String) -> BridgeComponentState {
        let name = "Godot \(version) Mono"
        let appURL = URL(fileURLWithPath: appPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: appURL.path, isDirectory: &isDir), isDir.boolValue else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "未找到 macOS 导出模板 (.app)，请运行一键搭建脚本。",
                path: appPath
            )
        }

        guard let execURL = Self.locateGodotReleaseExecutable(in: appURL) else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "导出模板缺少 Contents/MacOS 可执行主程序。",
                path: appPath
            )
        }

        let archs = Self.detectArchitectures(of: execURL)
        guard archs.contains("arm64") else {
            let archText = archs.isEmpty ? "非 Mach-O 或无法识别" : archs.joined(separator: ", ")
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "主程序 \(execURL.lastPathComponent) 不包含 arm64 架构（检测到：\(archText)）。",
                path: execURL.path
            )
        }

        return BridgeComponentState(
            name: name,
            isReady: true,
            isOptional: false,
            detail: "已就绪 · \(execURL.lastPathComponent) (\(archs.joined(separator: "/")))",
            path: appPath
        )
    }

    private func inspectDotNetComponent(
        version: String,
        runtimeDirPath: String,
        godotSharpDllPath: String
    ) -> BridgeComponentState {
        let name = ".NET \(version) osx-arm64"
        let fm = FileManager.default
        let runtimeDir = URL(fileURLWithPath: runtimeDirPath)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: runtimeDir.path, isDirectory: &isDir), isDir.boolValue else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "未找到 dotnet-osx-arm64 运行时目录。",
                path: runtimeDirPath
            )
        }

        let requiredDylibs = ["libhostfxr.dylib", "libcoreclr.dylib", "libclrjit.dylib"]
        let missingDylibs = requiredDylibs.filter { !fm.fileExists(atPath: runtimeDir.appendingPathComponent($0).path) }
        if !missingDylibs.isEmpty {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "缺少 CoreCLR 核心库：\(missingDylibs.joined(separator: ", "))。",
                path: runtimeDirPath
            )
        }

        let coreClrURL = runtimeDir.appendingPathComponent("libcoreclr.dylib")
        let archs = Self.detectArchitectures(of: coreClrURL)
        guard archs.contains("arm64") else {
            let archText = archs.isEmpty ? "未知" : archs.joined(separator: ", ")
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "libcoreclr.dylib 不是 arm64 架构（检测到：\(archText)）。",
                path: coreClrURL.path
            )
        }

        guard fm.fileExists(atPath: godotSharpDllPath) else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "缺少 GodotSharp.dll（预期位置：\(godotSharpDllPath)）。",
                path: godotSharpDllPath
            )
        }

        let entries = (try? fm.contentsOfDirectory(atPath: runtimeDir.path)) ?? []
        let dllCount = entries.filter { $0.lowercased().hasSuffix(".dll") }.count
        let dylibCount = entries.filter { $0.lowercased().hasSuffix(".dylib") }.count

        return BridgeComponentState(
            name: name,
            isReady: true,
            isOptional: false,
            detail: "已就绪 · CoreCLR arm64（\(dylibCount) dylib / \(dllCount) BCL DLL + GodotSharp.dll）",
            path: runtimeDirPath
        )
    }

    private func inspectSpineComponent(version: String, frameworkPath: String?) -> BridgeComponentState {
        let name = "Spine \(version)"
        guard let frameworkPath, FileManager.default.fileExists(atPath: frameworkPath) else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "未找到 libspine_godot.macos.template_release.framework。",
                path: frameworkPath
            )
        }

        let url = URL(fileURLWithPath: frameworkPath)
        guard let binaryURL = Self.locateMachOBinary(in: url) else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "Spine 框架内缺少可执行动态库二进制。",
                path: frameworkPath
            )
        }

        let archs = Self.detectArchitectures(of: binaryURL)
        guard archs.contains("arm64") else {
            let archText = archs.isEmpty ? "未知" : archs.joined(separator: ", ")
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "Spine 扩展不包含 arm64 架构（检测到：\(archText)）。",
                path: frameworkPath
            )
        }

        return BridgeComponentState(
            name: name,
            isReady: true,
            isOptional: false,
            detail: "已就绪 · \(url.lastPathComponent) (\(archs.joined(separator: "/")))",
            path: frameworkPath
        )
    }

    private func inspectFmodComponent(
        version: String,
        fmodMode: String,
        frameworkPath: String?,
        dylibPaths: [String]
    ) -> BridgeComponentState {
        let name = "FMOD \(version)"
        let fm = FileManager.default

        if fmodMode == "full" {
            guard let frameworkPath, fm.fileExists(atPath: frameworkPath),
                  let fwBinary = Self.locateMachOBinary(in: URL(fileURLWithPath: frameworkPath)) else {
                return BridgeComponentState(
                    name: name,
                    isReady: false,
                    isOptional: true,
                    detail: "完整音频模式缺少 libGodotFmod.macos.template_release.framework。",
                    path: frameworkPath
                )
            }
            let fwArchs = Self.detectArchitectures(of: fwBinary)
            guard fwArchs.contains("arm64") else {
                return BridgeComponentState(
                    name: name,
                    isReady: false,
                    isOptional: true,
                    detail: "libGodotFmod 不包含 arm64 架构（检测到：\(fwArchs.joined(separator: ", "))）。",
                    path: frameworkPath
                )
            }

            let existingDylibs = dylibPaths.filter { fm.fileExists(atPath: $0) }
            let lowerNames = Set(existingDylibs.map { URL(fileURLWithPath: $0).lastPathComponent.lowercased() })
            let hasCore = lowerNames.contains("libfmod.dylib")
            let hasStudio = lowerNames.contains("libfmodstudio.dylib")
            guard hasCore && hasStudio else {
                return BridgeComponentState(
                    name: name,
                    isReady: false,
                    isOptional: true,
                    detail: "缺少 libfmod.dylib 或 libfmodstudio.dylib。",
                    path: frameworkPath
                )
            }

            for dylib in existingDylibs {
                let dylibArchs = Self.detectArchitectures(of: URL(fileURLWithPath: dylib))
                if !dylibArchs.contains("arm64") {
                    return BridgeComponentState(
                        name: name,
                        isReady: false,
                        isOptional: true,
                        detail: "\(URL(fileURLWithPath: dylib).lastPathComponent) 不包含 arm64 架构。",
                        path: dylib
                    )
                }
            }

            return BridgeComponentState(
                name: name,
                isReady: true,
                isOptional: false,
                detail: "完整音频模式 (full) · arm64 + \(existingDylibs.count) 个 FMOD 动态库",
                path: frameworkPath
            )
        }

        if let frameworkPath, fm.fileExists(atPath: frameworkPath),
           let stubBinary = Self.locateMachOBinary(in: URL(fileURLWithPath: frameworkPath)) {
            let archs = Self.detectArchitectures(of: stubBinary)
            if archs.contains("arm64") {
                return BridgeComponentState(
                    name: name,
                    isReady: true,
                    isOptional: true,
                    detail: "静音兜底模式 (stub) · arm64",
                    path: frameworkPath
                )
            }
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: true,
                detail: "FMOD 兜底库不含 arm64 架构。",
                path: frameworkPath
            )
        }

        return BridgeComponentState(
            name: name,
            isReady: false,
            isOptional: true,
            detail: "未检测到 FMOD 扩展或兜底 stub（游戏可静音运行，建议运行搭建脚本补全）。",
            path: frameworkPath
        )
    }

    private func inspectNativeStubsComponent(
        sentryStubPath: String?,
        sentryDepPath: String?,
        hostfxrBridgePath: String?
    ) -> BridgeComponentState {
        let name = "Native Bridges"
        let items: [(String, String?)] = [
            ("libsentry.macos.release.dylib", sentryStubPath),
            ("libSentry.dylib", sentryDepPath),
            ("libhostfxr_bridge.dylib", hostfxrBridgePath)
        ]

        var missing: [String] = []
        var nonArm64: [String] = []

        for (label, path) in items {
            guard let path, FileManager.default.fileExists(atPath: path) else {
                missing.append(label)
                continue
            }
            let archs = Self.detectArchitectures(of: URL(fileURLWithPath: path))
            if !archs.contains("arm64") {
                nonArm64.append(label)
            }
        }

        if !missing.isEmpty {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "缺少原生桥接库：\(missing.joined(separator: ", "))。",
                path: hostfxrBridgePath ?? sentryStubPath
            )
        }

        if !nonArm64.isEmpty {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "以下原生桥接库不含 arm64 架构：\(nonArm64.joined(separator: ", "))。",
                path: hostfxrBridgePath ?? sentryStubPath
            )
        }

        let stubsDir = (hostfxrBridgePath ?? sentryStubPath).map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        return BridgeComponentState(
            name: name,
            isReady: true,
            isOptional: false,
            detail: "已就绪 · hostfxr_bridge + Sentry 空壳 (arm64)",
            path: stubsDir
        )
    }

    private func inspectBridgeAssemblyComponent(bridgeDllPath: String?) -> BridgeComponentState {
        let name = "STS2MacBridge"
        guard let bridgeDllPath, FileManager.default.fileExists(atPath: bridgeDllPath) else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "未找到 STS2MacBridge.dll（启动钩子与 Harmony 平台兼容补丁）。",
                path: bridgeDllPath
            )
        }

        let size = FileHasher.fileSizeBytes(of: URL(fileURLWithPath: bridgeDllPath))
        guard size > 0 else {
            return BridgeComponentState(
                name: name,
                isReady: false,
                isOptional: false,
                detail: "STS2MacBridge.dll 文件为空，请重新构建。",
                path: bridgeDllPath
            )
        }

        return BridgeComponentState(
            name: name,
            isReady: true,
            isOptional: false,
            detail: "已就绪 · DOTNET_STARTUP_HOOKS + Harmony 兼容补丁（\(size) B）",
            path: bridgeDllPath
        )
    }

    // MARK: - Discovery Helpers

    private func resolvePrimaryRootDirectory(paths: LauncherPaths, customRootPath: String?) -> URL {
        if let customRootPath, !customRootPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: customRootPath, isDirectory: true).standardizedFileURL
        }
        return paths.bridgeRuntimeDirectory
    }

    private func resolveEffectiveRootURL(
        userRootURL: URL,
        bundledRootURL: URL?,
        userManifest: BridgeRuntimeManifestFile?,
        bundledManifest: BridgeRuntimeManifestFile?
    ) -> URL {
        if userManifest != nil || hasPopulatedBridgeRuntime(at: userRootURL) {
            return userRootURL
        }
        if let bundledRootURL, (bundledManifest != nil || hasPopulatedBridgeRuntime(at: bundledRootURL)) {
            return bundledRootURL
        }
        return userRootURL
    }

    private func isNonEmpty(_ value: String?) -> Bool {
        nonEmpty(value) != nil
    }

    private func existingResolvedPath(_ raw: String?, relativeTo rootURL: URL) -> String? {
        guard let resolved = resolvePath(raw, relativeTo: rootURL),
              FileManager.default.fileExists(atPath: resolved) else {
            return nil
        }
        return resolved
    }

    private func hasPopulatedBridgeRuntime(at rootURL: URL) -> Bool {
        let fm = FileManager.default
        let manifest = rootURL.appendingPathComponent(GameConstants.bridgeManifestFileName)
        if fm.fileExists(atPath: manifest.path) {
            return true
        }
        let templateDir = rootURL.appendingPathComponent("godot-template", isDirectory: true)
        return fm.fileExists(atPath: templateDir.path)
    }

    private func loadManifest(at url: URL) -> BridgeRuntimeManifestFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BridgeRuntimeManifestFile.self, from: data)
    }

    private func resolvePath(_ raw: String?, relativeTo rootURL: URL) -> String? {
        guard let cleaned = nonEmpty(raw) else { return nil }
        if cleaned.hasPrefix("/") {
            return URL(fileURLWithPath: cleaned).standardizedFileURL.path
        }
        return rootURL.appendingPathComponent(cleaned).standardizedFileURL.path
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func existingPath(_ url: URL) -> String? {
        FileManager.default.fileExists(atPath: url.path) ? url.path : nil
    }

    private func discoverGodotTemplateApp(in rootURL: URL) -> String? {
        let fm = FileManager.default
        let templateDir = rootURL.appendingPathComponent("godot-template", isDirectory: true)
        let preferred = templateDir.appendingPathComponent("macos_template.app")
        if fm.fileExists(atPath: preferred.path) {
            return preferred.path
        }
        let items = (try? fm.contentsOfDirectory(
            at: templateDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return items.first(where: { $0.pathExtension.lowercased() == "app" })?.path
    }

    private func discoverGodotSharpDll(in rootURL: URL, dotnetRuntimeDirPath: String) -> String? {
        let candidates = [
            URL(fileURLWithPath: dotnetRuntimeDirPath).appendingPathComponent("GodotSharp.dll"),
            rootURL.appendingPathComponent("godot-template/GodotSharp.dll")
        ]
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })?.path
    }

    private func discoverSpineFramework(in rootURL: URL) -> String? {
        let spineDir = rootURL.appendingPathComponent("gdextensions/spine", isDirectory: true)
        let preferred = spineDir.appendingPathComponent("libspine_godot.macos.template_release.framework")
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred.path
        }
        return findFirstMatchingItem(in: spineDir) { url in
            let lower = url.lastPathComponent.lowercased()
            return lower.contains("spine") && (lower.hasSuffix(".framework") || lower.hasSuffix(".dylib"))
        }
    }

    private func discoverRealFmodFramework(in rootURL: URL) -> String? {
        let fmodDir = rootURL.appendingPathComponent("gdextensions/fmod", isDirectory: true)
        if let found = findFirstMatchingItem(in: fmodDir, predicate: { url in
            let lower = url.lastPathComponent.lowercased()
            return lower.contains("godotfmod") && lower.contains("release") && (lower.hasSuffix(".framework") || lower.hasSuffix(".dylib"))
        }) {
            return found
        }
        return findFirstMatchingItem(in: fmodDir) { url in
            let lower = url.lastPathComponent.lowercased()
            return lower.contains("godotfmod") && (lower.hasSuffix(".framework") || lower.hasSuffix(".dylib"))
        }
    }

    private func discoverFmodDylibs(in rootURL: URL) -> [String] {
        let fmodDir = rootURL.appendingPathComponent("gdextensions/fmod", isDirectory: true)
        let fm = FileManager.default
        guard fm.fileExists(atPath: fmodDir.path),
              let enumerator = fm.enumerator(
                at: fmodDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var results: [String] = []
        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            if name == "libfmod.dylib" || name == "libfmodstudio.dylib" {
                results.append(fileURL.path)
            }
        }
        return results.sorted()
    }

    private func findFirstMatchingItem(in directory: URL, predicate: (URL) -> Bool) -> String? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path),
              let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        for case let itemURL as URL in enumerator {
            if predicate(itemURL) {
                return itemURL.path
            }
        }
        return nil
    }

    private func inferFmodMode(
        manifestMode: String?,
        fmodFrameworkPath: String?,
        fmodDylibPaths: [String]
    ) -> String {
        if let manifestMode {
            return manifestMode
        }
        let fm = FileManager.default
        let hasDylibs = fmodDylibPaths.contains { fm.fileExists(atPath: $0) }
        if let fw = fmodFrameworkPath, fm.fileExists(atPath: fw) {
            if fw.lowercased().contains("stub") || !hasDylibs {
                return "stub"
            }
            return "full"
        }
        return "missing"
    }

    // MARK: - Shared Binary Inspection Helpers

    internal static func locateGodotReleaseExecutable(in appBundleURL: URL) -> URL? {
        let fm = FileManager.default
        let contentsDir = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSDir = contentsDir.appendingPathComponent("MacOS", isDirectory: true)

        let items = (try? fm.contentsOfDirectory(
            at: macOSDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let executables = items.filter { url in
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
            let ext = url.pathExtension.lowercased()
            return isRegular
                && ext != "dylib"
                && ext != "txt"
                && ext != "json"
                && fm.isExecutableFile(atPath: url.path)
        }.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })

        if let releaseUniversal = executables.first(where: {
            let lower = $0.lastPathComponent.lowercased()
            return lower.contains("release") && lower.contains("universal")
        }) {
            return releaseUniversal
        }

        if let releaseBinary = executables.first(where: {
            $0.lastPathComponent.lowercased().contains("release")
        }) {
            return releaseBinary
        }

        let infoPlistURL = contentsDir.appendingPathComponent("Info.plist")
        if let plistData = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
           let execName = plist["CFBundleExecutable"] as? String {
            let candidate = macOSDir.appendingPathComponent(execName)
            if fm.fileExists(atPath: candidate.path), fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        if let nonDebug = executables.first(where: { !$0.lastPathComponent.lowercased().contains("debug") }) {
            return nonDebug
        }

        return executables.first
    }

    internal static func locateMachOBinary(in itemURL: URL) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: itemURL.path, isDirectory: &isDir) else {
            return nil
        }
        if !isDir.boolValue {
            return itemURL
        }

        // Standard .framework layout: Foo.framework/Foo, Versions/Current/Foo, or Info.plist CFBundleExecutable
        let baseName = itemURL.deletingPathExtension().lastPathComponent
        let directCandidates = [
            itemURL.appendingPathComponent(baseName),
            itemURL.appendingPathComponent("Versions/Current/\(baseName)"),
            itemURL.appendingPathComponent("Versions/A/\(baseName)")
        ]
        for candidate in directCandidates where fm.fileExists(atPath: candidate.path) {
            var subDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &subDir), !subDir.boolValue {
                return candidate
            }
        }

        let plistCandidates = [
            itemURL.appendingPathComponent("Resources/Info.plist"),
            itemURL.appendingPathComponent("Info.plist"),
            itemURL.appendingPathComponent("Versions/Current/Resources/Info.plist")
        ]
        for plistURL in plistCandidates {
            if let data = try? Data(contentsOf: plistURL),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
               let execName = plist["CFBundleExecutable"] as? String {
                let candidate = itemURL.appendingPathComponent(execName)
                if fm.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
        }

        if let enumerator = fm.enumerator(
            at: itemURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let isRegular = (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false
                let ext = fileURL.pathExtension.lowercased()
                if isRegular, ext != "plist", ext != "json", ext != "txt", !detectArchitectures(of: fileURL).isEmpty {
                    return fileURL
                }
            }
        }

        return nil
    }

    /// Parses Mach-O single-arch and Fat/Universal headers directly in Swift so end-user Macs
    /// without Xcode Command Line Tools never trigger a `/usr/bin/lipo` install prompt.
    internal static func detectArchitectures(of binaryURL: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: binaryURL) else {
            return []
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else {
            return []
        }

        let magicLE = readUInt32LE(header, offset: 0)
        let magicBE = readUInt32BE(header, offset: 0)

        // Single-arch Mach-O (64-bit / 32-bit little-endian or big-endian)
        if magicLE == 0xFEED_FACF || magicLE == 0xFEED_FACE {
            return architectureName(cpuType: readUInt32LE(header, offset: 4)).map { [$0] } ?? []
        }
        if magicBE == 0xFEED_FACF || magicBE == 0xFEED_FACE {
            return architectureName(cpuType: readUInt32BE(header, offset: 4)).map { [$0] } ?? []
        }

        // Universal / Fat Mach-O (32-bit header: 0xCAFEBABE, 64-bit header: 0xCAFEBABF, always big-endian)
        if magicBE == 0xCAFE_BABE || magicBE == 0xCAFE_BABF {
            let entryStride = (magicBE == 0xCAFE_BABF) ? 32 : 20
            let archCount = Int(readUInt32BE(header, offset: 4))
            guard archCount > 0, archCount <= 32 else { return [] }
            var result: [String] = []
            for index in 0..<archCount {
                let entryOffset = 8 + index * entryStride
                guard entryOffset + 4 <= header.count else { break }
                if let name = architectureName(cpuType: readUInt32BE(header, offset: entryOffset)),
                   !result.contains(name) {
                    result.append(name)
                }
            }
            return result
        }

        return []
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1]) << 8
        let b2 = UInt32(data[data.startIndex + offset + 2]) << 16
        let b3 = UInt32(data[data.startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func readUInt32BE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset]) << 24
        let b1 = UInt32(data[data.startIndex + offset + 1]) << 16
        let b2 = UInt32(data[data.startIndex + offset + 2]) << 8
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | b1 | b2 | b3
    }

    private static func architectureName(cpuType: UInt32) -> String? {
        switch cpuType {
        case 0x0100_000C: return "arm64"
        case 0x0100_0007: return "x86_64"
        case 0x0000_0007: return "i386"
        case 0x0000_000C: return "arm"
        default: return nil
        }
    }
}
