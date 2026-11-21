import Foundation

public struct ConfigStore: Sendable {
    public let paths: LauncherPaths

    public init(paths: LauncherPaths = LauncherPaths()) {
        self.paths = paths
    }

    public func load() throws -> LaunchConfiguration {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.configFile.path) else {
            return LaunchConfiguration()
        }

        do {
            let data = try Data(contentsOf: paths.configFile)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(LaunchConfiguration.self, from: data)
        } catch {
            throw LauncherError(
                title: "读取启动器配置失败",
                detail: error.localizedDescription,
                dataSafetyNote: "游戏本体与存档均未受影响，配置文件本身保留在 \(paths.configFile.path)。",
                recoverySuggestionText: "请检查配置文件 JSON 格式，或移走损坏的 launcher-config.json 后重新打开启动器。"
            )
        }
    }

    public func save(_ configuration: LaunchConfiguration) throws {
        try paths.ensureDirectoriesExist()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(configuration)
        try data.write(to: paths.configFile, options: .atomic)
    }
}
