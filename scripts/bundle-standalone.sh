#!/usr/bin/env bash
# Note: This script bundles locally fetched third-party binaries (including FMOD and Spine)
# for PERSONAL LOCAL USE ONLY. Do not publicly redistribute the resulting standalone DMG
# without obtaining the appropriate FMOD and Spine redistribution licenses.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="STS2MacLauncher"
DIST_DIR="$ROOT/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-arm64-standalone.dmg"
BRIDGE_SRC="${1:-$HOME/Library/Application Support/STS2MacLauncher/bridge-runtime}"
MANIFEST_SRC="$BRIDGE_SRC/bridge-runtime-manifest.json"

if [ ! -f "$MANIFEST_SRC" ]; then
    echo "ERROR: Bridge runtime manifest not found at: $MANIFEST_SRC" >&2
    echo "Run ./scripts/setup-bridge-runtime.sh first." >&2
    exit 1
fi

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

thin_framework_to_arm64() {
    local fw="$1"
    if [ ! -d "$fw" ]; then
        return 0
    fi
    while IFS= read -r -d '' file; do
        thin_macho_to_arm64 "$file"
    done < <(find "$fw" -type f ! -name "*.plist" ! -name "*.json" ! -name "*.txt" -print0)
}

echo "[standalone] 1/5 Building release STS2LauncherApp (arm64)..."
cd "$ROOT"
swift build -c release --arch arm64 --product STS2LauncherApp

BIN_PATH="$(swift build -c release --arch arm64 --show-bin-path)/STS2LauncherApp"
if [ ! -f "$BIN_PATH" ]; then
    echo "ERROR: Built executable not found at $BIN_PATH" >&2
    exit 1
fi

echo "[standalone] 2/5 Assembling app bundle skeleton..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

if [ -f "$ROOT/THIRD_PARTY_LICENSES.md" ]; then
    cp "$ROOT/THIRD_PARTY_LICENSES.md" "$APP_BUNDLE/Contents/Resources/THIRD_PARTY_LICENSES.md"
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
    <key>CFBundleIdentifier</key>
    <string>io.github.lengsukq.sts2-macos-launcher</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>STS2MacLauncher</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
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

echo "[standalone] 3/5 Slimming and embedding arm64-only bridge-runtime..."
EMBED_ROOT="$APP_BUNDLE/Contents/Resources/bridge-runtime"
mkdir -p \
    "$EMBED_ROOT/godot-template" \
    "$EMBED_ROOT/dotnet-osx-arm64" \
    "$EMBED_ROOT/gdextensions/spine" \
    "$EMBED_ROOT/gdextensions/fmod" \
    "$EMBED_ROOT/stubs" \
    "$EMBED_ROOT/bridge"

# Read exact source paths from bridge-runtime-manifest.json
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
emit("M_FMOD_MODE", m.get("fmodMode", "full"))
emit("M_GODOT_APP", m.get("godotTemplateAppPath", ""))
emit("M_DOTNET_DIR", m.get("dotnetRuntimeDirPath", ""))
emit("M_SPINE_FW", m.get("spineFrameworkPath", ""))
emit("M_FMOD_FW", m.get("fmodFrameworkPath", ""))
emit("M_SENTRY_STUB", m.get("sentryStubDylibPath", ""))
emit("M_SENTRY_DEP", m.get("sentryDepDylibPath", ""))
emit("M_STEAM_API", m.get("steamApiDylibPath", ""))
emit("M_HOSTFXR_BRIDGE", m.get("hostfxrBridgeDylibPath", ""))
emit("M_BRIDGE_DLL", m.get("bridgeDllPath", ""))
dylibs = m.get("fmodDylibPaths") or []
print("M_FMOD_DYLIBS=(" + " ".join(shlex.quote(x) for x in dylibs) + ")")
PY
)"

