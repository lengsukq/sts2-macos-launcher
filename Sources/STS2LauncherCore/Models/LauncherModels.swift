import Foundation

public struct LauncherError: LocalizedError, Sendable, Equatable {
    public let title: String
    public let detail: String
    public let dataSafetyNote: String
    public let recoverySuggestionText: String

    public init(
        title: String,
        detail: String,
        dataSafetyNote: String = "原始游戏文件与存档未被修改。",
        recoverySuggestionText: String
    ) {
        self.title = title
        self.detail = detail
        self.dataSafetyNote = dataSafetyNote
        self.recoverySuggestionText = recoverySuggestionText
    }

    public var errorDescription: String? {
        "\(title)：\(detail)"
    }

    public var failureReason: String? {
        dataSafetyNote
    }

    public var recoverySuggestion: String? {
        recoverySuggestionText
    }

    public var formattedMessage: String {
        """
        [\(title)] \(detail)
        数据安全：\(dataSafetyNote)
        恢复建议：\(recoverySuggestionText)
        """
    }
}

public struct WindowsPayloadInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let rootPath: String
    public let pckPath: String
    public let pckFileName: String
    public let pckSizeBytes: Int64
    public let dataDirectoryPath: String
    public let sts2DllPath: String
    public let sts2DllSha256: String
    public let releaseVersion: String?
    public let supplementaryManagedDlls: [String]
    public let importedAt: Date

    public init(
        id: String,
        displayName: String,
        rootPath: String,
        pckPath: String,
        pckFileName: String,
        pckSizeBytes: Int64,
        dataDirectoryPath: String,
        sts2DllPath: String,
        sts2DllSha256: String,
        releaseVersion: String? = nil,
        supplementaryManagedDlls: [String],
        importedAt: Date = Date()
    ) {
        self.id = id
        self.displayName = displayName
        self.rootPath = rootPath
        self.pckPath = pckPath
        self.pckFileName = pckFileName
        self.pckSizeBytes = pckSizeBytes
        self.dataDirectoryPath = dataDirectoryPath
        self.sts2DllPath = sts2DllPath
        self.sts2DllSha256 = sts2DllSha256
        self.releaseVersion = releaseVersion
        self.supplementaryManagedDlls = supplementaryManagedDlls
        self.importedAt = importedAt
    }

    public var shortHash: String {
        String(sts2DllSha256.prefix(12))
    }
}

public enum RenderingDriver: String, Codable, Sendable, CaseIterable, Identifiable {
    case auto = "auto"
    case metal = "metal"
    case vulkan = "vulkan"
    case opengl3 = "opengl3"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "自动（推荐）"
        case .metal: return "Metal（Apple 原生）"
        case .vulkan: return "Vulkan（MoltenVK）"
        case .opengl3: return "OpenGL 3（兼容模式）"
        }
    }

    public var cliValue: String? {
        switch self {
        case .auto: return nil
        case .metal: return "metal"
        case .vulkan: return "vulkan"
        case .opengl3: return "opengl3"
        }
    }
}

public struct BridgeComponentState: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let isReady: Bool
    public let isOptional: Bool
    public let detail: String
    public let path: String?

    public init(
        name: String,
        isReady: Bool,
        isOptional: Bool = false,
        detail: String,
        path: String? = nil
    ) {
        self.name = name
        self.isReady = isReady
        self.isOptional = isOptional
        self.detail = detail
        self.path = path
    }

    public var id: String { name }
}

public struct BridgeRuntimeInfo: Codable, Sendable, Equatable {
    public let rootPath: String
    public let godotVersion: String
    public let dotnetVersion: String
    public let spineVersion: String
    public let fmodVersion: String
    public let fmodMode: String
    public let godotTemplateAppPath: String
    public let dotnetRuntimeDirPath: String
    public let godotSharpDllPath: String
    public let spineFrameworkPath: String?
    public let fmodFrameworkPath: String?
    public let fmodDylibPaths: [String]
    public let sentryStubDylibPath: String?
    public let sentryDepDylibPath: String?
    public let steamApiDylibPath: String?
    public let bridgeDllPath: String?
    public let components: [BridgeComponentState]

