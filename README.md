# llama-server-build

Automated builds of [llama.cpp](https://github.com/ggml-org/llama.cpp)'s `llama-server` for [Aegis-AI](https://github.com/SharpAI/Aegis-AI).

Produces pre-built binaries for **all platforms**, published as GitHub Releases tagged to match the upstream llama.cpp version (e.g. `b8502`). New releases are auto-detected weekly (Monday 04:00 UTC).

## Build Matrix

### Linux x64

| Artifact | GPU | SM Targets |
|----------|-----|------------|
| `llama-server-{ver}-linux-x64-cpu.tar.gz` | — | — |
| `llama-server-{ver}-linux-x64-cuda-12.tar.gz` | CUDA 12.8 | 75–120 |
| `llama-server-{ver}-linux-x64-cuda-13.tar.gz` | CUDA 13.1 | 75–120 |
| `llama-server-{ver}-linux-x64-vulkan.tar.gz` | Vulkan | — |

### Linux ARM64 — Generic

| Artifact | GPU |
|----------|-----|
| `llama-server-{ver}-linux-arm64-cpu.tar.gz` | — |
| `llama-server-{ver}-linux-arm64-cuda-12.tar.gz` | CUDA 12 |
| `llama-server-{ver}-linux-arm64-cuda-13.tar.gz` | CUDA 13 |

> **⚠️ Note on generic ARM64 builds:** These are compiled with `-march=armv9-a` which enables SVE instructions not available on Cortex-A72/A76/A78AE CPUs (Raspberry Pi 4/5, Jetson Orin, RK3588). If you see `signal=SIGILL` (exit 132), use the embedded device builds below.

### Linux ARM64 — Embedded Devices (no SVE, safe for all boards)

Built with device-appropriate `-march` flags. CPU backend uses `-march=armv8-a` on all GPU-accelerated variants since inference runs on CUDA/Vulkan.

| Artifact | Device | Accel | CPU flags |
|----------|--------|-------|-----------|
| `llama-server-{ver}-arm64-jetson-orin-cuda-12.tar.gz` | Jetson Orin Nano/NX/AGX | CUDA 12 | `-march=armv8-a` |
| `llama-server-{ver}-arm64-jetson-xavier-cuda-11.tar.gz` | Jetson Xavier NX/AGX | CUDA 11 | `-march=armv8-a` |
| `llama-server-{ver}-arm64-rpi5-vulkan.tar.gz` | Raspberry Pi 5 | Vulkan | `-march=armv8-a` |
| `llama-server-{ver}-arm64-rk3588-vulkan.tar.gz` | Rockchip RK3588 | Vulkan | `-march=armv8-a` |
| `llama-server-{ver}-arm64-a76-vulkan.tar.gz` | Orange Pi 5, Rock 5B | Vulkan | `-march=armv8-a` |
| `llama-server-{ver}-arm64-rpi5-cpu.tar.gz` | Raspberry Pi 5 | CPU | `-mcpu=cortex-a76` |
| `llama-server-{ver}-arm64-rpi4-cpu.tar.gz` | Raspberry Pi 4 | CPU | `-mcpu=cortex-a72` |
| `llama-server-{ver}-arm64-modern-cpu.tar.gz` | RPi5, RK3588, Jetson | CPU | `-march=armv8.2-a+dotprod` |
| `llama-server-{ver}-arm64-safe-cpu.tar.gz` | All ARM64 boards | CPU | `-march=armv8-a` |

### Windows / macOS

| Artifact | GPU |
|----------|-----|
| `llama-server-{ver}-windows-x64-cuda-12.zip` | CUDA 12.4 |
| `llama-server-{ver}-windows-x64-cuda-13.zip` | CUDA 13.1 |
| `llama-server-{ver}-windows-x64-vulkan.zip` | Vulkan |
| `llama-server-{ver}-windows-x64-cpu.zip` | — |
| `llama-server-{ver}-windows-arm64-cpu.zip` | — |
| `llama-server-{ver}-macos-arm64-metal.tar.gz` | Metal |
| `llama-server-{ver}-macos-x64-cpu.tar.gz` | — |

---

## Building locally

The `scripts/build-embedded.sh` script lets you build any variant locally on your device.

### Quick SIGILL fix (Jetson / RPi / RK3588)

If you already have a binary installed but it crashes with `signal=SIGILL`, use `patch-cpu-lib` to rebuild only `libggml-cpu.so` with safe flags and swap it in:

```bash
git clone https://github.com/SharpAI/llama-server-build.git
cd llama-server-build

# Replace the SVE-crashing libggml-cpu.so in your existing install:
./scripts/build-embedded.sh b8502 patch-cpu-lib \
  ~/.aegis-ai/llama_binaries/b8502/linux-arm64-cuda-12

# Takes ~5 minutes. Verifies automatically on completion.
```

### Full builds by profile

```bash
# Single binary for Jetson Orin/Xavier, RPi 5, RK3588 (modern boards, no RPi4):
./scripts/build-embedded.sh b8502 modern-cpu

# Universal binary — all boards including RPi 4:
./scripts/build-embedded.sh b8502 safe-cpu

# Jetson Orin with CUDA (run natively on the device):
./scripts/build-embedded.sh b8502 jetson-orin-cuda

# Raspberry Pi 5 with Vulkan:
./scripts/build-embedded.sh b8502 rpi5-vulkan

# Rockchip RK3588 with Vulkan (Mali-G610):
./scripts/build-embedded.sh b8502 rk3588-vulkan

# Raspberry Pi 4, CPU only:
./scripts/build-embedded.sh b8502 rpi4-cpu
```

### Install output

All builds produce a tarball in `./dist/`. Install into Aegis-AI:

```bash
VERSION=b8502
PROFILE=jetson-orin-cuda-12  # or rpi5-vulkan, rk3588-vulkan, etc.

mkdir -p ~/.aegis-ai/llama_binaries/${VERSION}/${PROFILE}/
tar -xzf dist/llama-server-${VERSION}-arm64-${PROFILE}.tar.gz \
  --strip-components=1 \
  -C ~/.aegis-ai/llama_binaries/${VERSION}/${PROFILE}/
```

### Cross-compilation (CPU/Vulkan profiles only)

On an x86_64 Linux host, install the aarch64 cross-toolchain and set `CROSS_TRIPLE`:

```bash
sudo apt install gcc-aarch64-linux-gnu g++-aarch64-linux-gnu

CROSS_TRIPLE=aarch64-linux-gnu \
  ./scripts/build-embedded.sh b8502 safe-cpu
```

> CUDA profiles require building natively on the target device.

---

## How it works

1. **Weekly** (Monday 04:00 UTC), the workflow checks the latest [llama.cpp release](https://github.com/ggml-org/llama.cpp/releases)
2. If the repo doesn't have a matching release it **automatically builds all variants**
3. Binaries are published as a GitHub Release with the same version tag
4. You can also **manually trigger** a build from the Actions tab

## How Aegis-AI uses these builds

Aegis-AI's `config/llama-binary-manifest.json` contains `url_template` entries pointing to this repo's releases. The runtime binary manager downloads the appropriate variant when a user installs or upgrades the AI engine.

## License

The built binaries are subject to the [llama.cpp license](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE) (MIT).
