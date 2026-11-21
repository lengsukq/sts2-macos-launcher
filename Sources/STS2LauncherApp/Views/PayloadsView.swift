import AppKit
import STS2LauncherCore
import SwiftUI
import UniformTypeIdentifiers

struct PayloadsView: View {
    @Bindable var state: AppState
    @State private var copyDirectoryOnImport: Bool = false
    @State private var isDropTargeted: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                bridgeRuntimeSection
                windowsPayloadsSection
            }
            .padding(24)
        }
        .navigationTitle("游戏包与运行时")
    }

    private var bridgeRuntimeSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("1. 自建 macOS 桥接运行时（Bridge Runtime）")
                            .font(.headline)
                        Text("零官方 Mac 版依赖：本地组合 Godot 4.5.1 Mono、.NET 9 osx-arm64、Spine 4.2、FMOD 2.03.06、Native Stubs 与 STS2MacBridge 补丁。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    overallBridgeStatusPill
                }

                HStack(spacing: 10) {
                    Button {
                        state.setupBridgeRuntime()
                    } label: {
                        if state.isBuildingBridgeRuntime {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("正在搭建…")
                            }
                        } else {
                            Label("一键安装/重建桥接运行时", systemImage: "wrench.and.screwdriver.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isBuildingBridgeRuntime || state.isStaging || state.isGameRunning)

                    Button("重新检测") {
                        state.reinspectBridgeRuntimeWithStatus()
                    }
                    .disabled(state.isBuildingBridgeRuntime)

                    Button("打开运行时目录") {
                        state.openDirectoryInFinder(state.bridgeRuntimeRootURL)
                    }

                    Spacer()
                }

                if state.isBuildingBridgeRuntime {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(state.statusBanner ?? "正在执行 scripts/setup-bridge-runtime.sh…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Button("查看构建日志") {
                            state.selectedSection = .logs
                        }
                        .controlSize(.small)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                if let runtime = state.bridgeRuntime {
                    VStack(alignment: .leading, spacing: 10) {
                        LabeledContent("运行时目录") {
                            HStack(spacing: 8) {
                                if state.hasCustomBridgeRuntimePath {
                                    Text("自定义")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                } else if state.isUsingBundledBridgeRuntime {
                                    Text("内置开箱即用")
                                        .font(.caption2.weight(.medium))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Color.green.opacity(0.16), in: Capsule())
                                        .foregroundStyle(.green)
                                }
                                Text(runtime.rootPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)

                                Button("自定义…") {
                                    chooseCustomBridgeDirectoryPanel()
                                }
                                .controlSize(.small)
                                .disabled(state.isBuildingBridgeRuntime)

                                if state.hasCustomBridgeRuntimePath {
                                    Button("恢复默认") {
                                        state.resetBridgeRuntimeDirectory()
                                    }
                                    .controlSize(.small)
                                    .disabled(state.isBuildingBridgeRuntime)
                                }
                            }
                        }
                        LabeledContent("组件版本") {
                            Text("Godot \(runtime.godotVersion) · .NET \(runtime.dotnetVersion) · Spine \(runtime.spineVersion) · FMOD \(runtime.fmodVersion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("FMOD 音频模式") {
                            Label(
                                BridgeDisplayFormatter.fmodModeLabel(runtime.fmodMode),
                                systemImage: BridgeDisplayFormatter.fmodModeSymbol(runtime.fmodMode)
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }

                        if runtime.components.isEmpty {
                            ContentUnavailableView(
                                "尚未检测到桥接组件",
                                systemImage: "square.stack.3d.up.slash",
                                description: Text("点击上方“一键安装/重建桥接运行时”在用户数据目录自动下载并组合 6 大桥接组件。")
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        } else {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                                ForEach(runtime.components, id: \.name) { component in
                                    bridgeComponentCard(component)
                                }
                            }
                            .padding(.top, 2)
                        }
                    }
                } else {
                    ContentUnavailableView(
                        "尚未搭建自建 macOS 桥接运行时",
                        systemImage: "square.stack.3d.up",
                        description: Text("点击上方“一键安装/重建桥接运行时”自动装配 Godot 4.5.1 Mono、.NET 9、Spine、FMOD、Native Stubs 与 STS2MacBridge。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private var overallBridgeStatusPill: some View {
        if state.isBuildingBridgeRuntime {
            Label("构建中", systemImage: "gearshape.2.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
                .foregroundStyle(Color.accentColor)
        } else if state.bridgeRuntime?.isLaunchReady == true {
            Label("全部必需组件就绪", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.14), in: Capsule())
                .foregroundStyle(.green)
        } else {
            Label("待搭建 / 缺失组件", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.orange.opacity(0.14), in: Capsule())
                .foregroundStyle(.orange)
        }
    }

    private func bridgeComponentCard(_ component: BridgeComponentState) -> some View {
        let tint: Color = component.isReady ? .green : (component.isOptional ? .orange : .red)
        let symbolName: String = component.isReady
            ? "checkmark.circle.fill"
            : (component.isOptional ? "exclamationmark.triangle.fill" : "xmark.circle.fill")
        let statusText: String = component.isReady
            ? "已就绪"
            : (component.isOptional ? "可选 / 兜底" : "缺失")

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(component.name, systemImage: symbolName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(tint.opacity(0.14), in: Capsule())
                    .foregroundStyle(tint)

                Spacer()

                Text(statusText)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(tint)
                    .fixedSize()

                if let path = component.path, !path.isEmpty {
                    Button {
                        state.revealInFinder(URL(fileURLWithPath: path))
                    } label: {
                        Image(systemName: "folder")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("在 Finder 中显示 \(component.name)")
                    .accessibilityLabel("在 Finder 中显示 \(component.name)")
                }
            }

            Text(component.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let path = component.path, !path.isEmpty {
                Text(path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.quaternary.opacity(0.32), in: RoundedRectangle(cornerRadius: 8))
    }

    private var windowsPayloadsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("2. Windows 游戏资产包 (.pck + sts2.dll)")
                            .font(.headline)
                        Text("支持导入已解压的 Windows 目录或 .zip 压缩包；建议保持就地引用以节省磁盘空间。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("导入目录时复制到受管仓库", isOn: $copyDirectoryOnImport)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    Button("导入目录 / ZIP…") {
                        chooseWindowsPayloadPanel()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.isImporting)
                }

                Divider()

                if state.configuration.payloads.isEmpty {
                    ContentUnavailableView(
                        "尚未导入 Windows 游戏包",
                        systemImage: "shippingbox",
                        description: Text("点击右上角“导入目录 / ZIP…”，选择包含 SlayTheSpire2.pck 与 data_sts2_windows_x86_64 的目录或压缩包。")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    VStack(spacing: 8) {
                        ForEach(state.configuration.payloads) { payload in
                            payloadRow(payload)
                        }
                    }
                }
            }
            .padding(8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else {
                return false
            }
            let shouldCopy = copyDirectoryOnImport
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    state.importWindowsPayload(from: url, copyIntoStore: shouldCopy)
                }
            }
            return true
        }
    }

    private func payloadRow(_ payload: WindowsPayloadInfo) -> some View {
        let isSelected = state.selectedPayload?.id == payload.id
        let sizeMB = Double(payload.pckSizeBytes) / (1024 * 1024)

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(payload.displayName)
                        .font(.headline)
                    if let ver = payload.releaseVersion {
                        Text(ver)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text("\(payload.pckFileName) (\(String(format: "%.1f", sizeMB)) MB) · sts2.dll SHA-256: \(payload.shortHash)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(payload.rootPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if !isSelected {
                Button("设为当前") {
                    state.selectPayload(id: payload.id)
                }
                .controlSize(.small)
            }
            Button {
                state.revealInFinder(URL(fileURLWithPath: payload.rootPath))
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            .accessibilityLabel("在 Finder 中显示 \(payload.displayName)")

            Button(role: .destructive) {
                state.removePayload(payload)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("从列表移除（不删除原文件）")
            .accessibilityLabel("移除 \(payload.displayName)")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.05))
        )
    }

    private func chooseCustomBridgeDirectoryPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择自建桥接运行时根目录 (bridge-runtime)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.setCustomBridgeRuntimeDirectory(url: url)
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
            state.importWindowsPayload(from: url, copyIntoStore: copyDirectoryOnImport)
        }
    }
}
