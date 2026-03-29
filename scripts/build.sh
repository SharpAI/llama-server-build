#!/bin/bash
# build.sh — Build llama-server from source (Linux & macOS)
#
# Usage:
#   ./scripts/build.sh <version> <acceleration> [cuda_architectures]
#
# Examples:
#   ./scripts/build.sh b8416 cpu
#   ./scripts/build.sh b8416 cuda "75;80;86;89;90;100;120"
#   ./scripts/build.sh b8416 vulkan
#   ./scripts/build.sh b8416 metal
#
# Environment:
#   CUDA_HOME — path to CUDA toolkit (auto-detected if not set)
#   BUILD_DIR — cmake build directory (default: /tmp/llama-build)
#   OUTPUT_DIR — where to place the final tarball (default: ./dist)

set -euo pipefail

VERSION="${1:?Usage: build.sh <version> <acceleration> [cuda_architectures]}"
ACCELERATION="${2:?Usage: build.sh <version> <acceleration> [cuda_architectures]}"
CUDA_ARCHS="${3:-}"

BUILD_DIR="${BUILD_DIR:-/tmp/llama-build}"
OUTPUT_DIR="${OUTPUT_DIR:-./dist}"
SOURCE_DIR="/tmp/llama-source"

# ── Derived values ────────────────────────────────────────────────────────────

ARCH="$(uname -m)"
OS="$(uname -s)"

case "$ARCH" in
    x86_64)  PLATFORM_ARCH="x64" ;;
    aarch64) PLATFORM_ARCH="arm64" ;;
    arm64)   PLATFORM_ARCH="arm64" ;;
    *)       echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

case "$OS" in
    Linux)  PLATFORM_OS="linux" ;;
    Darwin) PLATFORM_OS="macos" ;;
    *)      echo "❌ Unsupported OS: $OS"; exit 1 ;;
esac

# Cross-compilation support (e.g. CROSS_ARCH=x86_64 on arm64 macOS)
CROSS_COMPILE_ARGS=()
if [ -n "${CROSS_ARCH:-}" ]; then
    case "$CROSS_ARCH" in
        x86_64) PLATFORM_ARCH="x64" ;;
        arm64)  PLATFORM_ARCH="arm64" ;;
        *)      PLATFORM_ARCH="$CROSS_ARCH" ;;
    esac
    CROSS_COMPILE_ARGS+=( -DGGML_NATIVE=OFF )
    CROSS_COMPILE_ARGS+=( -DLLAMA_BUILD_BORINGSSL=OFF )
    CROSS_COMPILE_ARGS+=( -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL=ON )
    if [ "$PLATFORM_OS" = "macos" ]; then
        CROSS_COMPILE_ARGS+=( -DCMAKE_OSX_ARCHITECTURES="$CROSS_ARCH" )
    fi
    echo "🔄 Cross-compiling for $CROSS_ARCH (artifact arch: $PLATFORM_ARCH)"
fi

if [ "$ACCELERATION" = "cuda" ]; then
    # Determine CUDA label from CUDA_HOME path
    CUDA_LABEL="cuda-12"
    if [ -n "${CUDA_HOME:-}" ]; then
        case "$CUDA_HOME" in
            *13*) CUDA_LABEL="cuda-13" ;;
            *12*) CUDA_LABEL="cuda-12" ;;
        esac
    fi
    ARTIFACT_NAME="llama-server-${VERSION}-${PLATFORM_OS}-${PLATFORM_ARCH}-${CUDA_LABEL}"
else
    ARTIFACT_NAME="llama-server-${VERSION}-${PLATFORM_OS}-${PLATFORM_ARCH}-${ACCELERATION}"
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  llama-server builder                                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Version:       ${VERSION}"
echo "║  OS:            ${PLATFORM_OS}"
echo "║  Acceleration:  ${ACCELERATION}"
echo "║  Architecture:  ${ARCH} (${PLATFORM_ARCH})"
echo "║  CUDA archs:    ${CUDA_ARCHS:-n/a}"
echo "║  Artifact:      ${ARTIFACT_NAME}.tar.gz"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Clone source ──────────────────────────────────────────────────────────────

echo "📦 Cloning llama.cpp @ ${VERSION}..."
rm -rf "$SOURCE_DIR"
git clone --depth 1 --branch "${VERSION}" \
    https://github.com/ggml-org/llama.cpp.git "$SOURCE_DIR"

# ── Configure ─────────────────────────────────────────────────────────────────

CMAKE_ARGS=(
    -B "$BUILD_DIR"
    -S "$SOURCE_DIR"
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_SERVER=ON
)

