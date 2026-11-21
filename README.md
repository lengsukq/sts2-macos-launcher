# STS2 Mac Launcher

基于**纯自建 macOS 桥接运行时（Bridge Runtime）**的《杀戮尖塔2》（Slay the Spire 2）Apple Silicon 原生启动器，参照开源社区跨端启动器（`Ekyso/StS2-Launcher` / `Sts2MobileLauncher`）的分层兼容思路，使用 **Swift 6 + SwiftUI + .NET 9 Harmony Startup Hook + C Native Stubs** 构建。

> **免责声明与合规说明（Disclaimer & Legal Notice）**：
> - 本项目为**非官方开源社区工具**，与 **Mega Crit Games** 没有任何隶属或合作关系。*Slay the Spire 2*（《杀戮尖塔2》）为 Mega Crit Games 的商标。
> - **仅限正版用户**：本启动器**不包含任何《杀戮尖塔2》商业游戏资源、游戏程序集、Spine/FMOD/Steamworks 商业二进制或用户存档**，亦**不提供任何绕过 Steam 授权校验或 DRM 的功能**。用户必须自行合法拥有正版 Steam 游戏并由本机正版 Steam 客户端完成验证。
> - **第三方商业库分发边界**：所有运行时组装均在用户本机目录（`~/Library/Application Support/STS2MacLauncher/`）完成，绝不提交进 Git；请勿公开二次分发包含 FMOD / Spine / Steamworks 商业二进制的独立打包产物（详见 [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md)）。

## 6 大桥接组件与许可证说明

自建 `bridge-runtime` 由以下 6 大组件组成（通过 `scripts/setup-bridge-runtime.sh` 或应用内一键安装至用户数据目录）：

| # | 组件 | 上游来源 / 仓库目录 | 核心作用 | 许可证说明 |
| --- | --- | --- | --- | --- |
| 1 | **Godot 4.5.1 Mono** | 官方 `godotengine/godot` (`4.5.1-stable` Mono 导出模板 `macos_template.app` + NuGet `GodotSharp 4.5.1`) | 提供 Apple Silicon (`arm64`) 原生引擎宿主与 Godot C# 绑定 | MIT License |
| 2 | **.NET 9 osx-arm64** | Microsoft .NET 9 SDK (`dotnet@9` self-contained `osx-arm64` CoreCLR + BCL + `System.IO.Hashing 9.0.0`) | 提供原生 macOS `libhostfxr.dylib` / `libcoreclr.dylib` / `libclrjit.dylib` 与纯净 BCL | MIT License |
| 3 | **Spine 4.2** | Esoteric Software `spine-godot` (`4.2-4.5.1-stable` macOS GDExtension) | 提供 `libspine_godot.macos.template_release.framework` 骨骼动画渲染 | Spine Runtimes License（仅限配合授权游戏/项目运行） |
| 4 | **FMOD 2.03.06** | `utopia-rise/fmod-gdextension` (`6.1.0-4.5.0`) + FMOD Engine（缺失商业库时降级 `libGodotFmod.stub.dylib`） | 提供 `libGodotFmod`、`libfmod.dylib`、`libfmodstudio.dylib`（**完整音频**或**静音兜底**） | GDExtension 封装：MIT License；FMOD Engine 动态库：Firelight Technologies 商业许可（自研静音 stub 同仓库源码） |
| 5 | **Native Bridges** | `bridge/native-stubs/`（`sentry_stub.c` / `sentry_dep_stub.c` / `fmod_stub.c` / `hostfxr_bridge.c`） | 本地编译 arm64 `libsentry.macos.release.dylib`、`libSentry.dylib`、`libGodotFmod.stub.dylib` 及嵌入式 CoreCLR 钩子桥 `libhostfxr_bridge.dylib` | MIT License（本项目自研 C 源码） |
| 6 | **STS2MacBridge** | `bridge/STS2MacBridge/`（`.NET 9` 类库：`StartupHook` + `PlatformPatches` + `InGameOverlayManager`） | 由 `libhostfxr_bridge` 在游戏加载前触发 `InitializeUnmanaged`，将 Windows `steam_api64` 映射至用户本机官方 macOS `libsteam_api.dylib`、拦截 Sentry/DXGI、支持外置 Mod 扫描与游戏内性能悬浮窗 (F9) | MIT License（本项目自研 C# 源码；依赖游戏内附 `0Harmony.dll`） |

## 核心功能

- **纯自建 BridgeRuntime 架构**：
  - `BridgeRuntimeInspector` 读取 `bridge-runtime-manifest.json`（缺失时按约定子目录扫描），校验 6 大组件可用性与 `arm64` 架构。
  - `WindowsPayloadInspector` 支持目录与 `.zip` 导入（含解压前头/中/尾抽样全零损坏校验），提取 `.pck`、`sts2.dll` SHA-256 指纹与纯托管依赖清单。
  - `RuntimeStager` 通过 APFS 克隆生成隔离 `Staged SlayTheSpire2.app`，覆写 `.pck` 与纯托管 DLL，自动将纯 IL `PE32+` `AMD64 (0x8664)` 程序集头修补为 `ARM64 (0xAA64)` 供 macOS CoreCLR 加载，生成 `osx-arm64` `sts2.runtimeconfig.json` 并净化 `sts2.deps.json`，部署 GDExtension 与 Native Stubs，清理 `com.apple.quarantine` 并执行 ad-hoc `codesign`。
