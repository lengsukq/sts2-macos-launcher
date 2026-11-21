# STS2 Mac Launcher

基于**纯自建 macOS 桥接运行时（Bridge Runtime）**的《杀戮尖塔2》（Slay the Spire 2）Apple Silicon (`arm64`) 原生启动器，参照开源社区跨端启动器（`Ekyso/StS2-Launcher` / `Sts2MobileLauncher`）的分层兼容思路，使用 **Swift 6 + SwiftUI + .NET 9 Harmony Startup Hook + C Native Bridges** 构建。

> **免责声明与合规说明（Disclaimer & Legal Notice）**：
> - **非官方开源工具**：本项目为独立开源社区兼容工具，与 **Mega Crit Games** 没有任何隶属、授权或合作关系。*Slay the Spire 2*（《杀戮尖塔2》）为 Mega Crit Games 的商标。
> - **不提供游戏文件、不绕过任何 DRM**：本启动器**不包含任何《杀戮尖塔2》商业游戏资源、游戏程序集（`sts2.dll`）、用户存档或第三方商业动态库**，亦**不提供任何绕过 Steam 授权校验或 DRM 保护的功能**。
> - **自主导入与用户责任**：本启动器允许用户**自主导入本机已有的 Windows 版游戏目录或 `.zip` 压缩包**（不绑定特定商店下载器）。用户必须自行确保其所导入游戏文件来自合法授权渠道（例如 Steam 或其他合法发行平台）并遵守对应平台及游戏最终用户许可协议（EULA）；因游戏文件来源引发的一切法律与合规责任均由用户自行承担，与本项目及作者无关。
> - **第三方商业库分发边界**：公开发行版（`scripts/bundle-mit-release.sh`）**仅内置 100% MIT 开源核心组件**；Spine 4.2 与 FMOD 2.03.06 扩展绝不提交进 Git 亦不内置在公开安装包中，而是由用户端应用首次运行时直接从官方上游源下载至用户本机目录（详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)）。

## 普通用户开箱使用（免 Homebrew / Xcode / .NET）

公开版 DMG 采用 **「内置 MIT 四件套核心 + 应用内自动下载上游扩展」** 架构，普通 Apple Silicon Mac 用户无需安装任何开发工具：

1. **安装启动器**：下载公开版 DMG，将 `STS2MacLauncher.app` 拖入「应用程序」，若遇未公证拦截则在终端执行一次 `xattr -dr com.apple.quarantine /Applications/STS2MacLauncher.app`。
2. **一键下载上游扩展**：打开启动器，在首页点击 **「一键下载扩展」**，应用使用 macOS 原生 `URLSession` 直接从官方上游源下载 Spine 4.2 与 FMOD 2.03.06 至 `~/Library/Application Support/STS2MacLauncher/bridge-runtime/gdextensions/`（自动过滤非 macOS 冗余文件并完成 `arm64` 校验与本地签名）。
3. **自主导入 Windows 游戏包并启动**：将你本机合法持有的 Windows 版《杀戮尖塔2》文件夹或 `.zip` 压缩包（含 `SlayTheSpire2.pck` 与 `data_sts2_windows_x86_64/`）直接拖入窗口，点击 **「启动游戏」** 即可原生运行。

## 6 大桥接组件与分层来源

`BridgeRuntimeInspector` 采用**双层叠加机制**：优先读取用户目录（`~/Library/Application Support/STS2MacLauncher/bridge-runtime/`），缺失项自动回退至 `.app` 内置 MIT 核心目录，实现开源核心与上游商业扩展的彻底解耦：

