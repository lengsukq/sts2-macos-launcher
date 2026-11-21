import STS2LauncherCore
import SwiftUI

struct LogsView: View {
    @Bindable var state: AppState
    @State private var searchText: String = ""
    @State private var minimumLevel: LogLevel = .debug
    @State private var autoScroll: Bool = true

    private var filteredLogs: [LogEntry] {
        state.logs.filter { entry in
            guard levelRank(entry.level) >= levelRank(minimumLevel) else { return false }
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            return entry.message.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            filterToolbar
            Divider()

            if !state.diagnosticFindings.isEmpty {
                diagnosticsPanel
                Divider()
            }

            if filteredLogs.isEmpty {
                ContentUnavailableView(
                    state.logs.isEmpty ? "暂无会话日志" : "没有匹配筛选条件的日志",
                    systemImage: "terminal",
                    description: Text(state.logs.isEmpty ? "启动游戏后将在此实时显示 stdout / stderr 输出。" : "尝试降低日志级别或清空搜索关键词。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(filteredLogs) { entry in
                                logLineView(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(12)
                        .textSelection(.enabled)
                    }
                    .onChange(of: filteredLogs.last?.id) { _, lastID in
                        if autoScroll, let lastID {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("日志与诊断")
    }

    private var filterToolbar: some View {
        HStack(spacing: 12) {
            TextField("搜索日志关键字…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            Picker("最低级别", selection: $minimumLevel) {
                Text("DEBUG+").tag(LogLevel.debug)
                Text("INFO+").tag(LogLevel.info)
                Text("WARN+").tag(LogLevel.warning)
                Text("ERROR").tag(LogLevel.error)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Toggle("自动滚动", isOn: $autoScroll)
                .toggleStyle(.checkbox)

            Spacer()

            if let logPath = state.lastLogFilePath {
                Button("显示日志文件") {
                    state.revealInFinder(URL(fileURLWithPath: logPath))
                }
            }

            Button("打开日志目录") {
                state.openDirectoryInFinder(state.paths.logsDirectory)
            }

            Button("清空") {
                state.clearLogs()
            }
            .disabled(state.logs.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("崩溃与启动自动诊断", systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                if let code = state.lastExitCode {
                    Text("退出码：\(code)")
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background((code == 0 ? Color.green : Color.red).opacity(0.15), in: Capsule())
                }
            }

            ForEach(state.diagnosticFindings) { finding in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: finding.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(finding.severity == .error ? .red : .orange)
                        Text("[\(finding.category)] \(finding.title)")
                            .font(.callout.weight(.semibold))
                    }
                    Text("证据：\(finding.evidence)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("恢复建议：\(finding.recoveryAction)")
                        .font(.caption)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
    }

    private func logLineView(_ entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .foregroundStyle(.tertiary)
            Text(entry.level.label)
                .foregroundStyle(color(for: entry.level))
                .frame(width: 54, alignment: .leading)
            Text("[\(entry.source.rawValue)]")
                .foregroundStyle(.secondary)
            Text(entry.message)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func levelRank(_ level: LogLevel) -> Int {
        switch level {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}