- **原生 SwiftUI 桌面端 (`STS2LauncherApp`)**：
  - 遵循 Apple HIG 的 `NavigationSplitView` 五视图结构：概览与启动、游戏包与运行时、Mod 管理、存档与快照、日志与诊断，以及标准 macOS 设置窗口（`⌘,`）。
  - 支持应用内**一键安装/重建桥接运行时**并实时流式查看构建日志、切换图形渲染驱动（自动 / Metal / Vulkan / OpenGL3）以及配置官方 macOS `libsteam_api.dylib` 路径。
- **Mod 管理与存档安全隔离**：
  - `ModRepository` 扫描 `mod_manifest.json` / `.dll` / `.pck`，提供加载排序、缺失依赖与循环依赖检测。
  - `SaveManager` 严格隔离普通存档与 `modded/` 存档，支持时间戳快照备份、安全恢复与带前置备份的显式互转。
- **实时进程监控与崩溃诊断 (`GameProcessRunner` / `CrashDiagnostics`)**：
  - 启动时注入 `DOTNET_STARTUP_HOOKS`、`STS2_BRIDGE_HUD`、`STS2_BRIDGE_STEAM_DYLIB`、`STS2_BRIDGE_MODS_DIR`，流式落盘日志并自动分析签名失效、Startup Hook、Vortice/DXGI、`deps.json`、Spine/FMOD 等异常。
- **游戏内性能与快捷悬浮窗 (`InGameOverlayManager`)**：
  - 基于纯 `GodotSharp` 组合节点挂载于最高 `CanvasLayer`，无额外 GC 开销；默认以半透明深色紧凑胶囊显示 **FPS、帧时间、CPU 占用率与漏帧/卡顿提示**，支持自由拖动与位置记忆。
  - 展开面板提供 **1% Low FPS、最大卡顿峰值、漏帧/重卡统计、CPU 核数占用、进程内存与 .NET 堆、渲染器与分辨率**，以及**重置统计、全屏/窗口切换、隐藏、两段防误触快速结束游戏/强退**。
  - 快捷键：`F9` 一键显隐，`Shift+F9` 展开/收起；可在启动器概览或设置中随时开关。

## 一键搭建与验证步骤

### 前置依赖
- macOS 14.0+（Apple Silicon `arm64`）
- Xcode Command Line Tools（提供 `clang`、`codesign`、`swift`）
- Homebrew（脚本会自动检测并按需安装 `dotnet@9`）

### 1. 一键搭建自建桥接运行时
在项目根目录运行脚本（也可直接在 SwiftUI 应用「游戏包与运行时」页面点击**一键安装/重建桥接运行时**）：

```bash
./scripts/setup-bridge-runtime.sh
# 可选参数：
#   --output-dir <path>   指定桥接运行时输出目录
#   --win-zip <path>      指定 Windows 游戏包 zip 用于提取 STS2MacBridge 编译引用
#   --force               忽略缓存强制重新下载与构建
```

脚本会在 `~/Library/Application Support/STS2MacLauncher/bridge-runtime/` 下组装全部 6 大组件并生成 `bridge-runtime-manifest.json`。

### 2. 编译与运行单元测试
```bash
swift build
swift test
```

### 3. CLI 端到端验证 (`sts2-poc`)
```bash
# 1) 检查自建 BridgeRuntime 6 大组件就绪状态
swift run sts2-poc check-bridge

# 2) 检查或导入 Windows 游戏目录 / .zip
swift run sts2-poc inspect-win "/path/to/SlayTheSpire2-Windows.zip"

# 3) 合成隔离的 Staged .app 沙盒（不修改任何源文件）
swift run sts2-poc stage --win "/path/to/imported-windows-payload"

# 4) 启动游戏并实时输出日志与诊断（可选 --steam-api <libsteam_api.dylib>、--driver auto|metal|vulkan|opengl3、--no-mods、--no-hud、--fastmp、--verbose）
swift run sts2-poc launch --win "/path/to/imported-windows-payload"
```

### 4. 运行与打包 SwiftUI 桌面端
```bash
# 开发态直接启动桌面端
swift run STS2LauncherApp

# 轻量壳打包（仅 2.6 MB，推荐用于公开发布；使用本机 ~/Library/Application Support/STS2MacLauncher/bridge-runtime）
./scripts/bundle-app.sh

# 个人本地独立打包（内置本机精简 arm64 运行时，仅限个人自用，请勿公开再分发 FMOD/Spine 商业库）
./scripts/bundle-standalone.sh
open dist/STS2MacLauncher.app
```
