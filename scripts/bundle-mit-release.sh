#!/usr/bin/env bash
# Builds a 100% MIT-licensed public GitHub Release bundle & DMG for Apple Silicon Macs:
#   - Embeds ONLY the 4 MIT-licensed core runtime components:
#       1. Godot 4.5.1-stable Mono macOS template (arm64-thinned release binary)
#       2. .NET 9 osx-arm64 CoreCLR + BCL + GodotSharp.dll + System.IO.Hashing.dll
#       3. Self-written MIT native C bridges (hostfxr_bridge, Sentry no-op, FMOD stub)
#       4. Pure-MIT STS2MacBridge.dll (compiled out-of-tree against MIT NuGet packages)
#   - Explicitly excludes all proprietary / restricted third-party binaries
#     (Spine, FMOD Engine, Steamworks SDK, game assets) and verifies exclusion before signing.
#   - End users launch the app with ZERO developer tools (no Homebrew/Xcode/.NET) and click
#     "一键下载扩展" in-app to fetch official upstream Spine 4.2 & FMOD 2.03.06 directly.
set -euo pipefail

export PATH="/opt/homebrew/opt/dotnet@9/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="STS2MacLauncher"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME-MIT.app"
DMG_PATH="$DIST_DIR/$APP_NAME-arm64-mit-release.dmg"
BRIDGE_SRC="${1:-$HOME/Library/Application Support/STS2MacLauncher/bridge-runtime}"
MANIFEST_SRC="$BRIDGE_SRC/bridge-runtime-manifest.json"

if [ ! -f "$MANIFEST_SRC" ]; then
    echo "ERROR: Local bridge-runtime manifest not found at: $MANIFEST_SRC" >&2
    echo "Run ./scripts/setup-bridge-runtime.sh once on this build machine to populate Godot & .NET 9 MIT core." >&2
    exit 1
fi

WORK_TMP="$(mktemp -d /tmp/sts2-mit-release.XXXXXX)"
cleanup() {
    rm -rf "$WORK_TMP"
}
trap cleanup EXIT

thin_macho_to_arm64() {
    local target="$1"
    if [ ! -f "$target" ]; then
        return 0
    fi
    local archs
    archs="$(lipo -archs "$target" 2>/dev/null || true)"
    if [[ "$archs" == *"arm64"* && "$archs" == *"x86_64"* ]]; then
        local tmp="${target}.arm64.tmp"
        lipo -thin arm64 "$target" -output "$tmp"
        mv -f "$tmp" "$target"
        chmod +x "$target" || true
    fi
}

echo "[mit-release] 1/6 Building release STS2LauncherApp (arm64)..."
cd "$ROOT"
swift build -c release --arch arm64 --product STS2LauncherApp

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/STS2LauncherApp"
if [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: Built executable not found at $BIN_PATH" >&2
    exit 1
fi

echo "[mit-release] 2/6 Building fresh pure-MIT STS2MacBridge.dll & arm64 native bridges..."
if [[ -d "/opt/homebrew/opt/dotnet@9/libexec" ]]; then
    export DOTNET_ROOT="/opt/homebrew/opt/dotnet@9/libexec"
fi
if ! command -v dotnet >/dev/null 2>&1; then
    echo "ERROR: dotnet@9 SDK is required on the build machine to compile pure-MIT STS2MacBridge.dll." >&2
    exit 1
fi

rm -rf "$ROOT/bridge/STS2MacBridge/bin" "$ROOT/bridge/STS2MacBridge/obj"
mkdir -p "$WORK_TMP/bridge-obj" "$WORK_TMP/bridge-out" "$WORK_TMP/stubs"
dotnet build "$ROOT/bridge/STS2MacBridge/STS2MacBridge.csproj" \
    -c Release \
    -p:BaseIntermediateOutputPath="$WORK_TMP/bridge-obj/" \
    -o "$WORK_TMP/bridge-out" \
    -v minimal

"$ROOT/bridge/native-stubs/build-native-stubs.sh" "$WORK_TMP/stubs"

echo "[mit-release] 3/6 Assembling MIT-only app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

for doc in LICENSE THIRD_PARTY_LICENSES.md; do
    if [ -f "$ROOT/$doc" ]; then
        cp "$ROOT/$doc" "$APP_BUNDLE/Contents/Resources/$doc"
    fi
done
if [ -f "$ROOT/assets/AppIcon.icns" ]; then
    cp "$ROOT/assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>杀戮尖塔2启动器</string>
    <key>CFBundleExecutable</key>
    <string>STS2MacLauncher</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.lengsukq.sts2-macos-launcher</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>STS2MacLauncher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSArchitecturePriority</key>
    <array>
        <string>arm64</string>
    </array>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

EMBED_ROOT="$APP_BUNDLE/Contents/Resources/bridge-runtime"
mkdir -p \
    "$EMBED_ROOT/godot-template" \
    "$EMBED_ROOT/dotnet-osx-arm64" \
    "$EMBED_ROOT/stubs" \
    "$EMBED_ROOT/bridge"

eval "$(python3 - "$MANIFEST_SRC" <<'PY'
import json, shlex, sys
with open(sys.argv[1]) as f:
    m = json.load(f)
def emit(k, v):
    print(f"{k}={shlex.quote(str(v or ''))}")
emit("M_GODOT_VER", m.get("godotVersion", "4.5.1-stable"))
emit("M_DOTNET_VER", m.get("dotnetVersion", "9.0"))
emit("M_SPINE_VER", m.get("spineVersion", "4.2"))
emit("M_FMOD_VER", m.get("fmodVersion", "2.03.06"))
emit("M_GODOT_APP", m.get("godotTemplateAppPath", ""))
emit("M_DOTNET_DIR", m.get("dotnetRuntimeDirPath", ""))
PY
)"

