import AppKit
import SwiftUI

final class LauncherAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ensures swift-run executables present a normal macOS menu bar and foreground window.
        NSApp.setActivationPolicy(.regular)
        applyAppIconIfAvailable()
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func applyAppIconIfAvailable() {
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("assets/AppIcon.icns")
        ]
        for case let url? in candidates where FileManager.default.fileExists(atPath: url.path) {
            if let image = NSImage(contentsOf: url) {
                NSApp.applicationIconImage = image
                return
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct STS2LauncherApp: App {
    @NSApplicationDelegateAdaptor(LauncherAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup("杀戮尖塔2 macOS 启动器") {
            RootContentView(state: appState)
                .frame(minWidth: 940, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .newItem) {
                Button(appState.isGameRunning ? "停止游戏" : "启动游戏") {
                    if appState.isGameRunning {
                        appState.stopGame()
                    } else {
                        appState.launchGame()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled((!appState.isGameRunning && !appState.canLaunchGame) || appState.isBuildingBridgeRuntime)

                Button("刷新全部状态") {
                    appState.reloadAll()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("安装/重建桥接运行时") {
                    appState.setupBridgeRuntime()
                }
                .disabled(appState.isBuildingBridgeRuntime || appState.isStaging || appState.isGameRunning)

                Divider()

                Button("打开启动器数据目录") {
                    appState.openDirectoryInFinder(appState.paths.baseDirectory)
                }
                Button("打开桥接运行时目录") {
                    appState.openDirectoryInFinder(appState.bridgeRuntimeRootURL)
                }
                Button("打开游戏存档目录") {
                    appState.openDirectoryInFinder(appState.paths.gameUserDataDirectory)
                }
            }

            CommandMenu("导航") {
                ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element.id) { index, section in
                    Button(section.title) {
                        appState.selectedSection = section
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
        }

        Settings {
            SettingsView(state: appState)
        }
    }
}

struct RootContentView: View {
    @Bindable var state: AppState

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $state.selectedSection) { section in
                NavigationLink(value: section) {
                    Label {
                        HStack {
                            Text(section.title)
                            Spacer(minLength: 4)
                            badgeView(for: section)
                        }
                    } icon: {
                        Image(systemName: section.systemImage)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
            .listStyle(.sidebar)
        } detail: {
            detailView
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            state.reloadAll()
                        } label: {
                            Label("刷新", systemImage: "arrow.clockwise")
                        }
                        .help("重新扫描游戏包、Mod 与存档状态 (⌘⇧R)")

                        if state.isGameRunning {
                            Button(role: .destructive) {
                                state.stopGame()
                            } label: {
                                Label("停止游戏", systemImage: "stop.fill")
                            }
                            .help("结束当前运行中的游戏进程")
                        } else {
                            Button {
                                state.launchGame()
                            } label: {
                                Label(state.isStaging ? "合成中…" : "启动游戏", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!state.canLaunchGame || state.isBuildingBridgeRuntime)
                            .help("合成并启动《杀戮尖塔2》(⌘R)")
                        }
                    }
                }
        }
        .alert(
            state.activeError?.title ?? "错误",
            isPresented: Binding(
                get: { state.activeError != nil },
                set: { if !$0 { state.activeError = nil } }
            ),
            presenting: state.activeError
        ) { _ in
            Button("知道了", role: .cancel) {
                state.activeError = nil
            }
        } message: { error in
            Text("\(error.detail)\n\n数据安全：\(error.dataSafetyNote)\n恢复建议：\(error.recoverySuggestionText)")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch state.selectedSection {
        case .dashboard:
            DashboardView(state: state)
        case .payloads:
            PayloadsView(state: state)
        case .mods:
            ModsView(state: state)
        case .saves:
            SavesView(state: state)
        case .logs:
            LogsView(state: state)
        }
    }

    @ViewBuilder
    private func badgeView(for section: SidebarSection) -> some View {
        switch section {
        case .payloads:
            if state.isBuildingBridgeRuntime {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("正在搭建桥接运行时")
            } else if state.bridgeRuntime?.isLaunchReady != true {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("桥接运行时尚未就绪")
            }
        case .mods:
            if !state.blockingModErrors.isEmpty {
                Text("\(state.blockingModErrors.count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Color.red.opacity(0.18), in: Capsule())
                    .foregroundStyle(.red)
            } else if state.enabledModCount > 0 {
                Text("\(state.enabledModCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .logs:
            if state.isGameRunning {
                Image(systemName: "circle.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.green)
                    .accessibilityLabel("游戏运行中")
            } else if let exit = state.lastExitCode, exit != 0 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel("上次运行异常退出")
            }
        default:
            EmptyView()
        }
    }
}
