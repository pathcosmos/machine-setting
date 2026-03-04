# Machine Setting

Portable AI development environment system. One command to set up Python + AI/ML packages + optional Node.js/Java on any machine, with automatic GPU/CPU detection and cross-machine sync.

**Supported platforms**: Linux (x86_64, NVIDIA CUDA) + macOS (Apple Silicon M1+, MPS)
**Supported shells**: bash + zsh

## Quick Start

```bash
# New machine setup (Linux or macOS)
git clone https://github.com/pathcosmos/machine-setting.git ~/machine_setting
cd ~/machine_setting && ./setup.sh

# Activate AI environment
aienv
```

## Daily Usage

```bash
aienv                  # Activate venv + background update check
aienv-off              # Deactivate

make push              # Export packages + commit + push to remote
make update            # Pull changes + notify if packages changed
make status            # Show sync status
make export            # Export current venv to requirements files
```

## CLI Options

```bash
# Interactive (default)
./setup.sh

# Non-interactive
./setup.sh --python 3.12 --venv global --node --java
./setup.sh --profile gpu-workstation
./setup.sh --profile mac-apple-silicon
./setup.sh --no-node --no-java --venv local
```

## Profiles

| Profile | Platform | GPU Backend | Node | Java | Packages |
|---------|----------|-------------|------|------|----------|
| gpu-workstation | Linux | CUDA | Yes | Yes | core+data+web+gpu |
| mac-apple-silicon | macOS | MPS | Yes | No | core+data+web+mps |
| cpu-server | Linux | None | Yes | Yes | core+data+web+cpu |
| laptop | Any | None | Yes | No | core+data+web+cpu |
| minimal | Any | None | No | No | core only |

## GPU Support

| Platform | GPU | Backend | Auto-detected |
|----------|-----|---------|---------------|
| Linux | NVIDIA | CUDA (cu130, cu126, etc.) | lspci + nvcc |
| macOS arm64 | Apple Silicon | MPS (Metal) | uname -m |
| Any | None | CPU fallback | automatic |

## Structure

```
machine_setting/
├── setup.sh              # Single-entry bootstrap
├── Makefile              # make setup/update/push/status
├── config/               # Default + machine-specific config
├── packages/             # Categorized requirements files
│   ├── requirements-core.txt   # Platform-independent AI/ML
│   ├── requirements-gpu.txt    # NVIDIA CUDA packages
│   ├── requirements-mps.txt    # Apple Silicon MPS packages
│   ├── requirements-cpu.txt    # CPU-only fallback
│   ├── requirements-data.txt   # Data/DB packages
│   └── requirements-web.txt    # Web/API packages
├── scripts/              # Individual install + utility scripts
├── shell/bashrc.d/       # Modular shell config (bash + zsh)
├── profiles/             # Pre-configured machine profiles
└── docs/                 # System documentation
```

## Security

- Secrets go in `~/.bashrc.local` or `~/.zshrc.local` (never committed)
- Pre-commit hook blocks AWS keys, GitHub PATs, API keys
- Repository is **PRIVATE**
- Run `make secrets` to scan for leaked credentials