if [ ! -d "$M_GODOT_APP" ] || [ ! -d "$M_DOTNET_DIR" ]; then
    echo "ERROR: Missing Godot template or .NET 9 osx-arm64 directory in $BRIDGE_SRC." >&2
    exit 1
fi

# 3a. MIT Component #1: Godot 4.5.1 Mono macOS template (release arm64 only)
cp -R "$M_GODOT_APP" "$EMBED_ROOT/godot-template/macos_template.app"
rm -f "$EMBED_ROOT/godot-template/macos_template.app/Contents/MacOS/"*debug*
for bin in "$EMBED_ROOT/godot-template/macos_template.app/Contents/MacOS/"*; do
    thin_macho_to_arm64 "$bin"
done

# 3b. MIT Component #2: .NET 9 osx-arm64 CoreCLR + BCL + GodotSharp.dll + System.IO.Hashing.dll
cp -R "$M_DOTNET_DIR/." "$EMBED_ROOT/dotnet-osx-arm64/"

# 3c. MIT Component #3: Self-written native arm64 bridges
cp "$WORK_TMP/stubs/libsentry.macos.release.dylib" "$EMBED_ROOT/stubs/"
cp "$WORK_TMP/stubs/libSentry.dylib" "$EMBED_ROOT/stubs/"
cp "$WORK_TMP/stubs/libGodotFmod.stub.dylib" "$EMBED_ROOT/stubs/"
cp "$WORK_TMP/stubs/libhostfxr_bridge.dylib" "$EMBED_ROOT/stubs/"

# 3d. MIT Component #4: Pure-MIT STS2MacBridge.dll
cp "$WORK_TMP/bridge-out/STS2MacBridge.dll" "$EMBED_ROOT/bridge/STS2MacBridge.dll"

# 3e. Portable relative-path manifest (MIT core only; Spine & full FMOD fetched in-app to user dir)
python3 - "$EMBED_ROOT/bridge-runtime-manifest.json" \
    "$M_GODOT_VER" "$M_DOTNET_VER" "$M_SPINE_VER" "$M_FMOD_VER" <<'PY'
