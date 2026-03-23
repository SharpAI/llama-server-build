#!/bin/bash
# build.sh — Build llama-server from source
#
# Usage:
#   ./scripts/build.sh <version> <acceleration> [cuda_architectures]
#
# Examples:
#   ./scripts/build.sh b8416 cpu
#   ./scripts/build.sh b8416 cuda "75;80;86;89;90;100;120"
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
case "$ARCH" in
    x86_64)  PLATFORM_ARCH="x64" ;;
    aarch64) PLATFORM_ARCH="arm64" ;;
    *)       echo "❌ Unsupported architecture: $ARCH"; exit 1 ;;
esac

if [ "$ACCELERATION" = "cuda" ]; then
    ARTIFACT_NAME="llama-server-${VERSION}-linux-${PLATFORM_ARCH}-cuda-12"
else
    ARTIFACT_NAME="llama-server-${VERSION}-linux-${PLATFORM_ARCH}-cpu"
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  llama-server builder                                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Version:       ${VERSION}"
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

if [ "$ACCELERATION" = "cuda" ]; then
    if [ -z "$CUDA_ARCHS" ]; then
        echo "❌ CUDA build requires cuda_architectures argument"
        exit 1
    fi

    # Auto-detect CUDA_HOME if not set
    if [ -z "${CUDA_HOME:-}" ]; then
        for candidate in /usr/local/cuda /usr/local/cuda-12 /usr/local/cuda-12.8; do
            if [ -d "$candidate" ]; then
                export CUDA_HOME="$candidate"
                break
            fi
        done
    fi

    if [ -z "${CUDA_HOME:-}" ]; then
        echo "❌ CUDA_HOME not set and no CUDA toolkit found in /usr/local/cuda*"
        exit 1
    fi

    echo "🔧 Using CUDA toolkit: $CUDA_HOME"
    export PATH="${CUDA_HOME}/bin:${PATH}"

    CMAKE_ARGS+=(
        -DGGML_CUDA=ON
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHS}"
    )
else
    CMAKE_ARGS+=(
        -DGGML_CUDA=OFF
    )
fi

echo "🔧 Configuring cmake..."
cmake "${CMAKE_ARGS[@]}"

# ── Build ─────────────────────────────────────────────────────────────────────

NPROC="$(nproc)"
echo "🔨 Building with ${NPROC} jobs..."
cmake --build "$BUILD_DIR" --config Release -j"${NPROC}" --target llama-server

# ── Package ───────────────────────────────────────────────────────────────────

echo "📦 Packaging..."
STAGING_DIR="/tmp/llama-staging/${ARTIFACT_NAME}"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy the binary
cp "${BUILD_DIR}/bin/llama-server" "$STAGING_DIR/"
chmod +x "$STAGING_DIR/llama-server"

# Copy shared libraries if present
find "${BUILD_DIR}" -name '*.so' -o -name '*.so.*' | while read -r lib; do
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
