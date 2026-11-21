import AppKit
import STS2LauncherCore
import SwiftUI
import UniformTypeIdentifiers

struct DashboardView: View {
    @Bindable var state: AppState
    @State private var isDropTargeted: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader
                if let banner = state.statusBanner {
                    statusBannerView(banner)
                }
                if state.needsUpstreamExtensionsOnly {
                    extensionOnboardingCard
                }
                if state.selectedPayload == nil {
                    quickImportOnboardingCard
                }
                readinessGrid
                if let report = state.lastStagingReport {
                    lastStagingCard(report)
                }
                if !state.diagnosticFindings.isEmpty {
                    diagnosticsPreviewCard
                }
            }
            .padding(24)
        }
        .navigationTitle("概览与启动")
    }

    private var extensionOnboardingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("开源核心已内置就绪 — 一键自动下载官方 Spine 4.2 & FMOD 2.03.06 扩展")
                            .font(.headline)
                        Text("首次使用仅需联网直接从官方上游源拉取骨骼动画与音频扩展至本地用户目录，无需 Homebrew、Xcode 或任何开发工具。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        state.downloadUpstreamExtensions()
                    } label: {
                        if state.isDownloadingExtensions {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("下载中…")
                            }
                        } else {
                            Label("一键下载扩展", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isDownloadingExtensions || state.isBuildingBridgeRuntime || state.isStaging || state.isGameRunning)
                }

                if state.isDownloadingExtensions {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: state.extensionDownloadFraction, total: 1.0)
                        if let detail = state.extensionDownloadStatusText {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(10)
        }
    }

    private var quickImportOnboardingCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.bridgeRuntime?.isLaunchReady == true
                             ? "桥接运行时已就绪 — 拖入 Windows 游戏包即可开玩"
                             : "自主导入本地 Windows 游戏包（支持目录或 .zip）")
                            .font(.headline)
                        Text("将你本机合法持有的 Windows 版《杀戮尖塔2》文件夹或 .zip 压缩包（支持来自 Steam 或其他合法渠道）直接拖到此卡片，或点击右侧按钮选择导入。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择目录 / ZIP…") {
                        chooseWindowsPayloadPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isImporting)
                }
                Text("免责声明：本启动器仅为跨平台兼容运行工具，不提供任何游戏文件，亦不内置任何绕过 DRM 或正版校验功能；请自行确保导入游戏文件的合法授权与合规来源，相关责任由用户自行承担。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleFileDrop(providers)
        }
    }

    private func chooseWindowsPayloadPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Windows 版《杀戮尖塔2》目录或 .zip 压缩包"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.importWindowsPayload(from: url, copyIntoStore: false)
        }
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in
                state.importWindowsPayload(from: url, copyIntoStore: false)
            }
        }
        return true
    }

    private var heroHeader: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("杀戮尖塔2 · 自建 macOS 桥接运行时（零官方 Mac 版依赖）")
                        .font(.title2.weight(.semibold))
                    Text("本地组合 Godot 4.5.1 Mono + .NET 9 osx-arm64 + Spine + FMOD + STS2MacBridge 挂载 Windows 游戏资产，内置 Mod 管理、存档隔离与实时诊断。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 14) {
                            Toggle("启用 Mod", isOn: Binding(
                                get: { state.configuration.enableMods },
                                set: {
                                    state.configuration.enableMods = $0
                                    state.persistConfiguration()
                                }
                            ))
                            .toggleStyle(.checkbox)

                            Toggle("局域网联机模式 (--fastmp)", isOn: Binding(
                                get: { state.configuration.enableFastMultiplayer },
                                set: {
                                    state.configuration.enableFastMultiplayer = $0
                                    state.persistConfiguration()
                                }
                            ))
                            .toggleStyle(.checkbox)

                            Toggle("游戏内悬浮窗 (F9)", isOn: Binding(
                                get: { state.configuration.enableInGameOverlay },
                                set: {
                                    state.configuration.enableInGameOverlay = $0
                                    state.persistConfiguration()
                                }
                            ))
                            .toggleStyle(.checkbox)
                        }
                        Text("渲染驱动：\(state.configuration.renderingDriver.displayName) · 仅提供本地兼容运行环境，游戏文件需用户自主导入")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if state.isGameRunning {
                        Button(role: .destructive) {
                            state.stopGame()
                        } label: {
                            Label("停止游戏", systemImage: "stop.fill")
                                .frame(minWidth: 120)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            state.launchGame()
                        } label: {
                            Label(state.isStaging ? "合成沙盒中…" : "启动游戏", systemImage: "play.fill")
                                .frame(minWidth: 120)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .disabled(!state.canLaunchGame)
                    }
                    Text(launchStatusCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private var launchStatusCaption: String {
        if state.isGameRunning { return "游戏进程运行中，可前往“日志与诊断”查看实时输出" }
        if state.isStaging { return "正在合成隔离运行沙盒并执行 ad-hoc 重签…" }
        if state.isDownloadingExtensions { return "正在从官方上游源自动下载 Spine & FMOD 扩展…" }
        if state.isBuildingBridgeRuntime { return "正在构建自建 macOS 桥接运行时…" }
        if state.needsUpstreamExtensionsOnly { return "待完成：一键下载官方 Spine & FMOD 扩展（免配置）" }
        if state.selectedPayload == nil { return "待完成：自主导入本地 Windows 游戏包" }
        if state.bridgeRuntime?.isLaunchReady != true { return "待完成：搭建或检测自建 macOS 桥接运行时" }
        return "就绪 · 零官方 Mac 版依赖，启动时不会修改任何原始游戏文件"
    }

    private func statusBannerView(_ text: String) -> some View {
        HStack(spacing: 10) {
            if state.isImporting || state.isStaging || state.isBuildingBridgeRuntime || state.isDownloadingExtensions {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if state.isBuildingBridgeRuntime {
                Button("查看日志") {
                    state.selectedSection = .logs
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            Button("隐藏") {
                state.statusBanner = nil
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var readinessGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
            statusCard(
                title: "Windows 游戏包",
                isReady: state.selectedPayload != nil,
                summary: state.selectedPayload.map { payload in
                    let ver = payload.releaseVersion.map { " · \($0)" } ?? ""
                    return "\(payload.displayName)\(ver)\nsts2.dll: \(payload.shortHash)"
                } ?? "尚未导入 Windows 版目录或 .zip",
                actionTitle: "配置游戏包"
            ) {
                state.selectedSection = .payloads
            }

            statusCard(
                title: "自建 macOS 桥接运行时（零官方 Mac 版依赖）",
                isReady: state.bridgeRuntime?.isLaunchReady == true,
                summary: bridgeRuntimeSummary,
                actionTitle: state.bridgeRuntime?.isLaunchReady == true
                    ? "管理运行时"
                    : (state.needsUpstreamExtensionsOnly ? "下载扩展" : "去搭建")
            ) {
                state.selectedSection = .payloads
            }

            statusCard(
                title: "Mod 状态",
                isReady: state.blockingModErrors.isEmpty,
                summary: state.configuration.enableMods
                    ? "已启用 \(state.enabledModCount) / \(state.mods.count) 个 Mod"
                        + (state.blockingModErrors.isEmpty ? "" : "\n存在 \(state.blockingModErrors.count) 项依赖/结构错误")
                    : "已临时关闭 Mod（纯净模式）",
                actionTitle: "管理 Mod"
            ) {
                state.selectedSection = .mods
            }

            statusCard(
                title: "存档与快照",
                isReady: !state.saveSlots.isEmpty,
                summary: "已发现 \(state.saveSlots.count) 个账号槽位\n已保留 \(state.saveSnapshots.count) 份安全快照",
                actionTitle: "查看存档"
            ) {
                state.selectedSection = .saves
            }
        }
    }

    private var bridgeRuntimeSummary: String {
        guard let runtime = state.bridgeRuntime else {
            return "尚未执行桥接运行时检测，请前往“游戏包与运行时”搭建或重新检测。"
        }
        if runtime.components.isEmpty {
            return "尚未检测到组件清单，请点击“去搭建”一键生成桥接运行时。"
        }
        let readyCount = runtime.components.filter(\.isReady).count
        let totalCount = runtime.components.count
        let fmodText = BridgeDisplayFormatter.fmodModeLabel(runtime.fmodMode)
        if runtime.isLaunchReady {
            return "\(readyCount)/\(totalCount) 组件就绪 · FMOD：\(fmodText)\nGodot \(runtime.godotVersion) · .NET \(runtime.dotnetVersion) · Spine \(runtime.spineVersion)"
        }
        let missingRequired = runtime.components
            .filter { !$0.isReady && !$0.isOptional }
            .map(\.name)
        let missingText = missingRequired.isEmpty
            ? "部分组件未就绪"
            : "缺失：\(missingRequired.joined(separator: "、"))"
        return "\(readyCount)/\(totalCount) 组件就绪 · FMOD：\(fmodText)\n\(missingText)"
    }

    private func statusCard(
        title: String,
        isReady: Bool,
        summary: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(isReady ? .green : .orange)
                    Text(title)
                        .font(.headline)
                    Spacer()
                }
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
                HStack {
                    Spacer()
                    Button(actionTitle, action: action)
                        .controlSize(.small)
                }
            }
            .padding(4)
        }
    }

    private func lastStagingCard(_ report: StagingReport) -> some View {
        GroupBox("最近一次桥接沙盒合成摘要") {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Staged 包路径", value: report.stagedAppPath)
                LabeledContent("覆写托管程序集", value: report.copiedManagedDlls.joined(separator: ", "))
                LabeledContent("保留 macOS 原生库", value: "\(report.preservedMacNativeCount) 个 .dylib")
                LabeledContent("STS2MacBridge 注入") {
                    Label(
                        report.bridgeDllInjected ? "已注入 (DOTNET_STARTUP_HOOKS)" : "未注入",
                        systemImage: report.bridgeDllInjected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(report.bridgeDllInjected ? .green : .orange)
                }
                LabeledContent("Steamworks 动态库") {
                    Label(
                        report.steamApiLinked ? "已链接 libsteam_api.dylib" : "未配置（需提供官方 macOS libsteam_api.dylib）",
                        systemImage: report.steamApiLinked ? "checkmark.circle.fill" : "info.circle"
                    )
                    .foregroundStyle(.secondary)
                }
                LabeledContent("FMOD 音频模式") {
                    Label(
                        BridgeDisplayFormatter.fmodModeLabel(report.fmodMode),
                        systemImage: BridgeDisplayFormatter.fmodModeSymbol(report.fmodMode)
                    )
                    .foregroundStyle(.secondary)
                }
                LabeledContent("已部署 Mod", value: report.deployedModIDs.isEmpty ? "无" : report.deployedModIDs.joined(separator: ", "))
                LabeledContent("ad-hoc 重签", value: report.didAdHocSign ? "已完成" : "未执行")
                if !report.warnings.isEmpty {
                    Divider()
                    ForEach(report.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .padding(6)
        }
    }

    private var diagnosticsPreviewCard: some View {
        GroupBox("最近会话诊断") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(state.diagnosticFindings.prefix(3)) { finding in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: finding.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(finding.severity == .error ? .red : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("[\(finding.category)] \(finding.title)")
                                .font(.callout.weight(.medium))
                            Text(finding.recoveryAction)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("打开完整日志与诊断") {
                        state.selectedSection = .logs
                    }
                    .controlSize(.small)
                }
            }
            .padding(6)
        }
    }
}
