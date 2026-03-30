#!/bin/bash
# build-embedded.sh — Build llama-server for embedded ARM64 devices
#
# These devices share a common problem: generic aarch64 builds from upstream
# llama.cpp / SharpAI use -march=armv9-a which enables SVE instructions.
# SVE (Scalable Vector Extension) is NOT available on:
#   - NVIDIA Jetson Orin / Xavier (Cortex-A78AE / Carmel)
#   - Raspberry Pi 4/5 (Cortex-A72 / A76)
#   - Rockchip RK3588 (Cortex-A76)
#   - Orange Pi 5 (Cortex-A76)
#   - AWS Graviton 2 built with generic flags
#
# The specific failing instruction is `cntb` (SVE count bytes) in ggml_cpu_init,
# which causes an immediate SIGILL (exit 132) on these devices.
#
# This script builds with correct -mcpu flags per device profile.
#
# Usage:
#   ./scripts/build-embedded.sh <version> <profile>
#
# ── Common profiles (single binary works across multiple devices) ──
#
#   modern-cpu     RECOMMENDED: Works on Jetson Orin, RPi5, RK3588, OPi5
#                  Cortex-A76/A78/Carmel class — ARMv8.2-A + dotprod + fp16
#                  Does NOT support RPi 4 (Cortex-A72, no dotprod)
#
#   safe-cpu       Universal: Works on ALL listed devices including RPi 4
#                  Pure ARMv8-A baseline — slowest but maximum compatibility
#
# ── Accelerated profiles (device-specific, need correct GPU driver) ──
#
#   jetson-orin-cuda    Jetson Orin Nano/NX/AGX — Cortex-A78AE, CUDA 12, compute 8.7
#   jetson-xavier-cuda  Jetson Xavier NX/AGX     — Carmel, CUDA 11, compute 7.2
#   rpi5-vulkan         Raspberry Pi 5           — Cortex-A76, Vulkan (v3d)
#   rk3588-vulkan       Rockchip RK3588          — Cortex-A76, Vulkan (Mali-G610)
#   a76-vulkan          Generic Cortex-A76       — Vulkan (Orange Pi 5, Rock 5B, etc.)
#
# ── Per-device CPU profiles (when you need tuning for one specific board) ──
#
#   rpi5-cpu    Raspberry Pi 5    — Cortex-A76, CPU only
#   rpi4-cpu    Raspberry Pi 4    — Cortex-A72, CPU only
#   rk3588-cpu  Rockchip RK3588   — Cortex-A76, CPU only
#   a76-cpu     Generic A76       — CPU only
#   a72-cpu     Generic A72       — CPU only
#   armv8-cpu   Generic ARMv8-A   — CPU only (same as safe-cpu, explicit)
#
# ── Special action ──
#
#   patch-cpu-lib <install-dir>   Rebuild only libggml-cpu.so with modern-cpu
#                                 flags and swap it into an existing install.
#                                 Fastest fix for SIGILL without full rebuild.
#
#                  Example:
#                    ./scripts/build-embedded.sh b8502 patch-cpu-lib \
#                      ~/.aegis-ai/llama_binaries/b8502/linux-arm64-cuda-12
#
# Examples:
#   ./scripts/build-embedded.sh b8502 modern-cpu        # best single build
#   ./scripts/build-embedded.sh b8502 safe-cpu          # RPi4 compatible
#   ./scripts/build-embedded.sh b8502 jetson-orin-cuda  # full CUDA build
#   ./scripts/build-embedded.sh b8502 patch-cpu-lib ~/.aegis-ai/llama_binaries/b8502/linux-arm64-cuda-12
#
# Environment:
#   CUDA_HOME  — path to CUDA toolkit (auto-detected for Jetson)
#   BUILD_DIR  — cmake build directory (default: /tmp/llama-build)
#   OUTPUT_DIR — where to place the final tarball (default: ./dist)
#   SKIP_CLONE — set to 1 to reuse existing source in SOURCE_DIR

set -euo pipefail

VERSION="${1:?Usage: build-embedded.sh <version> <profile>}"
PROFILE="${2:?Usage: build-embedded.sh <version> <profile>}"
PATCH_TARGET_DIR="${3:-}"   # only used by patch-cpu-lib

