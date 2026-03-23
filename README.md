# llama-server-build

Automated builds of [llama.cpp](https://github.com/ggml-org/llama.cpp)'s `llama-server` for [Aegis-AI](https://github.com/solderzzc/Aegis-AI).

Produces pre-built binaries for Linux (CPU and CUDA 12.8) on both x64 and arm64, published as GitHub Releases tagged to match the upstream llama.cpp version (e.g. `b8416`).

## Build Matrix

| Artifact | Runner | GPU | SM Targets |
|----------|--------|-----|------------|
| `llama-server-{ver}-linux-x64-cpu.tar.gz` | ubuntu-22.04 | — | — |
| `llama-server-{ver}-linux-x64-cuda-12.tar.gz` | ubuntu-22.04 | CUDA 12.8 | 75–120 |
| `llama-server-{ver}-linux-arm64-cpu.tar.gz` | ubuntu-22.04-arm | — | — |
| `llama-server-{ver}-linux-arm64-cuda-12.tar.gz` | ubuntu-22.04-arm | CUDA 12.8 | 75–120 |

### SM Architecture Coverage

| SM | Hardware |
|----|----------|
| 75 | RTX 20xx, Tesla T4 (Turing) |
| 80 | A100 (Ampere) |
| 86 | RTX 30xx (Ampere) |
| 89 | RTX 40xx, L4, L40 (Ada) |
| 90 | H100, H200 (Hopper) |
| 100 | B200 (Blackwell server) |
| 120 | RTX 50xx, DGX Spark (Blackwell) |

## Usage

### Trigger a build

Go to **Actions → Build llama-server → Run workflow** and enter the upstream version tag (e.g. `b8416`).

### Download a release

```bash
VERSION=b8416
curl -L "https://github.com/SharpAI/llama-server-build/releases/download/${VERSION}/llama-server-${VERSION}-linux-x64-cuda-12.tar.gz" \
  -o llama-server-cuda.tar.gz
tar -xzf llama-server-cuda.tar.gz
./llama-server --version
```

## How Aegis-AI uses these builds

Aegis-AI's `config/llama-binary-manifest.json` contains `url_template` entries pointing to this repo's releases. The runtime binary manager (`llama-binary-manager.cjs`) downloads the appropriate variant when a user installs or upgrades the AI engine.

## License

The built binaries are subject to the [llama.cpp license](https://github.com/ggml-org/llama.cpp/blob/master/LICENSE) (MIT).
