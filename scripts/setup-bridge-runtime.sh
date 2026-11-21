#!/usr/bin/env bash
set -euo pipefail

# Ensure Homebrew & dotnet@9 are discoverable even when invoked from a GUI .app bundle.
export PATH="/opt/homebrew/opt/dotnet@9/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

GODOT_VERSION="4.5.1-stable"
GODOT_SHARP_NUGET_VERSION="4.5.1"
SYSTEM_IO_HASHING_VERSION="9.0.0"
SPINE_VERSION="4.2-4.5.1-stable"
FMOD_VERSION="6.1.0-4.5.0"

GODOT_TPZ_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_mono_export_templates.tpz"
FMOD_ADDONS_URL="https://github.com/utopia-rise/fmod-gdextension/releases/download/${FMOD_VERSION}/addons.zip"
SPINE_ZIP_URL="https://spine-godot.s3.eu-central-1.amazonaws.com/4.2/${GODOT_VERSION}/spine-godot-extension-${SPINE_VERSION}.zip"

LAUNCHER_APP_SUPPORT="${HOME}/Library/Application Support/STS2MacLauncher"
RUNTIME_DIR="${STS2_BRIDGE_RUNTIME_DIR:-${LAUNCHER_APP_SUPPORT}/bridge-runtime}"
FORCE_REBUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            RUNTIME_DIR="$2"
            shift 2
            ;;
        --force)
            FORCE_REBUILD=1
            shift
            ;;
        -h|--help)
            cat <<EOF
Usage: $(basename "$0") [--output-dir <path>] [--force]

Idempotently builds the self-hosted macOS arm64 Bridge Runtime for Slay the Spire 2:
  - Godot ${GODOT_VERSION} Mono macOS export template
  - .NET 9 osx-arm64 CoreCLR + BCL + GodotSharp ${GODOT_SHARP_NUGET_VERSION} + System.IO.Hashing ${SYSTEM_IO_HASHING_VERSION}
  - Spine GDExtension ${SPINE_VERSION}
  - FMOD GDExtension ${FMOD_VERSION} (auto-detects full vs stub)
  - Native arm64 bridges (hostfxr_bridge, Sentry no-op, FMOD fallback)
  - STS2MacBridge.dll (pure-MIT .NET 9 StartupHook + Harmony compatibility patches + in-game HUD)
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

CACHE_DIR="${RUNTIME_DIR}/.cache"
GODOT_TEMPLATE_DIR="${RUNTIME_DIR}/godot-template"
GODOT_TEMPLATE_APP="${GODOT_TEMPLATE_DIR}/macos_template.app"
DOTNET_RUNTIME_DIR="${RUNTIME_DIR}/dotnet-osx-arm64"
GDEXT_DIR="${RUNTIME_DIR}/gdextensions"
FMOD_DIR="${GDEXT_DIR}/fmod"
SPINE_DIR="${GDEXT_DIR}/spine"
STUBS_DIR="${RUNTIME_DIR}/stubs"
BRIDGE_DIR="${RUNTIME_DIR}/bridge"
MANIFEST_PATH="${RUNTIME_DIR}/bridge-runtime-manifest.json"

WORK_TMP="$(mktemp -d /tmp/sts2-bridge-setup.XXXXXX)"
cleanup() {
    rm -rf "${WORK_TMP}"
}
trap cleanup EXIT

log() {
    printf '[setup-bridge] %s\n' "$*"
}

fail() {
    printf '[setup-bridge] ERROR: %s\n' "$*" >&2
    exit 1
}

download_file() {
    local url="$1"
    local dest="$2"

    if [[ -f "${dest}" && ${FORCE_REBUILD} -eq 0 ]]; then
        log "Using cached archive: ${dest}"
        return 0
    fi

    mkdir -p "$(dirname "${dest}")"
    local part="${dest}.part"
    log "Downloading ${url} -> ${dest}"
    curl -fL --retry 3 --retry-delay 2 -C - -o "${part}" "${url}"
    mv "${part}" "${dest}"
}

