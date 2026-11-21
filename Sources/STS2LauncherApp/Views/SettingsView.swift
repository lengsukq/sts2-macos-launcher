import STS2LauncherCore
import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        Form {
            Section("桥接与渲染") {
                Picker("图形渲染驱动", selection: Binding(
                    get: { state.configuration.renderingDriver },
                    set: {
                        state.configuration.renderingDriver = $0
                        state.persistConfiguration()
                    }
                )) {
                    ForEach(RenderingDriver.allCases) { driver in
                        Text(driver.displayName).tag(driver)
                    }
                }

                TextField(
                    "官方 macOS libsteam_api.dylib 路径（可选，留空则从 bridge-runtime/steam 查找）",
                    text: Binding(
                        get: { state.configuration.customSteamApiDylibPath ?? "" },
                        set: {
                            let trimmed = $0.trimmingCharacters(in: .whitespacesAndNewlines)
                            state.configuration.customSteamApiDylibPath = trimmed.isEmpty ? nil : trimmed
                            state.persistConfiguration()
                        }
                    )
                )

                Toggle("启用游戏内性能与快捷悬浮窗（F9 显隐，Shift+F9 展开）", isOn: Binding(
                    get: { state.configuration.enableInGameOverlay },
                    set: {
                        state.configuration.enableInGameOverlay = $0
                        state.persistConfiguration()
                    }
                ))
            }

            Section("启动与兼容选项") {
                Picker("Mod 部署目标", selection: Binding(
                    get: { state.configuration.modDeployTarget },
                    set: {
                        state.configuration.modDeployTarget = $0
                        state.persistConfiguration()
                    }
                )) {
                    ForEach(ModDeployTarget.allCases) { target in
                        Text(target.displayName).tag(target)
                    }
                }

                Toggle("自动写入 steam_appid.txt (\(GameConstants.steamAppID))", isOn: Binding(
                    get: { state.configuration.writeSteamAppIDFile },
                    set: {
                        state.configuration.writeSteamAppIDFile = $0
                        state.persistConfiguration()
                    }
                ))

                Toggle("开启 Godot 详细日志 (--verbose，仅排障时按需启用)", isOn: Binding(
                    get: { state.configuration.enableVerboseLogging },
                    set: {
                        state.configuration.enableVerboseLogging = $0
                        state.persistConfiguration()
                    }
                ))

                Toggle("开启快速局域网联机 (--fastmp)", isOn: Binding(
                    get: { state.configuration.enableFastMultiplayer },
                    set: {
                        state.configuration.enableFastMultiplayer = $0
                        state.persistConfiguration()
                    }
                ))

                Toggle("设置 DOTNET_EnableWriteXorExecute=0（仅遇 JIT 崩溃时启用）", isOn: Binding(
                    get: { state.configuration.disableDotNetWriteXorExecute },
                    set: {
                        state.configuration.disableDotNetWriteXorExecute = $0
                        state.persistConfiguration()
                    }
                ))

                TextField("自定义额外启动参数（空格分隔）", text: Binding(
                    get: { state.configuration.customArguments },
                    set: {
                        state.configuration.customArguments = $0
                        state.persistConfiguration()
                    }
                ))
            }

            Section("目录位置") {
                directoryRow(
                    title: "桥接运行时目录",
                    url: state.bridgeRuntimeRootURL
                )
                directoryRow(
                    title: "启动器数据目录",
                    url: state.paths.baseDirectory
                )
                directoryRow(
                    title: "游戏存档目录",
                    url: state.paths.gameUserDataDirectory
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 520)
    }

    private func directoryRow(title: String, url: URL) -> some View {
        LabeledContent(title) {
            HStack {
                Text(url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("打开") {
                    state.openDirectoryInFinder(url)
                }
            }
        }
    }
}