    public init(
        rootPath: String,
        godotVersion: String,
        dotnetVersion: String,
        spineVersion: String,
        fmodVersion: String,
        fmodMode: String,
        godotTemplateAppPath: String,
        dotnetRuntimeDirPath: String,
        godotSharpDllPath: String,
        spineFrameworkPath: String?,
        fmodFrameworkPath: String?,
        fmodDylibPaths: [String],
        sentryStubDylibPath: String?,
        sentryDepDylibPath: String?,
        steamApiDylibPath: String? = nil,
        bridgeDllPath: String?,
        components: [BridgeComponentState]
    ) {
        self.rootPath = rootPath
        self.godotVersion = godotVersion
        self.dotnetVersion = dotnetVersion
        self.spineVersion = spineVersion
        self.fmodVersion = fmodVersion
        self.fmodMode = fmodMode
        self.godotTemplateAppPath = godotTemplateAppPath
        self.dotnetRuntimeDirPath = dotnetRuntimeDirPath
        self.godotSharpDllPath = godotSharpDllPath
        self.spineFrameworkPath = spineFrameworkPath
        self.fmodFrameworkPath = fmodFrameworkPath
        self.fmodDylibPaths = fmodDylibPaths
        self.sentryStubDylibPath = sentryStubDylibPath
        self.sentryDepDylibPath = sentryDepDylibPath
        self.steamApiDylibPath = steamApiDylibPath
        self.bridgeDllPath = bridgeDllPath
        self.components = components
    }

    public var isLaunchReady: Bool {
        !components.isEmpty && components.allSatisfy { $0.isReady || $0.isOptional }
    }
}

public enum ModDeployTarget: String, Codable, Sendable, CaseIterable, Identifiable {
    case both = "both"
    case userDataOnly = "user_data"
    case bundleOnly = "bundle"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .both: return "同时同步到应用支持目录与 Staged 包内（推荐）"
        case .userDataOnly: return "仅 ~/Library/Application Support/SlayTheSpire2/mods"
        case .bundleOnly: return "仅 Staged .app/Contents/MacOS/mods"
        }
    }
}

public struct LaunchConfiguration: Codable, Sendable, Equatable {
    public var selectedPayloadID: String?
    public var payloads: [WindowsPayloadInfo]
    public var bridgeRuntimeCustomPath: String?
    public var customSteamApiDylibPath: String?
    public var renderingDriver: RenderingDriver
    public var enableMods: Bool
    public var modDeployTarget: ModDeployTarget
    public var writeSteamAppIDFile: Bool
    public var enableFastMultiplayer: Bool
    public var enableInGameOverlay: Bool
    public var enableVerboseLogging: Bool
    public var disableDotNetWriteXorExecute: Bool
    public var customArguments: String

    public init(
        selectedPayloadID: String? = nil,
        payloads: [WindowsPayloadInfo] = [],
        bridgeRuntimeCustomPath: String? = nil,
        customSteamApiDylibPath: String? = nil,
        renderingDriver: RenderingDriver = .auto,
        enableMods: Bool = true,
        modDeployTarget: ModDeployTarget = .both,
        writeSteamAppIDFile: Bool = true,
        enableFastMultiplayer: Bool = false,
        enableInGameOverlay: Bool = true,
        enableVerboseLogging: Bool = false,
        disableDotNetWriteXorExecute: Bool = false,
        customArguments: String = ""
    ) {
        self.selectedPayloadID = selectedPayloadID
        self.payloads = payloads
        self.bridgeRuntimeCustomPath = bridgeRuntimeCustomPath
        self.customSteamApiDylibPath = customSteamApiDylibPath
        self.renderingDriver = renderingDriver
        self.enableMods = enableMods
        self.modDeployTarget = modDeployTarget
        self.writeSteamAppIDFile = writeSteamAppIDFile
        self.enableFastMultiplayer = enableFastMultiplayer
        self.enableInGameOverlay = enableInGameOverlay
        self.enableVerboseLogging = enableVerboseLogging
        self.disableDotNetWriteXorExecute = disableDotNetWriteXorExecute
        self.customArguments = customArguments
    }