ensure_dotnet9() {
    log "[1/7] Checking .NET 9 SDK..."

    if [[ -d "/opt/homebrew/opt/dotnet@9/libexec" ]]; then
        export DOTNET_ROOT="/opt/homebrew/opt/dotnet@9/libexec"
    fi

    local has_dotnet9=0
    if command -v dotnet >/dev/null 2>&1; then
        if dotnet --list-sdks 2>/dev/null | grep -qE '^9\.'; then
            has_dotnet9=1
        fi
    fi

    if [[ ${has_dotnet9} -eq 0 ]]; then
        if ! command -v brew >/dev/null 2>&1; then
            fail "dotnet@9 is not installed and Homebrew was not found. Install Homebrew or .NET 9 SDK manually."
        fi

        log "Installing dotnet@9 via Homebrew..."
        (
            unset HOMEBREW_ASK
            NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1 brew install dotnet@9 </dev/null
        )

        export PATH="/opt/homebrew/opt/dotnet@9/bin:${PATH}"
        export DOTNET_ROOT="/opt/homebrew/opt/dotnet@9/libexec"
    fi

    if ! command -v dotnet >/dev/null 2>&1 || ! dotnet --list-sdks 2>/dev/null | grep -qE '^9\.'; then
        fail "Failed to locate .NET 9 SDK after installation."
    fi

    DOTNET_SDK_VERSION="$(dotnet --list-sdks | awk '/^9\./ { v=$1 } END { print v }')"
    log "Using .NET 9 SDK ${DOTNET_SDK_VERSION} ($(command -v dotnet))"
}