| # | 组件 | 分发方式 | 上游来源 / 仓库目录 | 核心作用 | 许可证说明 |
| --- | --- | --- | --- | --- | --- |
| 1 | **Godot 4.5.1 Mono** | 内置在公开 MIT 包 | `godotengine/godot`（`4.5.1-stable` Mono macOS 导出模板 + NuGet `GodotSharp 4.5.1`） | 提供 Apple Silicon (`arm64`) 原生引擎宿主与 Godot C# 绑定 | MIT License |
| 2 | **.NET 9 osx-arm64** | 内置在公开 MIT 包 | Microsoft .NET 9 Runtime（`osx-arm64` CoreCLR + BCL + `System.IO.Hashing 9.0.0`） | 提供原生 macOS `libhostfxr.dylib` / `libcoreclr.dylib` / `libclrjit.dylib` 与纯净 BCL | MIT License |
| 3 | **Native Bridges** | 内置在公开 MIT 包 | `bridge/native-stubs/`（`hostfxr_bridge.c` / `sentry_stub.c` / `sentry_dep_stub.c` / `fmod_stub.c`） | 提供嵌入式 CoreCLR 钩子垫片 `libhostfxr_bridge.dylib`、Sentry 空壳与 FMOD 静音兜底 | MIT License（本项目自研 C 源码） |
| 4 | **STS2MacBridge** | 内置在公开 MIT 包 | `bridge/STS2MacBridge/`（纯 MIT `.NET 9` 类库，仅编译引用 NuGet `GodotSharp` 与 `Lib.Harmony`） | 启动前注入 Harmony 跨平台兼容补丁（拦截 Sentry / Vortice DXGI、映射用户提供的 macOS `libsteam_api.dylib`、外置 Mod 扫描与游戏内性能悬浮窗 F9） | MIT License（本项目自研 C# 源码） |
| 5 | **Spine 4.2** | 应用内直连上游下载 | Esoteric Software `spine-godot` (`4.2-4.5.1-stable` macOS GDExtension) | 提供 `libspine_godot.macos.template_release.framework` 骨骼动画渲染 | Spine Runtimes License（仅限配合授权游戏/项目运行） |
| 6 | **FMOD 2.03.06** | 应用内直连上游下载 | `utopia-rise/fmod-gdextension` (`6.1.0-4.5.0`) + FMOD Engine（缺失时降级自研静音 stub） | 提供 `libGodotFmod`、`libfmod.dylib`、`libfmodstudio.dylib`（完整音频） | 封装层：MIT License；FMOD Engine：Firelight Technologies 商业许可 |

## 核心功能

- **纯自建双层 BridgeRuntime 架构**：
  - `BridgeRuntimeInspector` 使用纯 Swift 解析 Mach-O / Fat 二进制头（无需 Xcode CLT / `lipo`），支持用户层与内置 MIT 层的双层组件合并校验。
  - `BridgeExtensionDownloader` 使用 macOS 原生 `URLSessionDownloadDelegate`、`ditto`、`xattr`、`codesign` 零开发工具拉取并校验 Spine 4.2 与 FMOD 2.03.06，自动剔除非 macOS 文件。
  - `WindowsPayloadInspector` 支持自主导入任意本地 Windows 目录与 `.zip` 压缩包（含解压前头/中/尾抽样全零损坏校验），提取 `.pck`、`sts2.dll` SHA-256 指纹与纯托管依赖清单。
  - `RuntimeStager` 通过 APFS 克隆生成隔离 `Staged SlayTheSpire2.app`，覆写 `.pck` 与纯托管 DLL，自动将纯 IL `PE32+` `AMD64 (0x8664)` 程序集头修补为 `ARM64 (0xAA64)`，生成 `osx-arm64` `sts2.runtimeconfig.json` 与净化版 `sts2.deps.json`，写入性能优化 `override.cfg` 并执行 ad-hoc `codesign`。
- **原生 SwiftUI 桌面端 (`STS2LauncherApp`)**：
  - 遵循 Apple HIG 的 `NavigationSplitView` 五视图结构：概览与启动、游戏包与运行时、Mod 管理、存档与快照、日志与诊断，以及标准 macOS 设置窗口（`⌘,`）。
  - 支持应用内一键下载官方上游扩展（实时进度条）、拖放自主导入 Windows 游戏包、切换图形渲染驱动（自动 / Metal / Vulkan / OpenGL3）以及按需配置本机 macOS `libsteam_api.dylib` 路径。