# 3a. Godot template (drop debug binary, thin release binary to arm64)
cp -R "$M_GODOT_APP" "$EMBED_ROOT/godot-template/macos_template.app"
rm -f "$EMBED_ROOT/godot-template/macos_template.app/Contents/MacOS/"*debug*
for bin in "$EMBED_ROOT/godot-template/macos_template.app/Contents/MacOS/"*; do
    thin_macho_to_arm64 "$bin"
done

# 3b. .NET 9 osx-arm64 runtime + GodotSharp.dll
cp -R "$M_DOTNET_DIR/." "$EMBED_ROOT/dotnet-osx-arm64/"

# 3c. Spine macOS template_release framework (thinned to arm64)
SPINE_NAME="$(basename "$M_SPINE_FW")"
cp -R "$M_SPINE_FW" "$EMBED_ROOT/gdextensions/spine/$SPINE_NAME"
thin_framework_to_arm64 "$EMBED_ROOT/gdextensions/spine/$SPINE_NAME"

# 3d. FMOD macOS template_release framework + core dylibs ONLY (drop win/linux/android/ios bloat)
FMOD_FW_REL=""
FMOD_DYLIBS_REL=()
if [ -n "$M_FMOD_FW" ] && [ -e "$M_FMOD_FW" ]; then
    FMOD_FW_NAME="$(basename "$M_FMOD_FW")"
    cp -R "$M_FMOD_FW" "$EMBED_ROOT/gdextensions/fmod/$FMOD_FW_NAME"
    thin_framework_to_arm64 "$EMBED_ROOT/gdextensions/fmod/$FMOD_FW_NAME"
    FMOD_FW_REL="gdextensions/fmod/$FMOD_FW_NAME"
fi
for dylib in "${M_FMOD_DYLIBS[@]}"; do
    if [ -f "$dylib" ]; then
        dname="$(basename "$dylib")"
        cp "$dylib" "$EMBED_ROOT/gdextensions/fmod/$dname"
        thin_macho_to_arm64 "$EMBED_ROOT/gdextensions/fmod/$dname"
        FMOD_DYLIBS_REL+=("gdextensions/fmod/$dname")
    fi
done

# 3e. Native runtime bridges & STS2MacBridge.dll
for stub in "$M_SENTRY_STUB" "$M_SENTRY_DEP" "$M_HOSTFXR_BRIDGE"; do
    if [ -n "$stub" ] && [ -f "$stub" ]; then
        cp "$stub" "$EMBED_ROOT/stubs/$(basename "$stub")"
    fi
done
STEAM_API_REL=""
if [ -n "$M_STEAM_API" ] && [ -f "$M_STEAM_API" ]; then
    mkdir -p "$EMBED_ROOT/steam"
    cp "$M_STEAM_API" "$EMBED_ROOT/steam/libsteam_api.dylib"
    STEAM_API_REL="steam/libsteam_api.dylib"
fi
if [ -f "$BRIDGE_SRC/stubs/libGodotFmod.stub.dylib" ]; then
    cp "$BRIDGE_SRC/stubs/libGodotFmod.stub.dylib" "$EMBED_ROOT/stubs/libGodotFmod.stub.dylib"
fi
cp "$M_BRIDGE_DLL" "$EMBED_ROOT/bridge/STS2MacBridge.dll"

# 3f. Write portable relative-path bridge-runtime-manifest.json
python3 - "$EMBED_ROOT/bridge-runtime-manifest.json" \
    "$M_GODOT_VER" "$M_DOTNET_VER" "$M_SPINE_VER" "$M_FMOD_VER" "$M_FMOD_MODE" \
    "gdextensions/spine/$SPINE_NAME" "$FMOD_FW_REL" "$STEAM_API_REL" "${FMOD_DYLIBS_REL[@]}" <<'PY'