fetch_godot_macos_template_zip() {
    local cached_macos_zip="${CACHE_DIR}/godot-${GODOT_VERSION}-mono-macos.zip"
    local cached_full_tpz="${CACHE_DIR}/Godot_v${GODOT_VERSION}_mono_export_templates.tpz"

    if [[ -f "${cached_macos_zip}" && ${FORCE_REBUILD} -eq 0 ]]; then
        log "Using cached Godot macOS export template: ${cached_macos_zip}"
        GODOT_MACOS_ZIP_PATH="${cached_macos_zip}"
        return 0
    fi

    mkdir -p "${CACHE_DIR}"

    if [[ -f "${cached_full_tpz}" && ${FORCE_REBUILD} -eq 0 ]]; then
        log "Extracting templates/macos.zip from cached .tpz..."
        unzip -p "${cached_full_tpz}" "templates/macos.zip" > "${cached_macos_zip}.part"
        mv "${cached_macos_zip}.part" "${cached_macos_zip}"
        GODOT_MACOS_ZIP_PATH="${cached_macos_zip}"
        return 0
    fi

    log "Fetching templates/macos.zip (~123 MB) from official Godot ${GODOT_VERSION} .tpz via HTTP Range..."
    if python3 - "${GODOT_TPZ_URL}" "${cached_macos_zip}" <<'PYEOF'
import concurrent.futures
import os
import struct
import sys
import urllib.request
import zlib

url, out_path = sys.argv[1], sys.argv[2]
req = urllib.request.Request(url, method="HEAD")
with urllib.request.urlopen(req, timeout=30) as resp:
    final_url = resp.geturl()
    total_size = int(resp.headers["Content-Length"])
    accept_ranges = resp.headers.get("Accept-Ranges", "")
    if "bytes" not in accept_ranges.lower():
        sys.exit(2)

tail_size = min(65536, total_size)
tail_req = urllib.request.Request(final_url, headers={"Range": f"bytes={total_size - tail_size}-{total_size - 1}"})
with urllib.request.urlopen(tail_req, timeout=30) as resp:
    tail = resp.read()

eocd_idx = tail.rfind(b"PK\x05\x06")
if eocd_idx < 0:
    sys.exit(2)

_, _, _, total_entries, cd_size, cd_offset = struct.unpack_from("<HHHHII", tail, eocd_idx + 4)
cd_rel = cd_offset - (total_size - tail_size)
if cd_rel >= 0:
    cd = tail[cd_rel:cd_rel + cd_size]
else:
    cd_req = urllib.request.Request(final_url, headers={"Range": f"bytes={cd_offset}-{cd_offset + cd_size - 1}"})
    with urllib.request.urlopen(cd_req, timeout=30) as resp:
        cd = resp.read()

pos = 0
entry = None
for _ in range(total_entries):
    if cd[pos:pos + 4] != b"PK\x01\x02":
        sys.exit(2)
    comp_method, _, _, crc, comp_sz, uncomp_sz, fname_len, extra_len, comm_len, _, _, _, lfh_off = struct.unpack_from(
        "<HHHIIIHHHHHII", cd, pos + 10
    )
    fname = cd[pos + 46:pos + 46 + fname_len].decode("utf-8", "replace")
    if fname == "templates/macos.zip":
        entry = (comp_method, crc, comp_sz, uncomp_sz, lfh_off)
        break
    pos += 46 + fname_len + extra_len + comm_len

if entry is None:
    sys.exit(2)

comp_method, expected_crc, comp_sz, uncomp_sz, lfh_off = entry
lfh_req = urllib.request.Request(final_url, headers={"Range": f"bytes={lfh_off}-{lfh_off + 255}"})
with urllib.request.urlopen(lfh_req, timeout=30) as resp:
    lfh = resp.read()
if lfh[:4] != b"PK\x03\x04":
    sys.exit(2)

lfh_fname_len, lfh_extra_len = struct.unpack_from("<HH", lfh, 26)
data_start = lfh_off + 30 + lfh_fname_len + lfh_extra_len

chunks = 8
chunk_sz = (comp_sz + chunks - 1) // chunks

def fetch_chunk(idx):
    start = data_start + idx * chunk_sz
    end = min(data_start + comp_sz - 1, start + chunk_sz - 1)
    if start > end:
        return b""
    for attempt in range(4):
        try:
            r = urllib.request.Request(final_url, headers={"Range": f"bytes={start}-{end}"})
            with urllib.request.urlopen(r, timeout=180) as resp:
                buf = resp.read()
                if len(buf) == (end - start + 1):
                    return buf
        except Exception:
            if attempt == 3:
                raise
    raise RuntimeError(f"Range chunk {idx} failed")

with concurrent.futures.ThreadPoolExecutor(max_workers=chunks) as pool:
    compressed = b"".join(pool.map(fetch_chunk, range(chunks)))

if len(compressed) != comp_sz:
    sys.exit(2)

raw = zlib.decompress(compressed, -zlib.MAX_WBITS) if comp_method == 8 else compressed
if len(raw) != uncomp_sz:
    sys.exit(2)
if (zlib.crc32(raw) & 0xFFFFFFFF) != expected_crc:
    sys.exit(2)

tmp_out = out_path + ".part"
with open(tmp_out, "wb") as f:
    f.write(raw)
os.replace(tmp_out, out_path)
PYEOF
    then
        GODOT_MACOS_ZIP_PATH="${cached_macos_zip}"
        return 0
    fi

    log "HTTP Range extraction unavailable; falling back to full .tpz download..."
    download_file "${GODOT_TPZ_URL}" "${cached_full_tpz}"
    unzip -p "${cached_full_tpz}" "templates/macos.zip" > "${cached_macos_zip}.part"
    mv "${cached_macos_zip}.part" "${cached_macos_zip}"
    GODOT_MACOS_ZIP_PATH="${cached_macos_zip}"
}

setup_godot_template() {
    log "[2/7] Preparing Godot ${GODOT_VERSION} Mono macOS template..."
    GODOT_MACOS_ZIP_PATH=""
    fetch_godot_macos_template_zip
    local macos_zip="${GODOT_MACOS_ZIP_PATH}"

    local stage_dir="${WORK_TMP}/godot-stage"
    mkdir -p "${stage_dir}"
    unzip -q -o "${macos_zip}" -d "${stage_dir}"

    if [[ ! -d "${stage_dir}/macos_template.app" ]]; then
        fail "macos_template.app was not found inside ${macos_zip}."
    fi

    mkdir -p "${GODOT_TEMPLATE_DIR}"
    rm -rf "${GODOT_TEMPLATE_APP}"
    mv "${stage_dir}/macos_template.app" "${GODOT_TEMPLATE_APP}"

    chmod +x "${GODOT_TEMPLATE_APP}/Contents/MacOS/"*
    xattr -dr com.apple.quarantine "${GODOT_TEMPLATE_APP}" 2>/dev/null || true

    log "Godot template ready at ${GODOT_TEMPLATE_APP}"
}