    private enum CodingKeys: String, CodingKey {
        case selectedPayloadID
        case payloads
        case bridgeRuntimeCustomPath
        case customSteamApiDylibPath
        case renderingDriver
        case enableMods
        case modDeployTarget
        case writeSteamAppIDFile
        case enableFastMultiplayer
        case enableInGameOverlay
        case enableVerboseLogging
        case disableDotNetWriteXorExecute
        case customArguments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.selectedPayloadID = try container.decodeIfPresent(String.self, forKey: .selectedPayloadID)
        self.payloads = try container.decodeIfPresent([WindowsPayloadInfo].self, forKey: .payloads) ?? []
        self.bridgeRuntimeCustomPath = try container.decodeIfPresent(String.self, forKey: .bridgeRuntimeCustomPath)
        self.customSteamApiDylibPath = try container.decodeIfPresent(String.self, forKey: .customSteamApiDylibPath)
        self.renderingDriver = try container.decodeIfPresent(RenderingDriver.self, forKey: .renderingDriver) ?? .auto
        self.enableMods = try container.decodeIfPresent(Bool.self, forKey: .enableMods) ?? true
        self.modDeployTarget = try container.decodeIfPresent(ModDeployTarget.self, forKey: .modDeployTarget) ?? .both
        self.writeSteamAppIDFile = try container.decodeIfPresent(Bool.self, forKey: .writeSteamAppIDFile) ?? true
        self.enableFastMultiplayer = try container.decodeIfPresent(Bool.self, forKey: .enableFastMultiplayer) ?? false
        self.enableInGameOverlay = try container.decodeIfPresent(Bool.self, forKey: .enableInGameOverlay) ?? true
        self.enableVerboseLogging = try container.decodeIfPresent(Bool.self, forKey: .enableVerboseLogging) ?? false
        self.disableDotNetWriteXorExecute = try container.decodeIfPresent(Bool.self, forKey: .disableDotNetWriteXorExecute) ?? false
        self.customArguments = try container.decodeIfPresent(String.self, forKey: .customArguments) ?? ""
    }

    public var selectedPayload: WindowsPayloadInfo? {
        guard let selectedPayloadID else { return payloads.first }
        return payloads.first(where: { $0.id == selectedPayloadID }) ?? payloads.first
    }

    public func resolvedLaunchArguments() -> [String] {
        var args: [String] = []
        if let driverCLI = renderingDriver.cliValue {
            args.append(contentsOf: ["--rendering-driver", driverCLI])
        }
        if enableVerboseLogging {
            args.append("--verbose")
        }
        if enableFastMultiplayer {
            args.append("--fastmp")
        }
        let extra = customArguments
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        args.append(contentsOf: extra)
        return args
    }
}

public struct StagingReport: Codable, Sendable, Equatable {
    public let stagedAppPath: String
    public let stagedExecutablePath: String
    public let windowsPayloadID: String
    public let windowsSts2Sha256: String
    public let targetPckPath: String
    public let copiedManagedDlls: [String]
    public let preservedMacNativeCount: Int
    public let deployedModIDs: [String]
    public let wroteSteamAppID: Bool
    public let didAdHocSign: Bool
    public let steamApiLinked: Bool
    public let bridgeDllInjected: Bool
    public let fmodMode: String
    public let warnings: [String]
    public let stagedAt: Date