import datetime, json, sys
out_path, godot_v, dotnet_v, spine_v, fmod_v, fmod_mode, spine_rel, fmod_fw_rel, steam_rel = sys.argv[1:10]
fmod_dylibs_rel = sys.argv[10:]
manifest = {
    "godotVersion": godot_v,
    "dotnetVersion": dotnet_v,
    "spineVersion": spine_v,
    "fmodVersion": fmod_v,
    "fmodMode": fmod_mode,
    "godotTemplateAppPath": "godot-template/macos_template.app",
    "dotnetRuntimeDirPath": "dotnet-osx-arm64",
    "godotSharpDllPath": "dotnet-osx-arm64/GodotSharp.dll",
    "spineFrameworkPath": spine_rel,
    "fmodFrameworkPath": fmod_fw_rel,
    "fmodDylibPaths": fmod_dylibs_rel,
    "sentryStubDylibPath": "stubs/libsentry.macos.release.dylib",
    "sentryDepDylibPath": "stubs/libSentry.dylib",
    "steamApiDylibPath": steam_rel or None,
    "hostfxrBridgeDylibPath": "stubs/libhostfxr_bridge.dylib",
    "bridgeDllPath": "bridge/STS2MacBridge.dll",
    "builtAt": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(out_path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY

echo "[standalone] 4/5 Signing embedded binaries and app bundle (inside-out ad-hoc)..."
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# Sign individual dylibs, frameworks, nested template .app, then outer .app
while IFS= read -r -d '' dylib; do
    codesign --force --sign - "$dylib" 2>/dev/null
done < <(find "$EMBED_ROOT" -type f -name "*.dylib" -print0)

while IFS= read -r -d '' fw; do
    codesign --force --deep --sign - "$fw" 2>/dev/null
done < <(find "$EMBED_ROOT" -type d -name "*.framework" -print0)

codesign --force --deep --sign - "$EMBED_ROOT/godot-template/macos_template.app" 2>/dev/null
codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null
codesign --force --sign - "$APP_BUNDLE" 2>/dev/null

echo "[standalone] Verifying codesign integrity..."
codesign --verify --strict --verbose=2 "$APP_BUNDLE"
codesign --verify --deep --strict "$EMBED_ROOT/godot-template/macos_template.app"

echo "[standalone] 5/5 Creating compressed standalone DMG..."
DMG_STAGE="$(mktemp -d /tmp/sts2-dmg-stage.XXXXXX)"
trap 'rm -rf "$DMG_STAGE"' EXIT

cp -R "$APP_BUNDLE" "$DMG_STAGE/$APP_NAME.app"
ln -s /Applications "$DMG_STAGE/Applications"

cat > "$DMG_STAGE/首次打开说明.txt" <<'TXT'
《杀戮尖塔2》macOS 启动器（Apple Silicon 开箱即用版）
==================================================

1. 安装：
   将 STS2MacLauncher.app 拖入右侧 Applications（应用程序）文件夹。

2. 首次打开若 macOS 提示“无法验证开发者”或“已损坏”：
   因本应用为开源自签名分发（无 Apple 付费公证证书），请打开「终端」执行一次：
     xattr -dr com.apple.quarantine /Applications/STS2MacLauncher.app
   然后双击打开即可。

3. 开始游戏（无需官方 Mac 版，无需安装任何开发工具）：
   打开启动器后，直接将你的 Windows 版《杀戮尖塔2》文件夹或 .zip 压缩包
   拖入窗口，点击「启动游戏」即可原生游玩。

4. 游戏内快捷悬浮窗：
   - 按 F9：隐藏/显示性能悬浮窗（FPS / 帧时间 / CPU / 漏帧）
   - 按 Shift+F9：展开/收起详情面板与快速结束游戏按钮
   - 拖动悬浮窗顶部可自由调整位置并自动记忆
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
echo "[standalone] Size summary:"
du -sh "$EMBED_ROOT"/* "$APP_BUNDLE" "$DMG_PATH"
echo "[standalone] Done! Standalone bundle ready:"
echo "  App: $APP_BUNDLE"
echo "  DMG: $DMG_PATH"
