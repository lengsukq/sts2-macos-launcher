#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_OUTPUT_DIR="${HOME}/Library/Application Support/STS2MacLauncher/bridge-runtime/stubs"
OUTPUT_DIR="${1:-${DEFAULT_OUTPUT_DIR}}"

MIN_MACOS_VERSION="13.0"
CLANG_BIN="${CLANG:-clang}"

if ! command -v "${CLANG_BIN}" >/dev/null 2>&1; then
    echo "Error: clang not found. Install Xcode Command Line Tools (xcode-select --install)." >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

compile_stub() {
    local source_file="$1"
    local output_name="$2"
    local install_name="${3:-@rpath/${output_name}}"
    local output_path="${OUTPUT_DIR}/${output_name}"

    echo "[native-stubs] Compiling ${output_name} (arm64)..."
    "${CLANG_BIN}" \
        -arch arm64 \
        -mmacosx-version-min="${MIN_MACOS_VERSION}" \
        -O2 \
        -Wall -Wextra -Werror \
        -fvisibility=hidden \
        -shared \
        -Wl,-install_name,"${install_name}" \
        "${SCRIPT_DIR}/${source_file}" \
        -o "${output_path}"

    codesign --force --sign - "${output_path}" >/dev/null 2>&1
}

compile_stub "sentry_stub.c" "libsentry.macos.release.dylib"
compile_stub "sentry_dep_stub.c" "libSentry.dylib"
compile_stub "fmod_stub.c" "libGodotFmod.stub.dylib"
compile_stub "hostfxr_bridge.c" "libhostfxr_bridge.dylib" "@rpath/libhostfxr.dylib"

echo "[native-stubs] Built all arm64 dylibs in ${OUTPUT_DIR}"