setup_dotnet_runtime() {
    log "[3/7] Building pure .NET 9 osx-arm64 CoreCLR + BCL + GodotSharp ${GODOT_SHARP_NUGET_VERSION}..."

    local proj_dir="${WORK_TMP}/dotnet-runtime-seed"
    local publish_dir="${WORK_TMP}/dotnet-publish"
    mkdir -p "${proj_dir}" "${publish_dir}"

    cat > "${proj_dir}/RuntimeSeed.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net9.0</TargetFramework>
    <RuntimeIdentifier>osx-arm64</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <PublishSingleFile>false</PublishSingleFile>
    <PublishTrimmed>false</PublishTrimmed>
    <DebugType>none</DebugType>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="GodotSharp" Version="${GODOT_SHARP_NUGET_VERSION}" />
    <PackageReference Include="System.IO.Hashing" Version="${SYSTEM_IO_HASHING_VERSION}" />
  </ItemGroup>
</Project>
EOF

    cat > "${proj_dir}/Program.cs" <<'EOF'
using System;
using System.IO.Hashing;

internal static class Program
{
    private static void Main()
    {
        Console.WriteLine(typeof(Godot.Node).Assembly.FullName);
        Console.WriteLine(typeof(XxHash32).Assembly.FullName);
    }
}
EOF

    dotnet publish "${proj_dir}/RuntimeSeed.csproj" \
        -c Release \
        -r osx-arm64 \
        --self-contained true \
        -o "${publish_dir}" \
        -v minimal

    # Extract exact .NET runtime version from RuntimeSeed.runtimeconfig.json before deleting seed files.
    DOTNET_RUNTIME_VERSION="$(python3 - "${publish_dir}/RuntimeSeed.runtimeconfig.json" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    cfg = json.load(f)
frameworks = cfg.get("runtimeOptions", {}).get("includedFrameworks", [])
print(frameworks[0]["version"] if frameworks else "9.0.0")
PYEOF
)"

    # Strip the temporary seed executable and metadata so only pure CoreCLR/BCL/GodotSharp remain.
    rm -f \
        "${publish_dir}/RuntimeSeed" \
        "${publish_dir}/RuntimeSeed.dll" \
        "${publish_dir}/RuntimeSeed.pdb" \
        "${publish_dir}/RuntimeSeed.deps.json" \
        "${publish_dir}/RuntimeSeed.runtimeconfig.json" \
        "${publish_dir}/createdump"

    rm -rf "${DOTNET_RUNTIME_DIR}"
    mkdir -p "${RUNTIME_DIR}"
    mv "${publish_dir}" "${DOTNET_RUNTIME_DIR}"

    xattr -dr com.apple.quarantine "${DOTNET_RUNTIME_DIR}" 2>/dev/null || true
    log ".NET ${DOTNET_RUNTIME_VERSION} osx-arm64 runtime ready at ${DOTNET_RUNTIME_DIR}"
}