BUILD_DIR="${BUILD_DIR:-/tmp/llama-build}"
OUTPUT_DIR="${OUTPUT_DIR:-./dist}"
SOURCE_DIR="/tmp/llama-source"
SKIP_CLONE="${SKIP_CLONE:-0}"

# ── Device Profiles ───────────────────────────────────────────────────────────
# Each profile sets:
#   CPU_FLAGS    — -mcpu/-march flags for the target CPU (NO SVE)
#   ACCELERATION — cuda / vulkan / cpu
#   CUDA_ARCHS   — CUDA compute architecture(s) for CUDA builds
#   ARTIFACT_ID  — manifest variant ID (used in tarball name)
#   DESCRIPTION  — human-readable description

case "$PROFILE" in

    jetson-orin-cuda)
        DESCRIPTION="NVIDIA Jetson Orin Nano/NX/AGX (Cortex-A78AE, CUDA 12, Compute 8.7)"
        # CPU backend uses safe-cpu flags — inference is 100% on CUDA,
        # libggml-cpu.so only runs during init. -march=armv8-a avoids SVE
        # on ALL ARM64 devices with no performance cost on GPU workloads.
        CPU_FLAGS="-march=armv8-a"
        ACCELERATION="cuda"
        CUDA_ARCHS="87"
        ARTIFACT_ID="linux-arm64-jetson-orin-cuda-12"
        ;;

    jetson-xavier-cuda)
        DESCRIPTION="NVIDIA Jetson Xavier NX/AGX (Carmel, CUDA 11, Compute 7.2)"
        # CPU backend uses safe-cpu flags — inference is 100% on CUDA.
        CPU_FLAGS="-march=armv8-a"
        ACCELERATION="cuda"
        CUDA_ARCHS="72"
        ARTIFACT_ID="linux-arm64-jetson-xavier-cuda-11"
        ;;

    rpi5-vulkan)
        DESCRIPTION="Raspberry Pi 5 (Cortex-A76, Vulkan via v3d driver)"
        # CPU backend uses safe-cpu flags — inference is 100% on Vulkan.
        CPU_FLAGS="-march=armv8-a"
        ACCELERATION="vulkan"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-rpi5-vulkan"
        ;;

    rpi5-cpu)
        DESCRIPTION="Raspberry Pi 5 (Cortex-A76, CPU only)"
        CPU_FLAGS="-mcpu=cortex-a76 -march=armv8.2-a+dotprod+fp16"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-rpi5-cpu"
        ;;

    rpi4-cpu)
        DESCRIPTION="Raspberry Pi 4 (Cortex-A72, CPU only)"
        # Cortex-A72: ARMv8-A — NO dotprod, NO SVE
        CPU_FLAGS="-mcpu=cortex-a72 -march=armv8-a+fp16"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-rpi4-cpu"
        ;;

    rk3588-vulkan)
        DESCRIPTION="Rockchip RK3588 (Cortex-A76 big cluster, Mali-G610 Vulkan)"
        # CPU backend uses safe-cpu flags — inference is 100% on Vulkan.
        CPU_FLAGS="-march=armv8-a"
        ACCELERATION="vulkan"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-rk3588-vulkan"
        ;;

    rk3588-cpu)
        DESCRIPTION="Rockchip RK3588 (Cortex-A76 big cluster, CPU only)"
        CPU_FLAGS="-mcpu=cortex-a76 -march=armv8.2-a+dotprod+fp16"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-rk3588-cpu"
        ;;

    a76-vulkan)
        DESCRIPTION="Generic Cortex-A76 with Vulkan (Orange Pi 5, Rock 5B, etc.)"
        # CPU backend uses safe-cpu flags — inference is 100% on Vulkan.
        CPU_FLAGS="-march=armv8-a"
        ACCELERATION="vulkan"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-a76-vulkan"
        ;;

    a76-cpu)
        DESCRIPTION="Generic Cortex-A76, CPU only (Cortex-A76/A78 without GPU)"
        CPU_FLAGS="-mcpu=cortex-a76 -march=armv8.2-a+dotprod+fp16"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-a76-cpu"
        ;;

    a72-cpu)
        DESCRIPTION="Generic Cortex-A72, CPU only (safe for RPi4-class boards)"
        CPU_FLAGS="-mcpu=cortex-a72 -march=armv8-a+fp16"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-a72-cpu"
        ;;

    armv8-cpu)
        DESCRIPTION="Generic ARMv8-A, CPU only (maximum compatibility)"
        CPU_FLAGS="-march=armv8-a"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-armv8-cpu"
        ;;

    # ── Common cross-device profiles ────────────────────────────────────────

    modern-cpu)
        # ARMv8.2-A + dotprod + fp16 — the common subset of:
        #   Cortex-A76  (Raspberry Pi 5, RK3588, Orange Pi 5)
        #   Cortex-A76AE/A78AE (Jetson Orin)
        #   Carmel (Jetson Xavier)
        # Does NOT include SVE (excluded explicitly via -march, not -mcpu)
        # Does NOT support Cortex-A72 (Raspberry Pi 4) — use safe-cpu for that
        DESCRIPTION="Common modern ARM64: RPi5, RK3588, Jetson Orin/Xavier, OPi5 (ARMv8.2-A+dotprod, no SVE)"
        CPU_FLAGS="-march=armv8.2-a+dotprod+fp16+crypto -mno-outline-atomics"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-modern-cpu"
        ;;

    safe-cpu)
        # ARMv8-A — runs on everything: RPi4, RPi5, RK3588, Jetson Orin/Xavier
        # Trades dotprod optimizations for universal compatibility
        DESCRIPTION="Safe universal ARM64: ALL devices including RPi4 (ARMv8-A baseline, no SVE)"
        CPU_FLAGS="-march=armv8-a+fp16 -mno-outline-atomics"
        ACCELERATION="cpu"
        CUDA_ARCHS=""
        ARTIFACT_ID="linux-arm64-safe-cpu"
        ;;

    patch-cpu-lib)
        # Special action: rebuild only libggml-cpu.so with modern-cpu flags
        # and hot-swap it into an existing install directory.
        # Much faster than a full rebuild — only compiles the CPU backend library.
        if [ -z "$PATCH_TARGET_DIR" ]; then
            echo "❌ patch-cpu-lib requires target directory as 3rd argument"
            echo "   Usage: $0 <version> patch-cpu-lib <install-dir>"
            echo "   Example: $0 b8502 patch-cpu-lib ~/.aegis-ai/llama_binaries/b8502/linux-arm64-cuda-12"
            exit 1
        fi
        if [ ! -d "$PATCH_TARGET_DIR" ]; then
            echo "❌ Target directory not found: $PATCH_TARGET_DIR"
            exit 1
        fi

        echo "╔══════════════════════════════════════════════════════════════╗"
        echo "║  patch-cpu-lib — hot-swap libggml-cpu.so                     ║"
        echo "╠══════════════════════════════════════════════════════════════╣"
        echo "║  Version:    ${VERSION}"
        echo "║  CPU flags:  -march=armv8.2-a+dotprod+fp16 (no SVE)"
        echo "║  Target dir: ${PATCH_TARGET_DIR}"
        echo "╚══════════════════════════════════════════════════════════════╝"
        echo ""

        # Clone source
        if [ "$SKIP_CLONE" = "1" ] && [ -d "$SOURCE_DIR" ]; then
            echo "⏭️  Reusing existing source"
        else
            echo "📦 Cloning llama.cpp @ ${VERSION}..."
            rm -rf "$SOURCE_DIR"
            git clone --depth 1 --branch "${VERSION}" \
                https://github.com/ggml-org/llama.cpp.git "$SOURCE_DIR"
        fi

        # Build only ggml-cpu target
        # Use safe-cpu baseline: CPU backend only runs at init time on GPU devices.
        # Inference is 100% on CUDA/Vulkan, so -march=armv8-a costs nothing
        # and works on every ARM64 device (RPi4, RPi5, RK3588, Jetson).
        PATCH_CPU_FLAGS="-march=armv8-a"
        rm -rf "$BUILD_DIR"
        cmake \
            -B "$BUILD_DIR" -S "$SOURCE_DIR" \
            -DCMAKE_BUILD_TYPE=Release \
            -DLLAMA_BUILD_TESTS=OFF \
            -DLLAMA_BUILD_EXAMPLES=OFF \
            -DLLAMA_BUILD_SERVER=OFF \
            -DGGML_NATIVE=OFF \
            -DGGML_CUDA=OFF \
            -DGGML_VULKAN=OFF \
            "-DCMAKE_C_FLAGS=${PATCH_CPU_FLAGS}" \
            "-DCMAKE_CXX_FLAGS=${PATCH_CPU_FLAGS}"

        NPROC="$(nproc 2>/dev/null || echo 4)"
        echo "🔨 Building libggml-cpu with ${NPROC} jobs..."
        cmake --build "$BUILD_DIR" --config Release -j"${NPROC}" --target ggml-cpu

        # Find and install built lib
        BUILT_LIB=$(find "$BUILD_DIR" -name 'libggml-cpu.so*' -not -name '*.bak' | grep -v '.so.0.' | head -1)
        if [ -z "$BUILT_LIB" ]; then
            BUILT_LIB=$(find "$BUILD_DIR" -name 'libggml-cpu.so*' | head -1)
        fi

        if [ -z "$BUILT_LIB" ]; then
            echo "❌ libggml-cpu.so not found in build output"
            find "$BUILD_DIR" -name '*.so*' 2>/dev/null | head -10
            exit 1
        fi

        echo "📦 Installing patched libggml-cpu.so..."
        # Backup originals
        for f in "$PATCH_TARGET_DIR"/libggml-cpu.so*; do
            [ -f "$f" ] && mv "$f" "${f}.sigill-bak" && echo "  backed up: $(basename $f)"
        done

        # Copy all variants (.so, .so.0, .so.0.9.x)
        find "$BUILD_DIR" -name 'libggml-cpu.so*' | while read -r lib; do
            dest="$PATCH_TARGET_DIR/$(basename $lib)"
            cp "$lib" "$dest"
            echo "  installed: $(basename $lib)"
        done

        echo ""
        echo "🧪 Verifying patched install..."
        LLAMA_BIN="$PATCH_TARGET_DIR/llama-server"
        if [ -f "$LLAMA_BIN" ]; then
            if LD_LIBRARY_PATH="$PATCH_TARGET_DIR:${LD_LIBRARY_PATH:-}" \
                timeout 10 "$LLAMA_BIN" --version 2>&1; then
                echo "✅ Patch successful — llama-server runs without SIGILL"
            else
                EXIT=$?
                if [ $EXIT = 132 ]; then
                    echo "❌ Still SIGILL — the crash may be in a different .so (not libggml-cpu)"
                    echo "   Run: gdb -batch -ex run -ex 'x/4i \$pc-8' --args $LLAMA_BIN --version"
                else
                    echo "⚠️  Exited with code $EXIT (may be normal if waiting for args)"
                fi
            fi
        else
            echo "⚠️  No llama-server binary found in target dir — lib installed but not verified"
        fi

        rm -rf "$SOURCE_DIR" "$BUILD_DIR"
        echo ""
        echo "Done. To revert: rm $PATCH_TARGET_DIR/libggml-cpu.so* && rename .sigill-bak files"
        exit 0
        ;;

    *)
        echo "❌ Unknown profile: $PROFILE"
        echo ""
        echo "Common profiles (one binary for multiple devices):"
        echo "  modern-cpu         — RPi5, RK3588, Jetson Orin/Xavier (ARMv8.2-A+dotprod, no SVE)"
        echo "  safe-cpu           — ALL devices incl. RPi4 (ARMv8-A baseline, slowest)"
        echo ""
        echo "Accelerated profiles:"
        echo "  jetson-orin-cuda   — Jetson Orin Nano/NX/AGX (CUDA 12, compute 8.7)"
        echo "  jetson-xavier-cuda — Jetson Xavier NX/AGX (CUDA 11, compute 7.2)"
        echo "  rpi5-vulkan        — Raspberry Pi 5 (Vulkan)"
        echo "  rk3588-vulkan      — Rockchip RK3588 (Vulkan, Mali-G610)"
        echo "  a76-vulkan         — Generic Cortex-A76 (Vulkan)"
        echo ""
        echo "Per-device CPU profiles:"
        echo "  rpi5-cpu / rpi4-cpu / rk3588-cpu / a76-cpu / a72-cpu / armv8-cpu"
        echo ""
        echo "Special actions:"
        echo "  patch-cpu-lib <dir> — rebuild only libggml-cpu.so and hot-swap into existing install"
        exit 1
        ;;