    public init(
        stagedAppPath: String,
        stagedExecutablePath: String,
        windowsPayloadID: String,
        windowsSts2Sha256: String,
        targetPckPath: String,
        copiedManagedDlls: [String],
        preservedMacNativeCount: Int,
        deployedModIDs: [String],
        wroteSteamAppID: Bool,
        didAdHocSign: Bool,
        steamApiLinked: Bool = false,
        bridgeDllInjected: Bool = false,
        fmodMode: String = "unknown",
        warnings: [String],
        stagedAt: Date = Date()
    ) {
        self.stagedAppPath = stagedAppPath
        self.stagedExecutablePath = stagedExecutablePath
        self.windowsPayloadID = windowsPayloadID
        self.windowsSts2Sha256 = windowsSts2Sha256
        self.targetPckPath = targetPckPath
        self.copiedManagedDlls = copiedManagedDlls
        self.preservedMacNativeCount = preservedMacNativeCount
        self.deployedModIDs = deployedModIDs
        self.wroteSteamAppID = wroteSteamAppID
        self.didAdHocSign = didAdHocSign
        self.steamApiLinked = steamApiLinked
        self.bridgeDllInjected = bridgeDllInjected
        self.fmodMode = fmodMode
        self.warnings = warnings
        self.stagedAt = stagedAt
    }

    private enum CodingKeys: String, CodingKey {
        case stagedAppPath
        case stagedExecutablePath
        case windowsPayloadID
        case windowsSts2Sha256
        case targetPckPath
        case copiedManagedDlls
        case preservedMacNativeCount
        case deployedModIDs
        case wroteSteamAppID
        case didAdHocSign
        case steamApiLinked
        case bridgeDllInjected
        case fmodMode
        case warnings
        case stagedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stagedAppPath = try container.decode(String.self, forKey: .stagedAppPath)
        self.stagedExecutablePath = try container.decode(String.self, forKey: .stagedExecutablePath)
        self.windowsPayloadID = try container.decode(String.self, forKey: .windowsPayloadID)
        self.windowsSts2Sha256 = try container.decode(String.self, forKey: .windowsSts2Sha256)
        self.targetPckPath = try container.decode(String.self, forKey: .targetPckPath)
        self.copiedManagedDlls = try container.decode([String].self, forKey: .copiedManagedDlls)
        self.preservedMacNativeCount = try container.decode(Int.self, forKey: .preservedMacNativeCount)
        self.deployedModIDs = try container.decode([String].self, forKey: .deployedModIDs)
        self.wroteSteamAppID = try container.decode(Bool.self, forKey: .wroteSteamAppID)
        self.didAdHocSign = try container.decode(Bool.self, forKey: .didAdHocSign)
        self.steamApiLinked = try container.decodeIfPresent(Bool.self, forKey: .steamApiLinked) ?? false
        self.bridgeDllInjected = try container.decodeIfPresent(Bool.self, forKey: .bridgeDllInjected) ?? false
        self.fmodMode = try container.decodeIfPresent(String.self, forKey: .fmodMode) ?? "unknown"
        self.warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
        self.stagedAt = try container.decodeIfPresent(Date.self, forKey: .stagedAt) ?? Date()
    }
}

public struct ModManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let author: String?
    public let description: String?
    public let dependencies: [String]
    public let gameVersion: String?

    public init(
        id: String,
        name: String,
        version: String,
        author: String? = nil,
        description: String? = nil,
        dependencies: [String] = [],
        gameVersion: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.author = author
        self.description = description
        self.dependencies = dependencies
        self.gameVersion = gameVersion
    }
}

public struct ModItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let folderName: String
    public let folderPath: String
    public let manifest: ModManifest?
    public let dllFiles: [String]
    public let pckFiles: [String]
    public var isEnabled: Bool
    public var loadOrder: Int

    public init(
        id: String,
        folderName: String,
        folderPath: String,
        manifest: ModManifest?,
        dllFiles: [String],
        pckFiles: [String],
        isEnabled: Bool,
        loadOrder: Int
    ) {
        self.id = id
        self.folderName = folderName
        self.folderPath = folderPath
        self.manifest = manifest
        self.dllFiles = dllFiles
        self.pckFiles = pckFiles
        self.isEnabled = isEnabled
        self.loadOrder = loadOrder
    }

    public var displayName: String {
        manifest?.name ?? folderName
    }

    public var versionText: String {
        manifest?.version ?? "未知版本"
    }
}