setup_fmod_extension() {
    log "[4/7] Preparing FMOD GDExtension (${FMOD_VERSION})..."
    local cached_zip="${CACHE_DIR}/fmod-addons-${FMOD_VERSION}.zip"
    download_file "${FMOD_ADDONS_URL}" "${cached_zip}"

    local stage_dir="${WORK_TMP}/fmod-stage"
    mkdir -p "${stage_dir}"
    unzip -q -o "${cached_zip}" -d "${stage_dir}"

    rm -rf "${FMOD_DIR}"
    mkdir -p "${GDEXT_DIR}"
    mv "${stage_dir}" "${FMOD_DIR}"
    xattr -dr com.apple.quarantine "${FMOD_DIR}" 2>/dev/null || true

    local found_fw found_fmod found_studio
    found_fw="$(find "${FMOD_DIR}" -maxdepth 5 -type d -name 'libGodotFmod.macos.template_release.framework' | head -n 1 || true)"
    found_fmod="$(find "${FMOD_DIR}" -maxdepth 5 -type f -name 'libfmod.dylib' | head -n 1 || true)"
    found_studio="$(find "${FMOD_DIR}" -maxdepth 5 -type f -name 'libfmodstudio.dylib' | head -n 1 || true)"

    if [[ -n "${found_fw}" && -n "${found_fmod}" && -n "${found_studio}" ]]; then
        local fw_bin="${found_fw}/libGodotFmod.macos.template_release"
        if [[ -f "${fw_bin}" ]] && lipo -archs "${fw_bin}" 2>/dev/null | grep -qw arm64; then
            # Normalize upstream install_name (which defaults to demo/addons/...) and add @loader_path/.. rpath.
            install_name_tool -id \
                "@rpath/libGodotFmod.macos.template_release.framework/libGodotFmod.macos.template_release" \
                "${fw_bin}" 2>/dev/null || true
            if ! otool -l "${fw_bin}" | grep -q "@loader_path/.."; then
                install_name_tool -add_rpath "@loader_path/.." "${fw_bin}" 2>/dev/null || true
            fi
            codesign --force --sign - "${fw_bin}" >/dev/null 2>&1
            codesign --force --sign - "${found_fmod}" >/dev/null 2>&1
            codesign --force --sign - "${found_studio}" >/dev/null 2>&1

            FMOD_MODE="full"
            FMOD_FRAMEWORK_PATH="${found_fw}"
            FMOD_DYLIB_1="${found_fmod}"
            FMOD_DYLIB_2="${found_studio}"
            log "FMOD full audio mode detected (framework + libfmod.dylib + libfmodstudio.dylib)."
            return 0
        fi
    fi

    FMOD_MODE="stub"
    FMOD_FRAMEWORK_PATH=""
    FMOD_DYLIB_1=""
    FMOD_DYLIB_2=""
    log "FMOD proprietary dylibs missing; falling back to silent stub mode."
}

setup_spine_extension() {
    log "[5/7] Preparing Spine GDExtension (${SPINE_VERSION})..."
    local cached_zip="${CACHE_DIR}/spine-godot-extension-${SPINE_VERSION}.zip"
    download_file "${SPINE_ZIP_URL}" "${cached_zip}"

    local stage_dir="${WORK_TMP}/spine-stage"
    mkdir -p "${stage_dir}"
    unzip -q -o "${cached_zip}" -d "${stage_dir}"

    local src_fw
    src_fw="$(find "${stage_dir}" -maxdepth 5 -type d -name 'libspine_godot.macos.template_release.framework' | head -n 1 || true)"
    if [[ -z "${src_fw}" ]]; then
        fail "libspine_godot.macos.template_release.framework not found inside ${cached_zip}."
    fi

    rm -rf "${SPINE_DIR}"
    mkdir -p "${SPINE_DIR}"
    mv "${src_fw}" "${SPINE_DIR}/libspine_godot.macos.template_release.framework"
    SPINE_FRAMEWORK_PATH="${SPINE_DIR}/libspine_godot.macos.template_release.framework"

    xattr -dr com.apple.quarantine "${SPINE_FRAMEWORK_PATH}" 2>/dev/null || true
    codesign --force --sign - "${SPINE_FRAMEWORK_PATH}/libspine_godot.macos.template_release" >/dev/null 2>&1
    log "Spine GDExtension ready at ${SPINE_FRAMEWORK_PATH}"
}

build_native_stubs() {
    log "[6/7] Building arm64 native stubs..."
    "${REPO_ROOT}/bridge/native-stubs/build-native-stubs.sh" "${STUBS_DIR}"
}

