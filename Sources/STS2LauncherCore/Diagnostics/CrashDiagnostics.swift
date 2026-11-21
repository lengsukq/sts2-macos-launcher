import Foundation

public struct CrashDiagnostics: Sendable {
    private static let errorIndicators: [String] = [
        "error",
        "exception",
        "failed",
        "failure",
        "unable to",
        "could not",
        "cannot",
        "can't",
        "not found",
        "missing",
        "invalid",
        "symbol not found",
        "dlopen",
        "crash",
        "abort",
        "segfault",
        "fatal",
        "incompatible"
    ]

    private static let benignLinePrefixes: [String] = [
        "orphan stringname:",
        "loading resource:",
        "found hostfxr:",
        "loaded assembly:"
    ]

    public init() {}

    public func analyze(exitCode: Int32?, entries: [LogEntry]) -> [DiagnosticFinding] {
        var findings: [DiagnosticFinding] = []
        let processEntries = entries.filter { $0.source != .launcher }

        if let code = exitCode {
            if code == 137 || code == 9 {
                findings.append(DiagnosticFinding(
                    id: "sigkill-codesign",
                    severity: .error,
                    category: "签名 / 系统拦截",
                    title: "进程被系统强杀 (SIGKILL / 退出码 \(code))",
                    evidence: "退出码 \(code)，在 Apple Silicon macOS 上最常见于 Staged .app 及其内嵌动态库代码签名失效。",
                    recoveryAction: "请重新执行 Staging 合成（确保未跳过 ad-hoc codesign），或在终端检查 `codesign --verify --deep --strict <staged.app>`。"
                ))
            } else if code != 0 {
                findings.append(DiagnosticFinding(
                    id: "nonzero-exit",
                    severity: .warning,
                    category: "进程退出",
                    title: "游戏异常退出（退出码 \(code)）",
                    evidence: "游戏进程以非零状态码 \(code) 结束。",
                    recoveryAction: "结合下方错误日志与诊断条目逐项排查；若刚启用新 Mod，可尝试先关闭 Mod 复测。"
                ))
            }
        }

        if let hit = firstExplicitErrorLine(in: processEntries, patterns: [
            "Code Signature Invalid",
            "EXC_BAD_ACCESS (SIGKILL",
            "Library Validation"
        ]) ?? firstComponentErrorLine(in: processEntries, patterns: ["quarantine"]) {
            findings.append(DiagnosticFinding(
                id: "codesign-log",
                severity: .error,
                category: "签名 / Quarantine",
                title: "检测到 macOS 签名或隔离校验失败",
                evidence: hit,
                recoveryAction: "清除 Staged .app 的 com.apple.quarantine 属性并执行 `codesign --force --deep --sign -` 重签。"
            ))
        }

        if let hit = firstExplicitErrorLine(in: processEntries, patterns: [
            "failed to load startup hook"
        ]) ?? firstComponentErrorLine(in: processEntries, patterns: [
            "DOTNET_STARTUP_HOOKS",
            "StartupHook",
            "STS2MacBridge"
        ]) {
            findings.append(DiagnosticFinding(
                id: "startup-hook-error",
                severity: .error,
                category: "桥接注入 (StartupHook)",
                title: "STS2MacBridge 启动钩子加载或执行异常",
                evidence: hit,
                recoveryAction: "请确认 BridgeRuntime 中的 STS2MacBridge.dll 与 libhostfxr_bridge.dylib 已编译且与当前 Windows sts2.dll 匹配，必要时重新运行 scripts/setup-bridge-runtime.sh。"
            ))
        }

        if let hit = firstComponentErrorLine(in: processEntries, patterns: [
            "deps.json",
            "sts2.deps.json",
            "runtimeconfig.json",
            "hostpolicy",
            "hostfxr",
            "runtimepack.Microsoft.NETCore.App.Runtime.win"
        ]) {
            findings.append(DiagnosticFinding(
                id: "deps-json-error",
                severity: .error,
                category: ".NET 宿主配置 (deps.json)",
                title: "CoreCLR deps.json 或 runtimeconfig.json 解析失败",
                evidence: hit,
                recoveryAction: "请重新执行 Staging 合成，以重新生成已清理 win-x64 原生段的 macOS osx-arm64 版 sts2.deps.json 与 sts2.runtimeconfig.json。"
            ))
        }

        if let hit = firstComponentErrorLine(in: processEntries, patterns: [
            "Vortice",
            "DXGI",
            "SharpGen",
            "dxgi.dll",
            "d3d11",
            "OsDebugInfo"
        ]) {
            findings.append(DiagnosticFinding(
                id: "vortice-dxgi-error",
                severity: .error,
                category: "Windows 图形 API 拦截 (Vortice / DXGI)",
                title: "检测到 Windows Vortice / DXGI 调用异常",
                evidence: hit,
                recoveryAction: "请确认 STS2MacBridge.dll 已通过 DOTNET_STARTUP_HOOKS 正常注入以拦截 OsDebugInfo.LogSystemInfo，并在设置中尝试切换渲染驱动（Metal / Vulkan / OpenGL3）。"
            ))
        }

        if let hit = firstExplicitErrorLine(in: processEntries, patterns: [
            "assembly architecture is not compatible",
            "BadImageFormatException",
            "MissingMethodException",
            "TypeLoadException",
            "Could not load file or assembly",
            "FileNotFoundException"
        ]) {
            findings.append(DiagnosticFinding(
                id: "dotnet-mismatch",
                severity: .error,
                category: ".NET / 程序集兼容",
                title: ".NET 托管程序集架构或 API 不兼容",
                evidence: hit,
                recoveryAction: "请重新执行 Staging 合成（确保 PE32+ AMD64 ILONLY -> ARM64 修补与 .NET 9 osx-arm64 运行时完整）；若报错指向某个 Mod DLL，请先禁用该 Mod 或更新其版本。"
            ))
        }

        var matchedSpecificMiddleware = false

        if let hit = firstComponentErrorLine(in: processEntries, patterns: [
            "libspine_godot",
            "spine_godot",
            "SpineSprite",
            "SpineSkeleton"
        ]) {
            matchedSpecificMiddleware = true
            findings.append(DiagnosticFinding(
                id: "spine-extension-error",
                severity: .error,
                category: "Spine GDExtension",
                title: "检测到 Spine 4.2 原生扩展加载异常",
                evidence: hit,
                recoveryAction: "请确认 BridgeRuntime 已包含 arm64 架构的 libspine_godot.macos.template_release.framework 并已部署至 Staged .app/Contents/Frameworks/。"
            ))
        }

        if let hit = firstComponentErrorLine(in: processEntries, patterns: [
            "libGodotFmod",
            "libfmod",
            "libfmodstudio",
            "fmod_library_init",
            "FMOD"
        ]) {
            matchedSpecificMiddleware = true
            findings.append(DiagnosticFinding(
                id: "fmod-extension-error",
                severity: .error,
                category: "FMOD GDExtension",
                title: "检测到 FMOD 音频原生扩展异常",
                evidence: hit,
                recoveryAction: "请核查 BridgeRuntime 的 FMOD 组件（完整模式需同时具备 libGodotFmod.framework、libfmod.dylib 与 libfmodstudio.dylib；或使用静音兜底 stub 模式）。"
            ))
        }

        if !matchedSpecificMiddleware, let hit = firstComponentErrorLine(in: processEntries, patterns: [
            "GDExtension",
            "libsentry",
            "sentry-godot"
        ]) {
            findings.append(DiagnosticFinding(
                id: "middleware-error",
                severity: .error,
                category: "引擎原生扩展 (GDExtension)",
                title: "检测到 Godot 原生扩展加载异常",
                evidence: hit,
                recoveryAction: "请运行 `sts2-poc check-bridge` 核对 6 大桥接组件是否全部为 arm64 且路径有效。"
            ))
        }

        if let hit = firstComponentErrorLine(in: processEntries, patterns: [
            "SteamInitializer",
            "SteamAPI_Init",
            "SteamAPI.Init",
            "SteamClient",
            "libsteam_api",
            "steam_api64",
            "steam_appid",
            "Failed to initialize Steam"
        ]) {
            findings.append(DiagnosticFinding(
                id: "steam-init",
                severity: .warning,
                category: "Steam 初始化",
                title: "Steamworks 初始化相关日志/错误",
                evidence: hit,
                recoveryAction: "请确认本地 Steam 客户端已启动、已写入 steam_appid.txt (2868840)，并在设置中配置了有效的官方 macOS libsteam_api.dylib 路径。"
            ))
        }

        if let hit = firstExplicitErrorLine(in: processEntries, patterns: [
            "HarmonyException"
        ]) ?? firstComponentErrorLine(in: processEntries, patterns: [
            "ModInitializer",
            "MegaCrit.Sts2.Core.Modding.ModManager",
            "ModManager.",
            "BaseLib"
        ]) {
            findings.append(DiagnosticFinding(
                id: "mod-loader-error",
                severity: .warning,
                category: "Mod 加载",
                title: "检测到 Mod 初始化或 Harmony 补丁相关日志",
                evidence: hit,
                recoveryAction: "请前往“Mod 管理”检查前置依赖（如 BaseLib）是否已启用并排在最前面，必要时二分禁用定位异常 Mod。"
            ))
        }

        if findings.isEmpty, exitCode == 0 {
            findings.append(DiagnosticFinding(
                id: "clean-exit",
                severity: .warning,
                category: "正常结束",
                title: "游戏进程正常退出，未检测到已知崩溃特征",
                evidence: "退出码 0，共采集 \(entries.count) 条日志。",
                recoveryAction: "无需额外处理。"
            ))
        }

        return findings
    }

