import Foundation

public struct SaveManager: Sendable {
    public let paths: LauncherPaths

    public init(paths: LauncherPaths = LauncherPaths()) {
        self.paths = paths
    }

    public func discoverAccountSlots() -> [SaveAccountSlot] {
        let fm = FileManager.default
        let namespaces = ["steam", "default"]
        var slots: [SaveAccountSlot] = []

        for ns in namespaces {
            let nsDir = paths.gameUserDataDirectory.appendingPathComponent(ns, isDirectory: true)
            guard let accounts = try? fm.contentsOfDirectory(
                at: nsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for accountDir in accounts.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard ((try? accountDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) else {
                    continue
                }
                let vanillaSummary = summarizeBucket(.vanilla, accountRoot: accountDir)
                let moddedSummary = summarizeBucket(.modded, accountRoot: accountDir)
                slots.append(SaveAccountSlot(
                    namespaceName: ns,
                    accountID: accountDir.lastPathComponent,
                    accountRootPath: accountDir.path,
                    vanilla: vanillaSummary,
                    modded: moddedSummary
                ))
            }
        }

        return slots
    }

    public func listSnapshots() -> [SaveSnapshot] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: paths.snapshotsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var snapshots: [SaveSnapshot] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("snapshot-meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let meta = try? decoder.decode(SaveSnapshot.self, from: data) else {
                continue
            }
            snapshots.append(meta)
        }
        return snapshots.sorted(by: { $0.createdAt > $1.createdAt })
    }

    @discardableResult
    public func createSnapshot(for slot: SaveAccountSlot, bucket: SaveBucket, note: String) throws -> SaveSnapshot {
        try paths.ensureDirectoriesExist()
        let fm = FileManager.default
        let sourceRoot = bucketRoot(for: slot, bucket: bucket)
        let snapshotID = makeSnapshotID(slot: slot, bucket: bucket)
        let archiveDir = paths.snapshotsDirectory.appendingPathComponent(snapshotID, isDirectory: true)
        let payloadDir = archiveDir.appendingPathComponent("data", isDirectory: true)
        try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true)

        var copiedCount = 0
        for itemName in managedSaveEntries(in: sourceRoot, bucket: bucket) {
            let src = sourceRoot.appendingPathComponent(itemName)
            let dst = payloadDir.appendingPathComponent(itemName)
            try SystemCommandRunner.cloneOrCopyItem(from: src, to: dst)
            copiedCount += countRegularFiles(under: dst)
        }

        let snapshot = SaveSnapshot(
            id: snapshotID,
            accountSlotID: slot.id,
            bucket: bucket,
            note: note,
            createdAt: Date(),
            archiveDirectoryPath: archiveDir.path,
            fileCount: copiedCount
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let metaData = try encoder.encode(snapshot)
        try metaData.write(to: archiveDir.appendingPathComponent("snapshot-meta.json"), options: .atomic)

        return snapshot
    }

    /// Always snapshots the destination bucket first so accidental overwrites remain recoverable.
    @discardableResult
    public func transfer(
        slot: SaveAccountSlot,
        from sourceBucket: SaveBucket,
        to destinationBucket: SaveBucket
    ) throws -> SaveSnapshot {
        guard sourceBucket != destinationBucket else {
            throw LauncherError(
                title: "无效的存档转移",
                detail: "来源与目标存档分区相同（\(sourceBucket.displayName)）。",
                recoverySuggestionText: "请选择不同的来源和目标分区。"
            )
        }

        let sourceRoot = bucketRoot(for: slot, bucket: sourceBucket)
        let sourceEntries = managedSaveEntries(in: sourceRoot, bucket: sourceBucket)
        guard !sourceEntries.isEmpty else {
            throw LauncherError(
                title: "来源存档为空",
                detail: "\(sourceBucket.displayName) 目录 \(sourceRoot.path) 中未找到任何 profile1..3 或 profile.save。",
                recoverySuggestionText: "请先在对应模式下运行一次游戏生成存档后再执行转移。"
            )
        }

        let safetySnapshot = try createSnapshot(
            for: slot,
            bucket: destinationBucket,
            note: "自动安全备份：执行 \(sourceBucket.displayName) → \(destinationBucket.displayName) 转移前"
        )

        let fm = FileManager.default
        let destRoot = bucketRoot(for: slot, bucket: destinationBucket)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        for existingName in managedSaveEntries(in: destRoot, bucket: destinationBucket) {
            try fm.removeItem(at: destRoot.appendingPathComponent(existingName))
        }

        for entryName in sourceEntries {
            try SystemCommandRunner.cloneOrCopyItem(
                from: sourceRoot.appendingPathComponent(entryName),
                to: destRoot.appendingPathComponent(entryName)
            )
        }

        return safetySnapshot
    }

    @discardableResult
    public func restoreSnapshot(_ snapshot: SaveSnapshot, to slot: SaveAccountSlot) throws -> SaveSnapshot {
        let fm = FileManager.default
        let archiveDataDir = URL(fileURLWithPath: snapshot.archiveDirectoryPath).appendingPathComponent("data", isDirectory: true)
        guard fm.fileExists(atPath: archiveDataDir.path) else {
            throw LauncherError(
                title: "快照数据丢失",
                detail: "快照目录缺少 data 子目录：\(archiveDataDir.path)",
                recoverySuggestionText: "请选择其他完好的快照进行恢复。"
            )
        }

        let safetyBackup = try createSnapshot(
            for: slot,
            bucket: snapshot.bucket,
            note: "自动安全备份：恢复快照 \(snapshot.id) 前"
        )

        let destRoot = bucketRoot(for: slot, bucket: snapshot.bucket)
        try fm.createDirectory(at: destRoot, withIntermediateDirectories: true)

        for existingName in managedSaveEntries(in: destRoot, bucket: snapshot.bucket) {
            try fm.removeItem(at: destRoot.appendingPathComponent(existingName))
        }

        let archivedItems = (try? fm.contentsOfDirectory(atPath: archiveDataDir.path)) ?? []
        for name in archivedItems {
            try SystemCommandRunner.cloneOrCopyItem(
                from: archiveDataDir.appendingPathComponent(name),
                to: destRoot.appendingPathComponent(name)
            )
        }

        return safetyBackup
    }

    private func bucketRoot(for slot: SaveAccountSlot, bucket: SaveBucket) -> URL {
        let root = URL(fileURLWithPath: slot.accountRootPath)
        switch bucket {
        case .vanilla:
            return root
        case .modded:
            return root.appendingPathComponent(GameConstants.moddedFolderName, isDirectory: true)
        }
    }

    /// Lists only save slots and `profile.save`, explicitly excluding `modded/` when inspecting `.vanilla`
    /// so vanilla operations never accidentally swallow or delete the nested `modded/` tree.
    private func managedSaveEntries(in directory: URL, bucket: SaveBucket) -> [String] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return items.filter { name in
            if bucket == .vanilla && name == GameConstants.moddedFolderName {
                return false
            }
            if name == GameConstants.profileSaveFileName {
                return true
            }
            return name.hasPrefix("profile")
        }.sorted()
    }

    private func summarizeBucket(_ bucket: SaveBucket, accountRoot: URL) -> SaveBucketSummary {
        let root: URL = (bucket == .vanilla)
            ? accountRoot
            : accountRoot.appendingPathComponent(GameConstants.moddedFolderName, isDirectory: true)

        let entries = managedSaveEntries(in: root, bucket: bucket)
        var fileCount = 0
        var totalBytes: Int64 = 0
        var latestModified: Date?
        var profileSlots: [String] = []

        for name in entries {
            if name.hasPrefix("profile"), name != GameConstants.profileSaveFileName {
                profileSlots.append(name)
            }
            let itemURL = root.appendingPathComponent(name)
            let stats = collectFileStats(under: itemURL)
            fileCount += stats.count
            totalBytes += stats.bytes
            if let modDate = stats.latestModified {
                if let current = latestModified {
                    latestModified = max(current, modDate)
                } else {
                    latestModified = modDate
                }
            }
        }

        return SaveBucketSummary(
            bucket: bucket,
            rootPath: root.path,
            exists: !entries.isEmpty,
            fileCount: fileCount,
            totalBytes: totalBytes,
            lastModified: latestModified,
            profileSlotsPresent: profileSlots.sorted()
        )
    }

    private func collectFileStats(under url: URL) -> (count: Int, bytes: Int64, latestModified: Date?) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return (0, 0, nil)
        }

        if !isDir.boolValue {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (1, Int64(values?.fileSize ?? 0), values?.contentModificationDate)
        }

        var count = 0
        var bytes: Int64 = 0
        var latest: Date?
        if let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ) {
            for case let fileURL as URL in enumerator {
                let values = try? fileURL.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
                )
                guard values?.isRegularFile == true else { continue }
                count += 1
                bytes += Int64(values?.fileSize ?? 0)
                if let date = values?.contentModificationDate {
                    latest = latest.map { max($0, date) } ?? date
                }
            }
        }
        return (count, bytes, latest)
    }

    private func countRegularFiles(under url: URL) -> Int {
        collectFileStats(under: url).count
    }

    private func makeSnapshotID(slot: SaveAccountSlot, bucket: SaveBucket) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let stamp = formatter.string(from: Date())
        let safeSlot = slot.id.replacingOccurrences(of: "/", with: "_")
        return "\(stamp)-\(safeSlot)-\(bucket.rawValue)-\(UUID().uuidString.prefix(4).lowercased())"
    }
}