- **Mod 管理与存档安全隔离**：
  - `ModRepository` 扫描 `mod_manifest.json` / `.dll` / `.pck`，提供加载排序、缺失依赖与循环依赖检测。
  - `SaveManager` 严格隔离普通存档与 `modded/` 存档，支持时间戳快照备份、安全恢复与带前置备份的显式互转。
- **实时进程监控与崩溃诊断 (`GameProcessRunner` / `CrashDiagnostics`)**：
  - 启动时注入 `DOTNET_STARTUP_HOOKS`、`STS2_BRIDGE_HUD`、`STS2_BRIDGE_STEAM_DYLIB`、`STS2_BRIDGE_MODS_DIR`，采用 O(N) 批量日志写入与 UI 节流刷新，自动分析签名失效、Startup Hook、Vortice/DXGI、`deps.json`、Spine/FMOD 等异常。
- **游戏内性能与快捷悬浮窗 (`InGameOverlayManager`)**：
  - 基于纯 `GodotSharp` 组合节点挂载于最高 `CanvasLayer`，无额外 GC 开销；默认以半透明深色紧凑胶囊显示 **FPS、帧时间、CPU 占用率与漏帧/卡顿提示**，支持自由拖动与位置记忆。
  - 展开面板提供 **1% Low FPS、最大卡顿峰值、漏帧/重卡统计、CPU 核数占用、进程内存与 .NET 堆、渲染器与分辨率**，以及**重置统计、全屏/窗口切换、隐藏、两段防误触快速结束游戏/强退**。
  - 快捷键：`F9` 一键显隐，`Shift+F9` 展开/收起；可在启动器概览或设置中随时开关。

## 开发者构建与打包步骤

### 开发者前置依赖（仅源码编译/打包机器需要）
- macOS 14.0+（Apple Silicon `arm64`）
- Xcode Command Line Tools（提供 `clang`、`codesign`、`swift`）
- Homebrew（脚本会自动检测并按需安装 `dotnet@9`）

### 1. 构建本地开发环境桥接运行时
```bash
./scripts/setup-bridge-runtime.sh
# 可选参数：
#   --output-dir <path>   指定桥接运行时输出目录
#   --force               忽略缓存强制重新下载与构建
```

### 2. 编译与运行单元测试
```bash
swift build -Xswiftc -warnings-as-errors
swift test
```

### 3. CLI 端到端工具 (`sts2-poc`)
```bash
# 1) 零开发工具从上游拉取 Spine 4.2 + FMOD 2.03.06 扩展
swift run sts2-poc fetch-extensions

# 2) 检查自建 BridgeRuntime 6 大组件就绪状态
swift run sts2-poc check-bridge

# 3) 检查或导入本地 Windows 游戏目录 / .zip
swift run sts2-poc inspect-win "/path/to/SlayTheSpire2-Windows.zip"

# 4) 合成隔离的 Staged .app 沙盒（不修改任何源文件）
swift run sts2-poc stage --win "/path/to/imported-windows-payload"

# 5) 启动游戏并实时输出日志与诊断（可选 --steam-api <libsteam_api.dylib>、--driver auto|metal|vulkan|opengl3、--no-mods、--no-hud、--fastmp、--verbose）
swift run sts2-poc launch --win "/path/to/imported-windows-payload"
```

### 4. 打包发行产物
```bash
# 推荐：100% MIT 合规公开发行包（仅内置 4 个 MIT 核心，通过强合规校验确保零 Spine/FMOD 商业库/Steamworks）
./scripts/bundle-mit-release.sh
# 产出：dist/STS2MacLauncher-MIT.app 与 dist/STS2MacLauncher-arm64-mit-release.dmg

# 轻量壳打包（仅含 SwiftUI 外壳，使用本机 ~/Library/Application Support/STS2MacLauncher/bridge-runtime）
./scripts/bundle-app.sh

# 个人本地全量打包（内置本机 Spine/FMOD，仅限个人自用，请勿公开再分发）
./scripts/bundle-standalone.sh
```