build_managed_bridge() {
    log "[7/7] Building pure-MIT STS2MacBridge.dll (zero commercial game DLL reference)..."
    local bridge_csproj="${REPO_ROOT}/bridge/STS2MacBridge/STS2MacBridge.csproj"
    local obj_dir="${WORK_TMP}/bridge-obj/"
    local out_dir="${WORK_TMP}/bridge-out"
    mkdir -p "${obj_dir}" "${out_dir}"

    # Ensure stale in-tree bin/obj cannot interfere with out-of-tree compilation.
    rm -rf "${REPO_ROOT}/bridge/STS2MacBridge/bin" "${REPO_ROOT}/bridge/STS2MacBridge/obj"

    dotnet build "${bridge_csproj}" \
        -c Release \
        -p:BaseIntermediateOutputPath="${obj_dir}" \
        -o "${out_dir}" \
        -v minimal

    mkdir -p "${BRIDGE_DIR}"
    cp -f "${out_dir}/STS2MacBridge.dll" "${BRIDGE_DIR}/STS2MacBridge.dll"
    if [[ -f "${out_dir}/STS2MacBridge.pdb" ]]; then
        cp -f "${out_dir}/STS2MacBridge.pdb" "${BRIDGE_DIR}/STS2MacBridge.pdb"
    fi
    log "STS2MacBridge.dll built at ${BRIDGE_DIR}/STS2MacBridge.dll"
}

write_manifest() {
    log "Writing ${MANIFEST_PATH}..."
    local built_at
    built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local steam_api_dylib=""
    if [[ -n "${STS2_STEAM_API_DYLIB:-}" && -f "${STS2_STEAM_API_DYLIB}" ]]; then
        steam_api_dylib="${STS2_STEAM_API_DYLIB}"
    elif [[ -f "${RUNTIME_DIR}/steam/libsteam_api.dylib" ]]; then
        steam_api_dylib="${RUNTIME_DIR}/steam/libsteam_api.dylib"
    fi

    python3 - "${MANIFEST_PATH}" \
        "${GODOT_VERSION}" \
        "${DOTNET_RUNTIME_VERSION}" \
        "${SPINE_VERSION}" \
        "${FMOD_VERSION}" \
        "${FMOD_MODE}" \
        "${GODOT_TEMPLATE_APP}" \
        "${DOTNET_RUNTIME_DIR}" \
        "${DOTNET_RUNTIME_DIR}/GodotSharp.dll" \
        "${SPINE_FRAMEWORK_PATH}" \
        "${FMOD_FRAMEWORK_PATH}" \
        "${FMOD_DYLIB_1}" \
        "${FMOD_DYLIB_2}" \
        "${STUBS_DIR}/libsentry.macos.release.dylib" \
        "${STUBS_DIR}/libSentry.dylib" \
        "${steam_api_dylib}" \
        "${STUBS_DIR}/libhostfxr_bridge.dylib" \
        "${BRIDGE_DIR}/STS2MacBridge.dll" \
        "${built_at}" <<'PYEOF'
import json
import sys

(
    manifest_path,
    godot_version,
    dotnet_version,
    spine_version,
    fmod_version,
    fmod_mode,
    godot_template_app,
    dotnet_runtime_dir,
    godot_sharp_dll,
    spine_framework,
    fmod_framework,
    fmod_dylib_1,
    fmod_dylib_2,
    sentry_stub,
    sentry_dep,
    steam_api_dylib,
    hostfxr_bridge,
    bridge_dll,
    built_at,
) = sys.argv[1:20]

fmod_dylibs = [p for p in (fmod_dylib_1, fmod_dylib_2) if p]

manifest = {
    "godotVersion": godot_version,
    "dotnetVersion": dotnet_version,
    "spineVersion": spine_version,
    "fmodVersion": fmod_version,
    "fmodMode": fmod_mode,
    "godotTemplateAppPath": godot_template_app,
    "dotnetRuntimeDirPath": dotnet_runtime_dir,
    "godotSharpDllPath": godot_sharp_dll,
    "spineFrameworkPath": spine_framework,
    "fmodFrameworkPath": fmod_framework,
    "fmodDylibPaths": fmod_dylibs,
    "sentryStubDylibPath": sentry_stub,
    "sentryDepDylibPath": sentry_dep,
    "steamApiDylibPath": steam_api_dylib or None,
    "hostfxrBridgeDylibPath": hostfxr_bridge,
    "bridgeDllPath": bridge_dll,
    "builtAt": built_at,
}

with open(manifest_path, "w", encoding="utf-8") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYEOF
}

