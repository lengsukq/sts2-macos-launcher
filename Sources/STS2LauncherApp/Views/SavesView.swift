import STS2LauncherCore
import SwiftUI

struct PendingTransferRequest: Identifiable {
    let id = UUID()
    let slot: SaveAccountSlot
    let from: SaveBucket
    let to: SaveBucket
}

struct SavesView: View {
    @Bindable var state: AppState
    @State private var pendingTransfer: PendingTransferRequest?
    @State private var pendingRestoreSnapshot: SaveSnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                isolationNoteCard
                accountSlotsSection
                snapshotsSection
            }
            .padding(24)
        }
        .navigationTitle("存档与快照")
        .confirmationDialog(
            transferDialogTitle,
            isPresented: Binding(
                get: { pendingTransfer != nil },
                set: { if !$0 { pendingTransfer = nil } }
            ),
            presenting: pendingTransfer
        ) { request in
            Button("确认备份并转移", role: request.to == .vanilla ? .destructive : nil) {
                state.transferSaves(slot: request.slot, from: request.from, to: request.to)
                pendingTransfer = nil
            }
            Button("取消", role: .cancel) {
                pendingTransfer = nil
            }
        } message: { request in
            if request.to == .vanilla {
                Text("将覆盖普通存档（转移前会自动为普通存档创建安全快照）。注意：如果 MOD 存档包含自定义卡牌/遗物/角色，原版游戏可能无法读取；仅建议用于纯 UI/QoL 类 Mod。")
            } else {
                Text("将把当前普通存档复制到 MOD 存档区（转移前会自动为现有 MOD 存档创建安全快照）。")
            }
        }
        .confirmationDialog(
            "确认恢复存档快照？",
            isPresented: Binding(
                get: { pendingRestoreSnapshot != nil },
                set: { if !$0 { pendingRestoreSnapshot = nil } }
            ),
            presenting: pendingRestoreSnapshot
        ) { snapshot in
            Button("备份当前并恢复此快照", role: .destructive) {
                state.restoreSnapshot(snapshot)
                pendingRestoreSnapshot = nil
            }
            Button("取消", role: .cancel) {
                pendingRestoreSnapshot = nil
            }
        } message: { snapshot in
            Text("恢复快照 \(snapshot.id) 前，启动器会自动将当前 \(snapshot.bucket.displayName) 再做一次安全备份。")
        }
    }

    private var transferDialogTitle: String {
        guard let req = pendingTransfer else { return "确认存档转移" }
        return "确认执行 \(req.from.displayName) → \(req.to.displayName)？"
    }

    private var isolationNoteCard: some View {
        GroupBox {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text("普通存档与 MOD 存档严格隔离")
                        .font(.headline)
                    Text("启动器绝不静默合并两套存档；任何转移或恢复前都会强制对目标槽位创建时间戳快照备份。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开存档目录") {
                    state.openDirectoryInFinder(state.paths.gameUserDataDirectory)
                }
            }
            .padding(6)
        }
    }

    private var accountSlotsSection: some View {
        GroupBox("已发现的账号存档槽位") {
            if state.saveSlots.isEmpty {
                ContentUnavailableView(
                    "暂未发现游戏存档",
                    systemImage: "externaldrive",
                    description: Text("尚未在 \(state.paths.gameUserDataDirectory.path) 下检测到 steam/ 或 default/ 账号目录。首次启动游戏后会自动生成。")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                VStack(spacing: 14) {
                    ForEach(state.saveSlots) { slot in
                        accountSlotCard(slot)
                    }
                }
                .padding(6)
            }
        }
    }

    private func accountSlotCard(_ slot: SaveAccountSlot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("账号：\(slot.id)", systemImage: "person.crop.circle")
                    .font(.headline)
                Spacer()
                Button("在 Finder 打开") {
                    state.openDirectoryInFinder(URL(fileURLWithPath: slot.accountRootPath))
                }
                .controlSize(.small)
            }

            HStack(spacing: 12) {
                bucketCard(slot: slot, summary: slot.vanilla)
                bucketCard(slot: slot, summary: slot.modded)
            }

            HStack(spacing: 10) {
                Button("普通存档 → MOD 存档") {
                    pendingTransfer = PendingTransferRequest(slot: slot, from: .vanilla, to: .modded)
                }
                .disabled(!slot.vanilla.exists)

                Button("MOD 存档 → 普通存档") {
                    pendingTransfer = PendingTransferRequest(slot: slot, from: .modded, to: .vanilla)
                }
                .disabled(!slot.modded.exists)
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private func bucketCard(slot: SaveAccountSlot, summary: SaveBucketSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(summary.bucket.displayName)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("快照备份") {
                    state.createSaveSnapshot(slot: slot, bucket: summary.bucket, note: "手动备份")
                }
                .controlSize(.mini)
                .disabled(!summary.exists)
            }
            if summary.exists {
                Text("槽位：\(summary.profileSlotsPresent.isEmpty ? "仅 profile.save" : summary.profileSlotsPresent.joined(separator: ", "))")
                    .font(.caption)
                Text("文件数：\(summary.fileCount) · 大小：\(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未生成该分区存档")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
    }

    private var snapshotsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("安全快照备份 (\(state.saveSnapshots.count))")
                        .font(.headline)
                    Spacer()
                    Button("打开快照目录") {
                        state.openDirectoryInFinder(state.paths.snapshotsDirectory)
                    }
                    .controlSize(.small)
                }

                Divider()

                if state.saveSnapshots.isEmpty {
                    Text("暂无快照。手动点击“快照备份”或执行存档转移时会自动创建。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(state.saveSnapshots) { snapshot in
                        HStack(alignment: .center, spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(snapshot.accountSlotID) · \(snapshot.bucket.displayName)")
                                    .font(.callout.weight(.medium))
                                Text("\(snapshot.note) · \(snapshot.fileCount) 个文件")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(snapshot.createdAt.formatted(date: .numeric, time: .standard))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("恢复到此快照") {
                                pendingRestoreSnapshot = snapshot
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
            .padding(6)
        }
    }
}