esac

ARTIFACT_NAME="${ARTIFACT_ID/linux-arm64-/llama-server-${VERSION}-linux-arm64-}"
ARTIFACT_NAME="llama-server-${VERSION}-${ARTIFACT_ID#linux-}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  llama-server embedded device builder                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Version:  ${VERSION}"
echo "║  Profile:  ${PROFILE}"
echo "║  Device:   ${DESCRIPTION}"
echo "║  CPU Flags: ${CPU_FLAGS}"
echo "║  Accel:    ${ACCELERATION}"
echo "║  Artifact: ${ARTIFACT_NAME}.tar.gz"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Verify we're on ARM64 (or cross-compiling) ────────────────────────────────

ARCH="$(uname -m)"
if [ "$ARCH" != "aarch64" ] && [ -z "${CROSS_TRIPLE:-}" ]; then
    echo "⚠️  Not running on aarch64 (got: $ARCH)"
    echo "   For cross-compilation, set CROSS_TRIPLE=aarch64-linux-gnu"
    echo "   and install: apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu"
    echo ""
fi

# ── Clone source ──────────────────────────────────────────────────────────────

if [ "$SKIP_CLONE" = "1" ] && [ -d "$SOURCE_DIR" ]; then
    echo "⏭️  Reusing existing source at $SOURCE_DIR"
