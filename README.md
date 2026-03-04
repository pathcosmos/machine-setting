# Machine Setting

Portable AI development environment system. One command to set up Python + AI/ML packages + optional Node.js/Java on any machine, with automatic GPU/CPU detection and cross-machine sync.

## Quick Start

```bash
# New machine setup
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
./setup.sh --no-node --no-java --venv local
```

## Profiles

| Profile | GPU | Node | Java | Packages |
|---------|-----|------|------|----------|
| gpu-workstation | Yes | Yes | Yes | core+data+web+gpu |
| cpu-server | No | Yes | Yes | core+data+web+cpu |
| laptop | No | Yes | No | core+data+web+cpu |
| minimal | No | No | No | core only |

## Structure

```
machine_setting/
├── setup.sh              # Single-entry bootstrap
├── Makefile              # make setup/update/push/status
├── config/               # Default + machine-specific config
├── packages/             # Categorized requirements files
├── scripts/              # Individual install + utility scripts
├── shell/bashrc.d/       # Modular shell configuration
├── profiles/             # Pre-configured machine profiles
└── docs/                 # System documentation
```

## Security

- Secrets go in `~/.bashrc.local` (never committed)
- Pre-commit hook blocks AWS keys, GitHub PATs, API keys
- Repository is **PRIVATE**
- Run `make secrets` to scan for leaked credentials