import datetime, json, sys
out_path, godot_v, dotnet_v, spine_v, fmod_v = sys.argv[1:6]
manifest = {
    "godotVersion": godot_v,
    "dotnetVersion": dotnet_v,
    "spineVersion": spine_v,
    "fmodVersion": fmod_v,
    "fmodMode": "stub",
    "godotTemplateAppPath": "godot-template/macos_template.app",
    "dotnetRuntimeDirPath": "dotnet-osx-arm64",
    "godotSharpDllPath": "dotnet-osx-arm64/GodotSharp.dll",
    "spineFrameworkPath": None,
    "fmodFrameworkPath": "stubs/libGodotFmod.stub.dylib",
    "fmodDylibPaths": [],
    "sentryStubDylibPath": "stubs/libsentry.macos.release.dylib",
    "sentryDepDylibPath": "stubs/libSentry.dylib",
    "steamApiDylibPath": None,
    "hostfxrBridgeDylibPath": "stubs/libhostfxr_bridge.dylib",
    "bridgeDllPath": "bridge/STS2MacBridge.dll",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "[mit-release] 4/6 Running strict compliance check (zero Spine/FMOD-commercial/Steam/game binaries)..."
VIOLATIONS="$(find "$APP_BUNDLE" \( \
    -iname "*spine*" -o \
    -iname "*steam*" -o \
    -iname "*sts2.dll*" -o \
    -iname "*.pck" -o \
    \( -iname "*fmod*" ! -name "libGodotFmod.stub.dylib" \) \
\) -print)"

if [ -n "$VIOLATIONS" ]; then
    echo "COMPLIANCE ERROR: Forbidden third-party or proprietary files detected inside MIT release bundle:" >&2
    echo "$VIOLATIONS" >&2
    exit 1
fi
echo "[mit-release] Compliance check passed: 0 forbidden binaries inside $APP_BUNDLE."

echo "[mit-release] 5/6 Signing embedded MIT binaries and app bundle (inside-out ad-hoc)..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib" 2>/dev/null
done < <(find "$EMBED_ROOT" -type f -name "*.dylib" -print0)

codesign --force --deep --sign - "$EMBED_ROOT/godot-template/macos_template.app" 2>/dev/null
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null

echo "[mit-release] Verifying codesign integrity..."
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
codesign --verify --deep --strict "$EMBED_ROOT/godot-template/macos_template.app"

echo "[mit-release] 6/6 Creating compressed public MIT-release DMG..."
DMG_STAGE="$WORK_TMP/dmg-stage"
mkdir -p "$DMG_STAGE"

cp -R "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

cat > "$DMG_STAGE/首次打开说明.txt" <<'TXT'
《杀戮尖塔2》macOS 启动器（Apple Silicon 开源公开版 · 免开发工具）
===================================================================

1. 安装：
   将 STS2MacLauncher.app 拖入右侧 Applications（应用程序）文件夹。

2. 首次打开若 macOS 提示“无法验证开发者”或“已损坏”：
   因本应用为开源自签名分发（无 Apple 付费公证证书），请打开「终端」执行一次：
     xattr -dr com.apple.quarantine /Applications/STS2MacLauncher.app
   然后双击打开即可。

3. 一键补齐上游扩展（无需 Homebrew / Xcode / .NET）：
   本公开版内置 100% MIT 开源核心（Godot 4.5.1 + .NET 9 osx-arm64 + 原生桥接库 + STS2MacBridge）。
   首次打开启动器后，点击首页「一键下载扩展」，应用会直接从官方上游源自动拉取
   Spine 4.2 骨骼扩展与 FMOD 2.03.06 音频库至你的本地用户目录。

4. 自主导入游戏包并启动：
   将你本机合法持有的 Windows 版《杀戮尖塔2》目录或 .zip 压缩包
   拖入启动器窗口，点击「启动游戏」即可原生游玩。

5. 游戏内性能与快捷悬浮窗：
   - 按 F9：隐藏/显示性能悬浮窗（FPS / 帧时间 / CPU / 漏帧）
   - 按 Shift+F9：展开/收起详情面板与快速结束游戏按钮
   - 拖动悬浮窗顶部可自由调整位置并自动记忆

免责声明：
   本工具为非官方开源跨平台兼容启动器，与 Mega Crit Games 无关联；
   不包含任何游戏文件，亦不内置任何绕过 DRM 或正版校验功能。
   用户须自行确保所导入游戏文件的合法授权与合规来源，并自行承担相关责任。
TXT

rm -f "$DMG_PATH"
hdiutil create \
    -volname "杀戮尖塔2 macOS 启动器" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH"

echo ""
echo "[mit-release] Size summary:"
du -sh "$EMBED_ROOT"/* "$APP_BUNDLE" "$DMG_PATH"
echo "[mit-release] Done! 100% MIT-compliant public release ready:"
echo "  App: $APP_BUNDLE"
echo "  DMG: $DMG_PATH"