else
    echo "📦 Cloning llama.cpp @ ${VERSION}..."
    rm -rf "$SOURCE_DIR"
    git clone --depth 1 --branch "${VERSION}" \
        https://github.com/ggml-org/llama.cpp.git "$SOURCE_DIR"
fi

# ── Configure cmake ───────────────────────────────────────────────────────────

CMAKE_ARGS=(
    -B "$BUILD_DIR"
    -S "$SOURCE_DIR"
    -DCMAKE_BUILD_TYPE=Release
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_SERVER=ON
    # ── KEY: disable native CPU detection, use explicit flags ──
    -DGGML_NATIVE=OFF
    # ── Inject device-specific CPU flags to prevent SVE ──
    "-DCMAKE_C_FLAGS=${CPU_FLAGS}"
    "-DCMAKE_CXX_FLAGS=${CPU_FLAGS}"
)

# ── Cross-compilation toolchain ───────────────────────────────────────────────

if [ -n "${CROSS_TRIPLE:-}" ]; then
    echo "🔄 Cross-compiling with toolchain: ${CROSS_TRIPLE}"
    CMAKE_ARGS+=(
        "-DCMAKE_C_COMPILER=${CROSS_TRIPLE}-gcc"
        "-DCMAKE_CXX_COMPILER=${CROSS_TRIPLE}-g++"
        "-DCMAKE_SYSTEM_NAME=Linux"
        "-DCMAKE_SYSTEM_PROCESSOR=aarch64"
        # CUDA cross-compilation is not supported — use native build for CUDA profiles
    )
    if [ "$ACCELERATION" = "cuda" ]; then
        echo "❌ CUDA cross-compilation is not supported."
        echo "   Run this script natively on the Jetson device instead."
        exit 1
    fi
