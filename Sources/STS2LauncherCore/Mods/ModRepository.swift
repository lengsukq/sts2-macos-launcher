import Foundation

private struct PersistedModEntry: Codable, Sendable {
    let id: String
    let isEnabled: Bool
    let loadOrder: Int
}

public struct ModRepository: Sendable {
    public let paths: LauncherPaths

    public init(paths: LauncherPaths = LauncherPaths()) {
        self.paths = paths
    }

    public func loadMods() throws -> [ModItem] {
        try paths.ensureDirectoriesExist()
        let fm = FileManager.default
        let savedState = loadSavedState()

        let entries = try fm.contentsOfDirectory(
            at: paths.modsLibraryDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var discovered: [ModItem] = []
        for entry in entries {
            guard ((try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) else {
                continue
            }
            let mod = inspectModDirectory(entry, savedState: savedState)
            discovered.append(mod)
        }

        discovered.sort { lhs, rhs in
            if lhs.loadOrder != rhs.loadOrder {
                return lhs.loadOrder < rhs.loadOrder
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        for idx in discovered.indices {
            discovered[idx].loadOrder = idx
        }

        return discovered
    }

    public func saveState(for mods: [ModItem]) throws {
        try paths.ensureDirectoriesExist()
        let entries = mods.enumerated().map { index, item in
            PersistedModEntry(id: item.id, isEnabled: item.isEnabled, loadOrder: index)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: paths.modsConfigFile, options: .atomic)
    }

    public func importMod(from sourceURL: URL) throws -> ModItem {
        try paths.ensureDirectoriesExist()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw LauncherError(
                title: "找不到待导入的 Mod",
                detail: "路径不存在：\(sourceURL.path)",
                recoverySuggestionText: "请确认 Mod 文件夹或 .zip 压缩包路径有效。"
            )
        }

        let stagingRoot: URL
        var cleanupTempDir: URL?
        defer {
            if let cleanupTempDir {
                try? fm.removeItem(at: cleanupTempDir)
            }
        }

        if isDir.boolValue {
            stagingRoot = sourceURL
        } else if sourceURL.pathExtension.lowercased() == "zip" {
            let tempDir = paths.modsLibraryDirectory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            cleanupTempDir = tempDir
            try SystemCommandRunner.extractZip(at: sourceURL, to: tempDir)
            stagingRoot = resolveModRoot(in: tempDir)
        } else {
            throw LauncherError(
                title: "不支持的 Mod 格式",
                detail: "仅支持导入 Mod 目录或 .zip 压缩包（收到：\(sourceURL.lastPathComponent)）。",
                recoverySuggestionText: "请把包含 mod_manifest.json / .dll / .pck 的目录或 zip 拖入启动器。"
            )
        }

        let tempInspect = inspectModDirectory(stagingRoot, savedState: [:])
        guard tempInspect.manifest != nil || !tempInspect.dllFiles.isEmpty || !tempInspect.pckFiles.isEmpty else {
            throw LauncherError(
                title: "未识别到有效的 Mod 文件",
                detail: "目录 \(stagingRoot.lastPathComponent) 内缺少 mod_manifest.json、.dll 或 .pck。",
                recoverySuggestionText: "请检查是否选错目录层级，确认压缩包内包含《杀戮尖塔2》Godot/C# Mod 文件。"
            )
        }

        let folderName = sanitizeFolderName(tempInspect.manifest?.id ?? stagingRoot.lastPathComponent)
        let targetDir = paths.modsLibraryDirectory.appendingPathComponent(folderName, isDirectory: true)
        try SystemCommandRunner.cloneOrCopyItem(from: stagingRoot, to: targetDir)

        var existingMods = try loadMods()
        if let idx = existingMods.firstIndex(where: { $0.folderName == folderName }) {
            existingMods[idx].isEnabled = true
            try saveState(for: existingMods)
            return existingMods[idx]
        }

        let fresh = inspectModDirectory(targetDir, savedState: [:])
        existingMods.append(fresh)
        try saveState(for: existingMods)
        return fresh
    }

    public func deleteMod(_ mod: ModItem) throws {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: mod.folderPath)
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        let remaining = try loadMods()
        try saveState(for: remaining)
    }

    public func validate(mods: [ModItem]) -> [ModValidationIssue] {
        var issues: [ModValidationIssue] = []
        let byID = Dictionary(mods.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        let enabledMods = mods.filter(\.isEnabled)

        for mod in mods {
            if mod.manifest == nil {
                issues.append(ModValidationIssue(
                    modID: mod.id,
                    severity: .warning,
                    message: "缺少 \(GameConstants.modManifestFileName)",
                    recoveryHint: "建议补充 mod_manifest.json 以便识别版本号与依赖关系。"
                ))
            }
            if mod.dllFiles.isEmpty && mod.pckFiles.isEmpty {
                issues.append(ModValidationIssue(
                    modID: mod.id,
                    severity: .error,
                    message: "目录中未找到 .dll 或 .pck 资产",
                    recoveryHint: "该 Mod 无法生效，请重新下载完整压缩包。"
                ))
            }
        }

        for mod in enabledMods {
            let deps = mod.manifest?.dependencies ?? []
            for dep in deps {
                let normalizedDep = dep.lowercased()
                guard let target = byID[normalizedDep] else {
                    issues.append(ModValidationIssue(
                        modID: mod.id,
                        severity: .error,
                        message: "缺少前置依赖：\(dep)",
                        recoveryHint: "请先导入并启用 \(dep)，否则启动游戏时该 Mod 可能报错或被跳过。"
                    ))
                    continue
                }

                if !target.isEnabled {
                    issues.append(ModValidationIssue(
                        modID: mod.id,
                        severity: .error,
                        message: "前置依赖 \(target.displayName) 当前未启用",
                        recoveryHint: "请在 Mod 列表中启用 \(target.displayName)。"
                    ))
                } else if target.loadOrder > mod.loadOrder {
                    issues.append(ModValidationIssue(
                        modID: mod.id,
                        severity: .warning,
                        message: "前置依赖 \(target.displayName) 排在当前 Mod 之后",
                        recoveryHint: "建议将 \(target.displayName) 上移至 \(mod.displayName) 之前加载。"
                    ))
                }
            }
        }

        for cycleModID in detectCircularDependencies(in: enabledMods) {
            issues.append(ModValidationIssue(
                modID: cycleModID,
                severity: .error,
                message: "检测到循环依赖",
                recoveryHint: "请检查 mod_manifest.json 中的 dependencies，或先禁用冲突的 Mod。"
            ))
        }

        return issues
    }

    private func detectCircularDependencies(in enabledMods: [ModItem]) -> [String] {
        let map = Dictionary(enabledMods.map { ($0.id.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        var state: [String: Int] = [:] // 1 = visiting, 2 = visited
        var cyclicIDs: Set<String> = []

        func dfs(_ nodeKey: String) {
            state[nodeKey] = 1
            let deps = map[nodeKey]?.manifest?.dependencies.map { $0.lowercased() } ?? []
            for dep in deps where map[dep] != nil {
                if state[dep] == 1 {
                    if let original = map[nodeKey]?.id {
                        cyclicIDs.insert(original)
                    }
                } else if state[dep] == nil {
                    dfs(dep)
                }
            }
            state[nodeKey] = 2
        }

        for mod in enabledMods {
            let key = mod.id.lowercased()
            if state[key] == nil {
                dfs(key)
            }
        }
        return cyclicIDs.sorted()
    }

    private func inspectModDirectory(_ directory: URL, savedState: [String: PersistedModEntry]) -> ModItem {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let dllFiles = items.filter { $0.pathExtension.lowercased() == "dll" }.map(\.lastPathComponent).sorted()
        let pckFiles = items.filter { $0.pathExtension.lowercased() == "pck" }.map(\.lastPathComponent).sorted()
        let manifest = parseManifest(at: directory.appendingPathComponent(GameConstants.modManifestFileName))
        let modID = manifest?.id ?? directory.lastPathComponent
        let persisted = savedState[modID] ?? savedState[directory.lastPathComponent]

        return ModItem(
            id: modID,
            folderName: directory.lastPathComponent,
            folderPath: directory.path,
            manifest: manifest,
            dllFiles: dllFiles,
            pckFiles: pckFiles,
            isEnabled: persisted?.isEnabled ?? true,
            loadOrder: persisted?.loadOrder ?? Int.max
        )
    }

    private func parseManifest(at url: URL) -> ModManifest? {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let fallbackName = url.deletingLastPathComponent().lastPathComponent
        let id = (raw["id"] as? String)
            ?? (raw["mod_id"] as? String)
            ?? (raw["pck_name"] as? String)
            ?? fallbackName
        let name = (raw["name"] as? String)
            ?? (raw["display_name"] as? String)
            ?? id
        let version = (raw["version"] as? String) ?? "0.0.0"
        let author = raw["author"] as? String
        let description = raw["description"] as? String
        let gameVersion = (raw["game_version"] as? String) ?? (raw["min_game_version"] as? String)
        let dependencies = parseDependencies(from: raw["dependencies"])

        return ModManifest(
            id: id,
            name: name,
            version: version,
            author: author,
            description: description,
            dependencies: dependencies,
            gameVersion: gameVersion
        )
    }

    private func parseDependencies(from rawValue: Any?) -> [String] {
        if let strings = rawValue as? [String] {
            return strings.filter { !$0.isEmpty }
        }
        if let dicts = rawValue as? [[String: Any]] {
            return dicts.compactMap { ($0["id"] as? String) ?? ($0["mod_id"] as? String) }
        }
        return []
    }

    private func loadSavedState() -> [String: PersistedModEntry] {
        guard let data = try? Data(contentsOf: paths.modsConfigFile),
              let entries = try? JSONDecoder().decode([PersistedModEntry].self, from: data) else {
            return [:]
        }
        return Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func resolveModRoot(in extractedDir: URL) -> URL {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(
            at: extractedDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let hasDirectModFiles = items.contains {
            let ext = $0.pathExtension.lowercased()
            return $0.lastPathComponent == GameConstants.modManifestFileName || ext == "dll" || ext == "pck"
        }
        if hasDirectModFiles {
            return extractedDir
        }

        let subdirs = items.filter {
            $0.lastPathComponent != "__MACOSX"
                && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }
        if subdirs.count == 1 {
            return subdirs[0]
        }
        return extractedDir
    }

    private func sanitizeFolderName(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "_", options: .regularExpression)
        return cleaned.isEmpty ? "mod-\(UUID().uuidString.prefix(6))" : cleaned
    }
}