# Generic ARM64 portability: when GGML_NATIVE=OFF, disable host-native CPU
# detection and force a conservative baseline so the binary runs on
# Jetson Orin (A78AE), Raspberry Pi 4 (A72), Pi 5 (A76), etc.
# Without this, builds on Graviton runners bake in SVE/i8mm/bf16 instructions
# that SIGILL on those targets.
if [ "${GGML_NATIVE:-ON}" = "OFF" ]; then
    CMAKE_ARGS+=( -DGGML_NATIVE=OFF )
    if [ "$PLATFORM_ARCH" = "arm64" ] && [ -z "${CROSS_ARCH:-}" ]; then
        # armv8-a = ARMv8.0 baseline: mandatory NEON, no dotprod/i8mm/SVE/BF16.
        # Runs on every 64-bit ARM board from Pi 4 onward.
        CMAKE_ARGS+=(
            -DCMAKE_C_FLAGS="-march=armv8-a"
            -DCMAKE_CXX_FLAGS="-march=armv8-a"
        )
    fi
fi

case "$ACCELERATION" in
    cuda)
        if [ -z "$CUDA_ARCHS" ]; then
            echo "❌ CUDA build requires cuda_architectures argument"
            exit 1
        fi

        # Auto-detect CUDA_HOME if not set
        if [ -z "${CUDA_HOME:-}" ]; then
            for candidate in /usr/local/cuda /usr/local/cuda-13 /usr/local/cuda-13.1 /usr/local/cuda-12 /usr/local/cuda-12.8; do
                if [ -d "$candidate" ]; then
                    export CUDA_HOME="$candidate"
                    break
                fi
            done
        fi

        if [ -z "${CUDA_HOME:-}" ]; then
            echo "❌ CUDA_HOME not set and no CUDA toolkit found"
            exit 1
        fi

        echo "🔧 Using CUDA toolkit: $CUDA_HOME"
        export PATH="${CUDA_HOME}/bin:${PATH}"

        CMAKE_ARGS+=(
            -DGGML_CUDA=ON
            -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}"
        )
        ;;
    vulkan)
        CMAKE_ARGS+=( -DGGML_VULKAN=ON )
        ;;
    metal)
        CMAKE_ARGS+=( -DGGML_METAL=ON )
        ;;
    cpu)
        CMAKE_ARGS+=( -DGGML_CUDA=OFF )
        ;;
    *)
        echo "❌ Unknown acceleration: $ACCELERATION"
        exit 1
        ;;
esac

echo "🔧 Configuring cmake..."
cmake "${CMAKE_ARGS[@]}" ${CROSS_COMPILE_ARGS[@]+"${CROSS_COMPILE_ARGS[@]}"}

# ── Build ─────────────────────────────────────────────────────────────────────

NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "🔨 Building with ${NPROC} jobs..."
cmake --build "$BUILD_DIR" --config Release -j"${NPROC}" --target llama-server

# ── Package ───────────────────────────────────────────────────────────────────

echo "📦 Packaging..."
STAGING_DIR="/tmp/llama-staging/${ARTIFACT_NAME}"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy the binary
if [ -f "${BUILD_DIR}/bin/llama-server" ]; then
    cp "${BUILD_DIR}/bin/llama-server" "$STAGING_DIR/"
elif [ -f "${BUILD_DIR}/bin/Release/llama-server" ]; then
    cp "${BUILD_DIR}/bin/Release/llama-server" "$STAGING_DIR/"
else
    echo "❌ Cannot find llama-server binary in build output"
    find "${BUILD_DIR}/bin" -type f 2>/dev/null || true
    exit 1
fi
chmod +x "$STAGING_DIR/llama-server"

# Copy shared libraries if present
find "${BUILD_DIR}" \( -name '*.so' -o -name '*.so.*' -o -name '*.dylib' -o -name '*.metal' \) | while read -r lib; do
    cp "$lib" "$STAGING_DIR/" 2>/dev/null || true
done

# Create tarball
mkdir -p "$OUTPUT_DIR"
TARBALL="${OUTPUT_DIR}/${ARTIFACT_NAME}.tar.gz"
tar -czf "$TARBALL" -C "/tmp/llama-staging" "${ARTIFACT_NAME}"

SIZE_MB=$(du -m "$TARBALL" | cut -f1)
echo ""
echo "✅ Built: ${TARBALL} (${SIZE_MB} MB)"

# Print binary info
echo ""
echo "📋 Binary info:"
"${STAGING_DIR}/llama-server" --version 2>&1 || true

# Clean up source and build dirs (keep staging for CI upload)
rm -rf "$SOURCE_DIR" "$BUILD_DIR"