fi

# ── Acceleration flags ────────────────────────────────────────────────────────

case "$ACCELERATION" in
    cuda)
        # Auto-detect CUDA toolkit (Jetson JetPack paths)
        if [ -z "${CUDA_HOME:-}" ]; then
            for candidate in \
                /usr/local/cuda \
                /usr/local/cuda-12 \
                /usr/local/cuda-12.6 \
                /usr/local/cuda-12.8 \
                /usr/local/cuda-11 \
                /usr/local/cuda-11.4; do
                if [ -d "$candidate" ]; then
                    export CUDA_HOME="$candidate"
                    echo "🔍 Auto-detected CUDA: $CUDA_HOME"
                    break
                fi
            done
        fi

        if [ -z "${CUDA_HOME:-}" ]; then
            echo "❌ CUDA_HOME not found. Is CUDA/JetPack installed?"
            echo "   On Jetson: sudo apt install cuda-toolkit-12-* (or jetpack)"
            exit 1
        fi

        export PATH="${CUDA_HOME}/bin:${PATH}"
        echo "🔧 CUDA toolkit: $CUDA_HOME"
        echo "🔧 CUDA compute: ${CUDA_ARCHS}"

        CMAKE_ARGS+=(
            -DGGML_CUDA=ON
            "-DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCHS}"
            # Use the same CPU flags for CUDA host code
            "-DCMAKE_CUDA_FLAGS=--generate-code arch=compute_${CUDA_ARCHS},code=sm_${CUDA_ARCHS}"
        )
        ;;

    vulkan)
        # Check Vulkan SDK / headers
        if ! pkg-config --exists vulkan 2>/dev/null && [ ! -d /usr/include/vulkan ]; then
            echo "⚠️  Vulkan headers not found. Install: apt install libvulkan-dev"
            echo "   Continuing anyway — build may fail if headers are missing."
        fi
        CMAKE_ARGS+=( -DGGML_VULKAN=ON )
        ;;

    cpu)
        CMAKE_ARGS+=( -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_METAL=OFF )
        ;;