    public static func inferLogLevel(from line: String, source: LogStreamSource) -> LogLevel {
        let lower = line.lowercased()
        if lower.contains("error") || lower.contains("exception") || lower.contains("fatal") || lower.contains("crash") {
            return .error
        }
        if lower.contains("warn") {
            return .warning
        }
        if source == .stderr {
            return .warning
        }
        if lower.contains("debug") || lower.contains("trace") {
            return .debug
        }
        return .info
    }

    /// Matches lines that already contain unambiguous error signatures.
    private func firstExplicitErrorLine(in entries: [LogEntry], patterns: [String]) -> String? {
        for entry in entries {
            let line = entry.message
            for pattern in patterns where line.localizedCaseInsensitiveContains(pattern) {
                return String(line.prefix(240))
            }
        }
        return nil
    }

    /// Matches component-specific lines only when accompanied by an error level or explicit error indicator,
    /// avoiding false positives on normal verbose startup/resource/shutdown messages.
    private func firstComponentErrorLine(in entries: [LogEntry], patterns: [String]) -> String? {
        for entry in entries {
            let line = entry.message
            let trimmedLower = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if Self.benignLinePrefixes.contains(where: { trimmedLower.hasPrefix($0) }) {
                continue
            }

            let matchesComponent = patterns.contains { line.localizedCaseInsensitiveContains($0) }
            guard matchesComponent else { continue }

            let hasErrorContext = entry.level == .error
                || Self.errorIndicators.contains { trimmedLower.contains($0) }
            if hasErrorContext {
                return String(line.prefix(240))
            }
        }
        return nil
    }
}