verify_arm64_binary() {
    local binary="$1"
    local required_symbol="${2:-}"

    [[ -f "${binary}" ]] || fail "Verification failed: missing binary ${binary}"
    lipo -archs "${binary}" 2>/dev/null | grep -qw arm64 \
        || fail "Verification failed: ${binary} does not contain arm64 slice"

    if [[ -n "${required_symbol}" ]]; then
        nm -gU "${binary}" 2>/dev/null | grep -q "_${required_symbol}\$" \
            || fail "Verification failed: ${binary} missing exported symbol ${required_symbol}"
    fi
}

verify_runtime() {
    log "Running self-verification on ${RUNTIME_DIR}..."

    verify_arm64_binary "${GODOT_TEMPLATE_APP}/Contents/MacOS/godot_macos_release.universal"
    verify_arm64_binary "${DOTNET_RUNTIME_DIR}/libhostfxr.dylib"
    verify_arm64_binary "${DOTNET_RUNTIME_DIR}/libcoreclr.dylib"
    verify_arm64_binary "${DOTNET_RUNTIME_DIR}/libclrjit.dylib"
    verify_arm64_binary "${SPINE_FRAMEWORK_PATH}/libspine_godot.macos.template_release" "spine_godot_library_init"

    if [[ "${FMOD_MODE}" == "full" ]]; then
        verify_arm64_binary "${FMOD_FRAMEWORK_PATH}/libGodotFmod.macos.template_release" "fmod_library_init"
        verify_arm64_binary "${FMOD_DYLIB_1}"
        verify_arm64_binary "${FMOD_DYLIB_2}"
    fi

    verify_arm64_binary "${STUBS_DIR}/libsentry.macos.release.dylib" "sentry_gdextension_init"
    verify_arm64_binary "${STUBS_DIR}/libSentry.dylib"
    verify_arm64_binary "${STUBS_DIR}/libGodotFmod.stub.dylib" "fmod_library_init"
    verify_arm64_binary "${STUBS_DIR}/libhostfxr_bridge.dylib" "hostfxr_get_runtime_delegate"
    verify_arm64_binary "${STUBS_DIR}/libhostfxr_bridge.dylib" "hostfxr_initialize_for_runtime_config"
    verify_arm64_binary "${STUBS_DIR}/libhostfxr_bridge.dylib" "hostfxr_initialize_for_dotnet_command_line"
    verify_arm64_binary "${STUBS_DIR}/libhostfxr_bridge.dylib" "hostfxr_close"

    [[ -f "${DOTNET_RUNTIME_DIR}/GodotSharp.dll" ]] || fail "Missing GodotSharp.dll in ${DOTNET_RUNTIME_DIR}"
    [[ -f "${DOTNET_RUNTIME_DIR}/System.IO.Hashing.dll" ]] || fail "Missing System.IO.Hashing.dll in ${DOTNET_RUNTIME_DIR}"
    [[ -f "${BRIDGE_DIR}/STS2MacBridge.dll" ]] || fail "Missing STS2MacBridge.dll in ${BRIDGE_DIR}"
    [[ -f "${MANIFEST_PATH}" ]] || fail "Missing manifest at ${MANIFEST_PATH}"

    log "All bridge runtime components verified (arm64 + required symbols + manifest)."
}

main() {
    mkdir -p "${RUNTIME_DIR}" "${CACHE_DIR}"
    ensure_dotnet9
    setup_godot_template
    setup_dotnet_runtime
    setup_fmod_extension
    setup_spine_extension
    build_native_stubs
    build_managed_bridge
    write_manifest
    verify_runtime
    log "Bridge runtime setup complete: ${RUNTIME_DIR}"
}

main