public enum ValidationSeverity: String, Codable, Sendable, Equatable {
    case warning
    case error
}

public struct ModValidationIssue: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let modID: String
    public let severity: ValidationSeverity
    public let message: String
    public let recoveryHint: String

    public init(
        modID: String,
        severity: ValidationSeverity,
        message: String,
        recoveryHint: String
    ) {
        self.id = "\(modID)-\(severity.rawValue)-\(message)"
        self.modID = modID
        self.severity = severity
        self.message = message
        self.recoveryHint = recoveryHint
    }
}

public enum SaveBucket: String, Codable, Sendable, CaseIterable, Identifiable {
    case vanilla
    case modded

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vanilla: return "普通存档"
        case .modded: return "MOD 存档"
        }
    }
}

public struct SaveBucketSummary: Codable, Sendable, Equatable {
    public let bucket: SaveBucket
    public let rootPath: String
    public let exists: Bool
    public let fileCount: Int
    public let totalBytes: Int64
    public let lastModified: Date?
    public let profileSlotsPresent: [String]

    public init(
        bucket: SaveBucket,
        rootPath: String,
        exists: Bool,
        fileCount: Int,
        totalBytes: Int64,
        lastModified: Date?,
        profileSlotsPresent: [String]
    ) {
        self.bucket = bucket
        self.rootPath = rootPath
        self.exists = exists
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.lastModified = lastModified
        self.profileSlotsPresent = profileSlotsPresent
    }
}

public struct SaveAccountSlot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let namespaceName: String
    public let accountID: String
    public let accountRootPath: String
    public let vanilla: SaveBucketSummary
    public let modded: SaveBucketSummary

    public init(
        namespaceName: String,
        accountID: String,
        accountRootPath: String,
        vanilla: SaveBucketSummary,
        modded: SaveBucketSummary
    ) {
        self.id = "\(namespaceName)/\(accountID)"
        self.namespaceName = namespaceName
        self.accountID = accountID
        self.accountRootPath = accountRootPath
        self.vanilla = vanilla
        self.modded = modded
    }
}

public struct SaveSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let accountSlotID: String
    public let bucket: SaveBucket
    public let note: String
    public let createdAt: Date
    public let archiveDirectoryPath: String
    public let fileCount: Int

    public init(
        id: String,
        accountSlotID: String,
        bucket: SaveBucket,
        note: String,
        createdAt: Date,
        archiveDirectoryPath: String,
        fileCount: Int
    ) {
        self.id = id
        self.accountSlotID = accountSlotID
        self.bucket = bucket
        self.note = note
        self.createdAt = createdAt
        self.archiveDirectoryPath = archiveDirectoryPath
        self.fileCount = fileCount
    }
}

public enum LogLevel: String, Codable, Sendable, CaseIterable {
    case debug
    case info
    case warning
    case error

    public var label: String {
        rawValue.uppercased()
    }
}

public enum LogStreamSource: String, Codable, Sendable {
    case launcher
    case stdout
    case stderr
}

public struct LogEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let source: LogStreamSource
    public let level: LogLevel
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        source: LogStreamSource,
        level: LogLevel,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.message = message
    }
}

public struct DiagnosticFinding: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let severity: ValidationSeverity
    public let category: String
    public let title: String
    public let evidence: String
    public let recoveryAction: String

    public init(
        id: String,
        severity: ValidationSeverity,
        category: String,
        title: String,
        evidence: String,
        recoveryAction: String
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.title = title
        self.evidence = evidence
        self.recoveryAction = recoveryAction
    }
}
