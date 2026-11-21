import Foundation

public enum GameConstants {
    public static let steamAppID = "2868840"
    public static let gameDisplayName = "Slay the Spire 2"
    public static let appBundleName = "SlayTheSpire2.app"
    public static let stagedExecutableName = "SlayTheSpire2"
    public static let stagedBundleIdentifier = "io.github.lengsukq.sts2-mac-bridge"
    public static let targetPckFileName = "SlayTheSpire2.pck"
    public static let macDataDirectoryName = "data_sts2_macos_arm64"
    public static let coreAssemblyFileName = "sts2.dll"
    public static let bridgeAssemblyFileName = "STS2MacBridge.dll"
    public static let bridgeManifestFileName = "bridge-runtime-manifest.json"
    public static let steamAppIDFileName = "steam_appid.txt"
    public static let modManifestFileName = "mod_manifest.json"
    public static let profileSaveFileName = "profile.save"
    public static let moddedFolderName = "modded"
    public static let modsFolderName = "mods"
    public static let stagingManifestFileName = "sts2_launcher_staging.json"
    public static let defaultProfileSlotNames = ["profile1", "profile2", "profile3"]
}

public struct LauncherPaths: Sendable, Equatable {
    public let baseDirectory: URL
    public let gameUserDataDirectory: URL
    public let bundledBridgeRuntimeDirectory: URL?

    public init(
        baseDirectory: URL = LauncherPaths.defaultBaseDirectory(),
        gameUserDataDirectory: URL = LauncherPaths.defaultGameUserDataDirectory(),
        bundledBridgeRuntimeDirectory: URL? = LauncherPaths.defaultBundledBridgeRuntimeDirectory()
    ) {
        self.baseDirectory = baseDirectory
        self.gameUserDataDirectory = gameUserDataDirectory
        self.bundledBridgeRuntimeDirectory = bundledBridgeRuntimeDirectory
    }

    public static func defaultBundledBridgeRuntimeDirectory() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else {
            return nil
        }
        let candidate = resourceURL.appendingPathComponent("bridge-runtime", isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    public static func defaultBaseDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("STS2MacLauncher", isDirectory: true)
    }

    public static func defaultGameUserDataDirectory() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport.appendingPathComponent("SlayTheSpire2", isDirectory: true)
    }

    public var configFile: URL {
        baseDirectory.appendingPathComponent("launcher-config.json")
    }

    public var bridgeRuntimeDirectory: URL {
        baseDirectory.appendingPathComponent("bridge-runtime", isDirectory: true)
    }

    public var bridgeManifestFile: URL {
        bridgeRuntimeDirectory.appendingPathComponent(GameConstants.bridgeManifestFileName)
    }

    public var payloadsDirectory: URL {
        baseDirectory.appendingPathComponent("payloads", isDirectory: true)
    }

    public var modsLibraryDirectory: URL {
        baseDirectory.appendingPathComponent("mods-library", isDirectory: true)
    }

    public var modsConfigFile: URL {
        baseDirectory.appendingPathComponent("mods-config.json")
    }

    public var stagedDirectory: URL {
        baseDirectory.appendingPathComponent("staged", isDirectory: true)
    }

    public var stagedAppBundle: URL {
        stagedDirectory.appendingPathComponent(GameConstants.appBundleName, isDirectory: true)
    }

    public var snapshotsDirectory: URL {
        baseDirectory.appendingPathComponent("snapshots", isDirectory: true)
    }

    public var logsDirectory: URL {
        baseDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    public var gameUserModsDirectory: URL {
        gameUserDataDirectory.appendingPathComponent(GameConstants.modsFolderName, isDirectory: true)
    }

    public func ensureDirectoriesExist() throws {
        let fm = FileManager.default
        let directories = [
            baseDirectory,
            bridgeRuntimeDirectory,
            payloadsDirectory,
            modsLibraryDirectory,
            stagedDirectory,
            snapshotsDirectory,
            logsDirectory
        ]
        for dir in directories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
