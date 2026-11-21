import Foundation
import STS2LauncherCore

@main
struct STS2PoCCLI {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(0)
        }

        let paths = LauncherPaths()
        let winInspector = WindowsPayloadInspector()
        let bridgeInspector = BridgeRuntimeInspector()
        let stager = RuntimeStager()
        let modRepo = ModRepository(paths: paths)
        let saveManager = SaveManager(paths: paths)
        let diagnostics = CrashDiagnostics()

        do {
            switch command {
            case "check-bridge":
                let options = parseFlagArguments(Array(args.dropFirst()))
                let customRoot: String? = options["--bridge"]
                    ?? (args.count >= 2 && !args[1].hasPrefix("--") ? args[1] : nil)
                let info = bridgeInspector.inspect(paths: paths, customRootPath: customRoot)
                printBridgeRuntime(info)
                if !info.isLaunchReady {
                    exit(1)
                }

            case "fetch-extensions":
                let options = parseFlagArguments(Array(args.dropFirst()))
                let customRoot: String? = options["--bridge"]
                    ?? (args.count >= 2 && !args[1].hasPrefix("--") ? args[1] : nil)
                let downloader = BridgeExtensionDownloader()
                let summary = try await downloader.downloadAndInstall(
                    into: paths,
                    customRootPath: customRoot
                ) { progress in
                    let pct = Int(progress.fractionCompleted * 100)
                    print("[\(pct)%] [\(progress.stage)] \(progress.detail)")
                }
                print("\n官方上游扩展安装完成：")
                print("  目标目录：\(summary.destinationRootPath)")
                print("  Spine：\(summary.spineFrameworkPath)")
                print("  FMOD：\(summary.fmodFrameworkPath)")
                for dylib in summary.fmodDylibPaths {
                    print("  FMOD 库：\(dylib)")
                }
                print("")
                let info = bridgeInspector.inspect(paths: paths, customRootPath: customRoot)
                printBridgeRuntime(info)

            case "inspect-win":
                guard args.count >= 2 else {
                    fail("用法：sts2-poc inspect-win <windows-dir-or-zip>")
                }
                let sourceURL = URL(fileURLWithPath: args[1]).standardizedFileURL
                let info = try inspectOrExtractWindowsSource(sourceURL, inspector: winInspector, paths: paths)
                printWindowsPayload(info)

            case "stage":
                let options = parseFlagArguments(Array(args.dropFirst()))
                guard let winPath = options["--win"] else {
                    fail("用法：sts2-poc stage --win <windows-dir-or-zip> [--bridge <dir>] [--steam-api <libsteam_api.dylib>] [--driver auto|metal|vulkan|opengl3] [--no-mods]")
                }
                let driver = parseRenderingDriver(options["--driver"])
                let winInfo = try inspectOrExtractWindowsSource(
                    URL(fileURLWithPath: winPath).standardizedFileURL,
                    inspector: winInspector,
                    paths: paths
                )
                let bridgeInfo = bridgeInspector.inspect(paths: paths, customRootPath: options["--bridge"])
                let mods = (try? modRepo.loadMods()) ?? []

                var config = LaunchConfiguration()
                config.bridgeRuntimeCustomPath = options["--bridge"]
                config.customSteamApiDylibPath = options["--steam-api"]
                config.renderingDriver = driver
                config.enableMods = !args.contains("--no-mods")

                let report = try stager.stage(
                    windowsPayload: winInfo,
                    bridgeRuntime: bridgeInfo,
                    enabledMods: mods,
                    configuration: config,
                    paths: paths
                )
                printStagingReport(report, configuration: config)

            case "launch":
                let options = parseFlagArguments(Array(args.dropFirst()))
                guard let winPath = options["--win"] else {
                    fail("用法：sts2-poc launch --win <windows-dir-or-zip> [--bridge <dir>] [--steam-api <libsteam_api.dylib>] [--driver auto|metal|vulkan|opengl3] [--no-mods] [--no-hud] [--fastmp] [--verbose]")
                }
                let driver = parseRenderingDriver(options["--driver"])
                let winInfo = try inspectOrExtractWindowsSource(
                    URL(fileURLWithPath: winPath).standardizedFileURL,
                    inspector: winInspector,
                    paths: paths
                )
                let bridgeInfo = bridgeInspector.inspect(paths: paths, customRootPath: options["--bridge"])
                let mods = (try? modRepo.loadMods()) ?? []

                var config = LaunchConfiguration()
                config.bridgeRuntimeCustomPath = options["--bridge"]
                config.customSteamApiDylibPath = options["--steam-api"]
                config.renderingDriver = driver
                config.enableMods = !args.contains("--no-mods")
                config.enableInGameOverlay = !args.contains("--no-hud")
                config.enableFastMultiplayer = args.contains("--fastmp")
                config.enableVerboseLogging = args.contains("--verbose")

                let report = try stager.stage(
                    windowsPayload: winInfo,
                    bridgeRuntime: bridgeInfo,
                    enabledMods: mods,
                    configuration: config,
                    paths: paths
                )
                printStagingReport(report, configuration: config)
                print("\n--- 开始运行游戏进程 ---")

                let collector = LogCollector()
                let runner = GameProcessRunner()
                let result = try await runner.launch(
                    stagedReport: report,
                    configuration: config,
                    paths: paths
                ) { entry in
                    collector.append(entry)
                    print("[\(entry.source.rawValue)][\(entry.level.label)] \(entry.message)")
                }

                print("\n--- 会话结束 (exit=\(result.exitCode)) ---")
                print("日志文件：\(result.logFilePath)")
                let findings = diagnostics.analyze(exitCode: result.exitCode, entries: collector.snapshot())
                if !findings.isEmpty {
                    print("\n--- 自动诊断 ---")
                    for item in findings {
                        print("[\(item.severity.rawValue.uppercased())][\(item.category)] \(item.title)")
                        print("  证据：\(item.evidence)")
                        print("  建议：\(item.recoveryAction)")
                    }
                }

            case "mods":
                let mods = try modRepo.loadMods()
                let issues = modRepo.validate(mods: mods)
                print("Mod 库目录：\(paths.modsLibraryDirectory.path)")
                print("共发现 \(mods.count) 个 Mod：")
                for mod in mods {
                    let state = mod.isEnabled ? "启用" : "禁用"
                    print("  #\(mod.loadOrder + 1) [\(state)] \(mod.displayName) (\(mod.id) @ \(mod.versionText)) dll=\(mod.dllFiles.count) pck=\(mod.pckFiles.count)")
                }
                if !issues.isEmpty {
                    print("\n校验告警（\(issues.count)）：")
                    for issue in issues {
                        print("  [\(issue.severity.rawValue.uppercased())] \(issue.modID): \(issue.message) -> \(issue.recoveryHint)")
                    }
                }

            case "saves":
                let slots = saveManager.discoverAccountSlots()
                print("存档根目录：\(paths.gameUserDataDirectory.path)")
                if slots.isEmpty {
                    print("未发现任何账号存档目录。")
                } else {
                    for slot in slots {
                        print("账号 \(slot.id):")
                        print("  普通存档：exists=\(slot.vanilla.exists) files=\(slot.vanilla.fileCount) slots=\(slot.vanilla.profileSlotsPresent.joined(separator: ","))")
                        print("  MOD存档： exists=\(slot.modded.exists) files=\(slot.modded.fileCount) slots=\(slot.modded.profileSlotsPresent.joined(separator: ","))")
                    }
                }
                let snapshots = saveManager.listSnapshots()
                print("已有快照备份：\(snapshots.count) 份")

            case "help", "-h", "--help":
                printUsage()

            default:
                fail("未知命令：\(command)。运行 `sts2-poc help` 查看用法。")
            }
        } catch let launcherError as LauncherError {
            fputs("\(launcherError.formattedMessage)\n", stderr)
            exit(1)
        } catch {
            fputs("执行失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func inspectOrExtractWindowsSource(
        _ sourceURL: URL,
        inspector: WindowsPayloadInspector,
        paths: LauncherPaths
    ) throws -> WindowsPayloadInfo {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue {
            return try inspector.inspectDirectory(at: sourceURL)
        }
        return try inspector.importSource(at: sourceURL, into: paths, copyDirectoryIntoStore: false)
    }

    private static func parseFlagArguments(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var idx = 0
        while idx < args.count {
            let key = args[idx]
            if key.hasPrefix("--"), idx + 1 < args.count, !args[idx + 1].hasPrefix("--") {
                result[key] = args[idx + 1]
                idx += 2
            } else {
                idx += 1
            }
        }
        return result
    }

    private static func parseRenderingDriver(_ raw: String?) -> RenderingDriver {
        guard let raw else { return .auto }
        guard let driver = RenderingDriver(rawValue: raw.lowercased()) else {
            fail("不支持的渲染驱动：\(raw)。可选值：auto, metal, vulkan, opengl3")
        }
        return driver
    }

    private static func printBridgeRuntime(_ info: BridgeRuntimeInfo) {
        let readyCount = info.components.filter(\.isReady).count
        print("自建 macOS BridgeRuntime 检测结果（\(info.isLaunchReady ? "已就绪" : "未就绪")，\(readyCount)/\(info.components.count)）：")
        print("  根目录：\(info.rootPath)")
        print("  版本：Godot \(info.godotVersion) | .NET \(info.dotnetVersion) | Spine \(info.spineVersion) | FMOD \(info.fmodVersion) (\(info.fmodMode))")
        for component in info.components {
            let badge: String
            if component.isReady {
                badge = "OK"
            } else if component.isOptional {
                badge = "OPT"
            } else {
                badge = "MISSING"
            }
            print("  [\(badge)] \(component.name)：\(component.detail)")
            if let path = component.path {
                print("        路径：\(path)")
            }
        }
    }

    private static func printWindowsPayload(_ info: WindowsPayloadInfo) {
        let mb = Double(info.pckSizeBytes) / (1024 * 1024)
        print("Windows 游戏包检验通过：")
        print("  名称：\(info.displayName)")
        if let ver = info.releaseVersion {
            print("  版本：\(ver)")
        }
        print("  根目录：\(info.rootPath)")
        print("  主包：\(info.pckFileName) (\(String(format: "%.1f", mb)) MB)")
        print("  sts2.dll SHA-256：\(info.sts2DllSha256)")
        print("  可补齐纯托管 DLL（\(info.supplementaryManagedDlls.count)）：\(info.supplementaryManagedDlls.joined(separator: ", "))")
    }

    private static func printStagingReport(_ report: StagingReport, configuration: LaunchConfiguration) {
        print("BridgeRuntime 合成完成：")
        print("  Staged App：\(report.stagedAppPath)")
        print("  主可执行文件：\(report.stagedExecutablePath)")
        print("  游戏资源包：\(report.targetPckPath)")
        print("  覆写托管 DLL（\(report.copiedManagedDlls.count)）：\(report.copiedManagedDlls.joined(separator: ", "))")
        print("  保留 macOS 原生 .dylib：\(report.preservedMacNativeCount) 个")
        print("  STS2MacBridge 注入：\(report.bridgeDllInjected ? "已注入" : "未注入")")
        print("  Steamworks (libsteam_api.dylib)：\(report.steamApiLinked ? "已链接" : "未配置")")
        print("  FMOD 模式：\(report.fmodMode)")
        print("  渲染驱动：\(configuration.renderingDriver.displayName)")
        print("  部署 Mod：\(report.deployedModIDs.isEmpty ? "无" : report.deployedModIDs.joined(separator: ", "))")
        print("  steam_appid.txt：\(report.wroteSteamAppID ? "已写入" : "未写入")")
        print("  ad-hoc 重签：\(report.didAdHocSign ? "已完成" : "已跳过")")
        for warning in report.warnings {
            print("  [警告] \(warning)")
        }
    }

    private static func printUsage() {
        print("""
        sts2-poc — 《杀戮尖塔2》macOS 纯自建 BridgeRuntime 诊断与启动工具

        用法：
          sts2-poc check-bridge [custom-bridge-dir]
          sts2-poc fetch-extensions [--bridge <dir>]
          sts2-poc inspect-win <windows-dir-or-zip>
          sts2-poc stage --win <windows-dir-or-zip> [--bridge <dir>] [--steam-api <libsteam_api.dylib>] [--driver auto|metal|vulkan|opengl3] [--no-mods]
          sts2-poc launch --win <windows-dir-or-zip> [--bridge <dir>] [--steam-api <libsteam_api.dylib>] [--driver auto|metal|vulkan|opengl3] [--no-mods] [--no-hud] [--fastmp] [--verbose]
          sts2-poc mods
          sts2-poc saves
        """)
    }

    private static func fail(_ message: String) -> Never {
        fputs("错误：\(message)\n", stderr)
        exit(2)
    }
}

private final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [LogEntry] = []

    func append(_ entry: LogEntry) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    func snapshot() -> [LogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