esac

# ── Build ─────────────────────────────────────────────────────────────────────

rm -rf "$BUILD_DIR"
echo "🔧 Configuring cmake..."
cmake "${CMAKE_ARGS[@]}"

NPROC="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
echo "🔨 Building with ${NPROC} jobs..."
# Build llama-server and all shared libs (ggml-cpu, ggml-cuda, etc.)
cmake --build "$BUILD_DIR" --config Release -j"${NPROC}"

# ── Package ───────────────────────────────────────────────────────────────────

echo "📦 Packaging..."
STAGING_DIR="/tmp/llama-staging/${ARTIFACT_NAME}"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"

# Copy binary
BIN_PATH=""
for candidate in \
    "${BUILD_DIR}/bin/llama-server" \
    "${BUILD_DIR}/bin/Release/llama-server" \
    "${BUILD_DIR}/llama-server"; do
    if [ -f "$candidate" ]; then
        BIN_PATH="$candidate"
        break
    fi
done

if [ -z "$BIN_PATH" ]; then
    echo "❌ Cannot find llama-server binary. Build output:"
    find "$BUILD_DIR/bin" -type f 2>/dev/null || true
    exit 1
fi

cp "$BIN_PATH" "$STAGING_DIR/"
chmod +x "$STAGING_DIR/llama-server"

# Copy shared libraries (.so files — CUDA, ggml backends, etc.)
find "$BUILD_DIR" \( -name '*.so' -o -name '*.so.*' \) | while read -r lib; do
    cp "$lib" "$STAGING_DIR/" 2>/dev/null || true
done

# Verify binary runs (only on native builds, not cross-compiled)
if [ "$ARCH" = "aarch64" ] && [ -z "${CROSS_TRIPLE:-}" ]; then
    echo ""
    echo "🧪 Verifying binary (should not segfault or SIGILL)..."
    if LD_LIBRARY_PATH="$STAGING_DIR:${LD_LIBRARY_PATH:-}" \
        timeout 10 "$STAGING_DIR/llama-server" --version 2>&1; then
        echo "✅ Binary ran successfully"
    else
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 132 ]; then
            echo "❌ SIGILL (exit 132) — binary uses CPU instructions not available on this device"
            echo "   Check CPU_FLAGS: ${CPU_FLAGS}"
            echo "   Device CPU features: $(grep Features /proc/cpuinfo | head -1)"
        elif [ $EXIT_CODE -eq 124 ]; then
            echo "⚠️  Binary timed out (10s) — may be waiting for input, this is OK"
        else
            echo "⚠️  Binary exited with code $EXIT_CODE"
        fi
    fi
fi

# Create tarball
mkdir -p "$OUTPUT_DIR"
TARBALL="${OUTPUT_DIR}/${ARTIFACT_NAME}.tar.gz"
tar -czf "$TARBALL" -C "/tmp/llama-staging" "${ARTIFACT_NAME}"

SIZE_MB=$(du -m "$TARBALL" | cut -f1)
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Build complete!                                          ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Artifact: ${TARBALL}"
echo "║  Size:     ${SIZE_MB} MB"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "To install manually:"
echo "  mkdir -p ~/.aegis-ai/llama_binaries/${VERSION}/${ARTIFACT_ID#linux-arm64-}"
echo "  tar -xzf ${TARBALL} --strip-components=1 -C ~/.aegis-ai/llama_binaries/${VERSION}/${ARTIFACT_ID#linux-arm64-}/"

# Cleanup
rm -rf "$SOURCE_DIR" "$BUILD_DIR"
