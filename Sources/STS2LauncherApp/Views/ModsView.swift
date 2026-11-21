import AppKit
import STS2LauncherCore
import SwiftUI
import UniformTypeIdentifiers

struct ModsView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()

            if !state.modIssues.isEmpty {
                issuesBanner
                Divider()
            }

            if state.mods.isEmpty {
                ContentUnavailableView(
                    "Mod 库为空",
                    systemImage: "puzzlepiece.extension",
                    description: Text("点击“导入 Mod”添加包含 mod_manifest.json / .dll / .pck 的目录或 .zip 压缩包。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(state.mods.enumerated()), id: \.element.id) { index, mod in
                        modRow(mod: mod, index: index, total: state.mods.count)
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Mod 管理")
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Toggle("启动时启用 Mod", isOn: Binding(
                get: { state.configuration.enableMods },
                set: {
                    state.configuration.enableMods = $0
                    state.persistConfiguration()
                }
            ))
            .toggleStyle(.switch)

            Text("已启用 \(state.enabledModCount) / \(state.mods.count)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                state.openDirectoryInFinder(state.paths.modsLibraryDirectory)
            } label: {
                Label("打开 Mod 库", systemImage: "folder")
            }

            Button {
                chooseModPanel()
            } label: {
                Label("导入 Mod", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var issuesBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(state.modIssues) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(issue.severity == .error ? .red : .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(issue.modID)：\(issue.message)")
                            .font(.callout.weight(.medium))
                        Text(issue.recoveryHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }

    private func modRow(mod: ModItem, index: Int, total: Int) -> some View {
        let issuesForMod = state.modIssues.filter { $0.modID == mod.id }

        return HStack(spacing: 12) {
            Text("#\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)

            Toggle("", isOn: Binding(
                get: { mod.isEnabled },
                set: { state.setModEnabled(mod.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(mod.displayName)
                        .font(.headline)
                    Text(mod.versionText)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                    if let author = mod.manifest?.author, !author.isEmpty {
                        Text("by \(author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !issuesForMod.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(issuesForMod.contains(where: { $0.severity == .error }) ? .red : .orange)
                            .help(issuesForMod.map(\.message).joined(separator: "；"))
                    }
                }

                if let desc = mod.manifest?.description, !desc.isEmpty {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 12) {
                    Text("ID: \(mod.id)")
                    Text("DLL: \(mod.dllFiles.count)")
                    Text("PCK: \(mod.pckFiles.count)")
                    if let deps = mod.manifest?.dependencies, !deps.isEmpty {
                        Text("依赖: \(deps.joined(separator: ", "))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    state.moveMod(id: mod.id, offset: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == 0)
                .help("上移加载顺序")

                Button {
                    state.moveMod(id: mod.id, offset: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(index >= total - 1)
                .help("下移加载顺序")

                Button {
                    state.revealInFinder(URL(fileURLWithPath: mod.folderPath))
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中打开 Mod 目录")

                Button(role: .destructive) {
                    state.deleteMod(mod)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("删除该 Mod")
            }
        }
        .padding(.vertical, 4)
        .opacity(mod.isEnabled ? 1.0 : 0.55)
    }

    private func chooseModPanel() {
        let panel = NSOpenPanel()
        panel.title = "选择 Mod 目录或 .zip 压缩包"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.importMod(from: url)
        }
    }
}
