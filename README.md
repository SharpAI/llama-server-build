# llama-server-build

Automated builds of [llama.cpp](https://github.com/ggml-org/llama.cpp)'s `llama-server` for [Aegis-AI](https://github.com/SharpAI/Aegis-AI).

Produces pre-built binaries for **all platforms**, published as GitHub Releases tagged to match the upstream llama.cpp version (e.g. `b8416`). New releases are auto-detected every 6 hours.

## Build Matrix (14 variants)

### Linux

| Artifact | GPU | SM Targets |
|----------|-----|------------|
| `llama-server-{ver}-linux-x64-cpu.tar.gz` | — | — |
| `llama-server-{ver}-linux-x64-cuda-12.tar.gz` | CUDA 12.8 | 75–120 |
| `llama-server-{ver}-linux-x64-cuda-13.tar.gz` | CUDA 13.1 | 75–120 |
| `llama-server-{ver}-linux-x64-vulkan.tar.gz` | Vulkan | — |
| `llama-server-{ver}-linux-arm64-cpu.tar.gz` | — | — |
| `llama-server-{ver}-linux-arm64-cuda-12.tar.gz` | CUDA 12.8 | 75–120 |
| `llama-server-{ver}-linux-arm64-cuda-13.tar.gz` | CUDA 13.1 | 75–120 |

### Windows

| Artifact | GPU |
|----------|-----|
| `llama-server-{ver}-windows-x64-cpu.zip` | — |
| `llama-server-{ver}-windows-x64-cuda-12.zip` | CUDA 12.4 |
| `llama-server-{ver}-windows-x64-cuda-13.zip` | CUDA 13.1 |
| `llama-server-{ver}-windows-x64-vulkan.zip` | Vulkan |
| `llama-server-{ver}-windows-arm64-cpu.zip` | — |

### macOS

| Artifact | GPU |
|----------|-----|
| `llama-server-{ver}-macos-arm64-metal.tar.gz` | Metal |
| `llama-server-{ver}-macos-x64-cpu.tar.gz` | — |

## How it works

1. **Every 6 hours**, the workflow checks the latest [llama.cpp release](https://github.com/ggml-org/llama.cpp/releases)
2. If our repo doesn't have a matching release, it **automatically builds all 14 variants**
3. Binaries are published as a GitHub Release with the same version tag
4. You can also **manually trigger** a build from the Actions tab

## Download

```bash
VERSION=b8416
curl -L "https://github.com/SharpAI/llama-server-build/releases/download/${VERSION}/llama-server-${VERSION}-linux-x64-cuda-12.tar.gz" \
  -o llama-server-cuda.tar.gz
tar -xzf llama-server-cuda.tar.gz
./llama-server --version
```

## How Aegis-AI uses these builds

Aegis-AI's `config/llama-binary-manifest.json` contains `url_template` entries pointing to this repo's releases. The runtime binary manager downloads the appropriate variant when a user installs or upgrades the AI engine.

## License

The built binaries are subject to the [llama.cpp license](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE) (MIT).
