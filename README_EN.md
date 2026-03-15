# Machine Setting

> **English** | [한국어](README.md)

Portable AI development environment system. One command to set up Python + AI/ML packages + optional Node.js/Java on any machine, with automatic GPU/CPU detection and cross-machine sync.

**Supported platforms**: Linux (x86_64, NVIDIA CUDA) + macOS (Apple Silicon M1+, MPS) + Cloud/Container (Docker, K8s, AWS/GCP/Azure)
**Supported shells**: bash + zsh

---

## Table of Contents

- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Installation Flow](#installation-flow)
- [Installed Components](#installed-components)
- [Daily Usage](#daily-usage)
- [CLI Options](#cli-options)
- [Profiles](#profiles)
- [GPU Support](#gpu-support)
- [Pre-flight Check](#pre-flight-check)
- [Reinstallation](#reinstallation)
- [Uninstall](#uninstall)
- [Health Check & Recovery](#health-check--recovery)
- [Cross-Machine Sync](#cross-machine-sync)
- [Disk Health & Monitoring](#disk-health--monitoring)
- [Shell Integration Details](#shell-integration-details)
- [Directory Structure](#directory-structure)
- [State & Configuration Files](#state--configuration-files)
- [Troubleshooting](#troubleshooting)
- [Security](#security)

---

## Quick Start

```bash
# New machine setup (Linux or macOS)
git clone https://github.com/pathcosmos/machine-setting.git ~/machine_setting
cd ~/machine_setting && ./setup.sh

# Cloud/container setup (user-space only, no sudo needed)
./setup.sh --cloud

# Activate AI environment
aienv
```

---

## How It Works

### Overview

`setup.sh` operates as a 7-stage pipeline, with each stage tracked by a **checkpoint system**. If installation fails midway, completed stages are skipped and execution resumes from the failure point.

### Execution Flow

```
./setup.sh
    |
    +-- 1) Pre-flight Check (interactive mode)
    |     Scans system state and shows what needs to be done
    |     User can toggle components on/off
    |
    +-- 2) Previous state check
    |     Reads progress from ~/.machine_setting/install.state
    |     -> If previous failure: Resume / Reset / Cancel menu
    |     -> If all done: Reinstall / Cancel menu
    |
    +-- 3) 7-stage installation pipeline
          Checkpoint recorded per stage -> auto-rollback on failure
```

### Checkpoint System

All installation state is recorded in `~/.machine_setting/install.state`:

```
STAGE_1_HARDWARE=done
STAGE_2_NVIDIA=done
STAGE_3_PYTHON=done
STAGE_4_VENV=in_progress    <- failed at this stage
STAGE_5_NODE=pending
STAGE_6_JAVA=pending
STAGE_7_SHELL=pending
```

When a stage fails:
1. Stage state is recorded as `failed`
2. **Auto-rollback** executes (removes what was installed in that stage)
3. Next run can resume from the failure point

---

## Installation Flow

### [1/7] Hardware Detection

Auto-detects system hardware and saves results to `~/.machine_setting_profile`.

| Detection | Linux | macOS |
|-----------|-------|-------|
| GPU | `lspci` + `nvidia-smi` (fallback) | `system_profiler` (Apple Silicon) |
| CUDA version | `nvcc --version` / `nvidia-smi` | N/A (uses MPS) |
| CPU/RAM | `/proc/cpuinfo`, `/proc/meminfo` | `sysctl` |
| NGC container | torch NV version check + `/opt/nvidia` exists | N/A |
| Cloud/Container | Docker, K8s, cgroup, cloud VM vendor, sudo availability | N/A |

> **Container GPU detection:** GPU is detected via `nvidia-smi` fallback even in containers without `lspci`.

Optimal profile is auto-selected based on detection results:
- Apple Silicon -> `mac-apple-silicon`
- NGC container -> `ngc-container`
- Cloud/Container environment -> `cloud-server`
- NVIDIA GPU -> `gpu-workstation`
- RAM >= 32GB (no GPU) -> `cpu-server`
- RAM >= 8GB -> `laptop`
- Otherwise -> `minimal`

### [2/7] NVIDIA GPU Stack (Linux only)

Automatically installs the system-level NVIDIA GPU software stack. `scripts/install-nvidia.sh` runs 9 sub-stages.

**Auto-skip conditions:** Non-Linux OS, no NVIDIA GPU detected, NGC container (already installed), `INSTALL_NVIDIA=false`

**GPU tier auto-classification:**

| Tier | GPU examples | Behavior |
|------|-------------|----------|
| Consumer | GeForce RTX 3090/4090 | Standard install (driver + CUDA + cuDNN + NCCL) |
| Professional | RTX A6000, L40 | Standard install |
| Datacenter | A100, H100, H200, B200 | Standard + enterprise tools auto-enabled |

**Installed components:**

| Component | Description | Config |
|-----------|-------------|--------|
| NVIDIA Driver | `ubuntu-drivers` auto-recommend or manual version | `NVIDIA_DRIVER_VERSION` |
| CUDA Toolkit | `cuda-toolkit` meta-package, `/usr/local/cuda` symlink | `NVIDIA_CUDA_VERSION` |
| cuDNN 9.x | DNN acceleration library (`cudnn9-cuda-XX`) | Auto |
| NCCL | Multi-GPU collective communication (skipped for single GPU) | Auto |
| Container Toolkit | Docker GPU support (skipped if Docker not installed) | `NVIDIA_CONTAINER_TOOLKIT` |
| Enterprise Tools | DCGM, Fabric Manager, GDS, nvidia-peermem | `NVIDIA_ENTERPRISE` |
| System Utilities | numactl, hwloc, nvtop, lm-sensors, build-essential, cmake | `NVIDIA_SYSTEM_TOOLS` |
| Kernel Tuning | sysctl (vm.max_map_count, shmmax, etc.), memlock limits, CPU governor | `NVIDIA_KERNEL_TUNING` |

**Open vs Proprietary Kernel Modules:**
- `NVIDIA_OPEN_KERNEL=auto` (default): Turing+ (RTX 20xx and later) -> open, older -> proprietary
- `NVIDIA_OPEN_KERNEL=true`: Force open kernel modules
- `NVIDIA_OPEN_KERNEL=false`: Force proprietary kernel modules

**Secure Boot:** MOK (Machine Owner Key) enrollment guidance is displayed automatically.

**Kernel tuning details:**
- `vm.max_map_count=1048576` (large memory mappings)
- Dynamic `shmmax`/`shmall` computed from RAM
- `memlock unlimited` (GPU memory locking)
- TCP buffer optimization (for distributed training)
- CPU governor -> performance

### [3/7] Python Setup

Installs Python via [uv](https://github.com/astral-sh/uv) (default: 3.12).

- Auto-installs uv if not present (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- `uv python install 3.12` for managed Python installation
- Does not affect system Python

### [4/7] AI Environment (Virtual Environment + Packages)

Creates venv and installs packages by group.

**Venv location options:**
| Mode | Path | Use case |
|------|------|----------|
| global (default) | `~/ai-env` | Shared across all projects |
| local | `./.venv` | Current project only |
| custom | User-specified path | Specific partition, etc. |

**Package groups:**
| Group | File | Contents |
|-------|------|----------|
| core | `requirements-core.txt` | transformers, accelerate, peft, wandb, numpy, mlflow, tensorboard, optuna, etc. |
| data | `requirements-data.txt` | pandas, polars, duckdb, SQLAlchemy, psycopg2, pypdf, openpyxl, etc. |
| web | `requirements-web.txt` | fastapi, uvicorn, httpx, gradio, cryptography, etc. |
| gpu | `requirements-gpu.txt` | torch+CUDA, triton, bitsandbytes, deepspeed, vllm, pynvml, nvitop, etc. |
| mps | `requirements-mps.txt` | torch (with Apple Silicon MPS) |
| cpu | `requirements-cpu.txt` | torch CPU-only build |

GPU/MPS/CPU packages are auto-selected based on hardware detected in [1/7].

**Disk requirements:** Minimum 15GB free space recommended (with GPU packages)

#### core — Core AI/ML (`requirements-core.txt`, ~160 packages)

| Category | Packages | Description |
|----------|----------|-------------|
| **LLM Providers** | `anthropic`, `openai`, `google-generativeai` + 7 Google API packages | Claude, GPT, Gemini APIs |
| **LangChain** | `langchain`, `langchain-community`, `langchain-core`, `langchain-huggingface`, `langgraph`, `langgraph-checkpoint`, `langgraph-prebuilt`, `langgraph-sdk`, `langsmith` | Agents/chains/graphs |
| **HuggingFace** | `transformers`, `datasets`, `tokenizers`, `huggingface_hub`, `accelerate`, `peft`, `trl`, `sentence-transformers`, `safetensors`, `hf-xet`, `sentencepiece` | Model training/inference/fine-tuning |
| **Classical ML** | `scikit-learn`, `scipy`, `xgboost`, `lightgbm`, `numba`, `llvmlite` | Traditional machine learning |
| **Vector/Embedding** | `chromadb`, `faiss-cpu` | Vector DB/similarity search |
| **Visualization** | `matplotlib`, `seaborn`, `contourpy`, `cycler`, `fonttools`, `kiwisolver` | Charts/graphs |
| **Experiment Tracking** | `wandb`, `mlflow`, `tensorboard`, `optuna` | Experiment tracking/hyperparameter optimization |
| **Scientific** | `sympy`, `mpmath`, `networkx`, `shapely`, `h5py` | Math/graph/geo/HDF5 |
| **Audio** | `pydub`, `ffmpy` | Audio processing/conversion |
| **Testing** | `pytest`, `pytest-asyncio` | Unit/async testing |
| **NLP/Text** | `regex`, `python-bidi`, `Markdown`, `markdown-it-py`, `rich`, `Pygments` | Text processing/rendering |
| **Utilities** | `pydantic`, `pydantic-settings`, `python-dotenv`, `click`, `typer`, `loguru`, `structlog`, `tqdm`, `coloredlogs`, `humanfriendly`, `prettytable`, `py-cpuinfo`, `tenacity`, `backoff` | Config/CLI/logging/retry |
| **Async** | `anyio`, `aiofiles`, `aiohappyeyeballs`, `aiosignal`, `frozenlist`, `multidict`, `yarl` | Async IO |
| **Serialization** | `typing_extensions`, `marshmallow`, `dataclasses-json`, `jsonschema`, `jsonpatch`, `PyYAML`, `ruamel.yaml` | Schema/serialization (YAML comment-preserving) |
| **gRPC/Protobuf** | `grpcio`, `grpcio-status`, `proto-plus`, `protobuf` | RPC communication |
| **Monitoring** | `opentelemetry-api`, `opentelemetry-sdk`, `opentelemetry-exporter-otlp-proto-grpc` + 3 more, `posthog` | Telemetry/analytics |
| **Infra** | `kubernetes`, `GitPython`, `APScheduler`, `psutil`, `watchdog` | K8s/Git/scheduling |
| **Build** | `packaging`, `setuptools`, `wheel`, `build`, `ninja` | Package build tools |

#### gpu — NVIDIA GPU (`requirements-gpu.txt`, ~15 packages)

| Category | Packages | Description |
|----------|----------|-------------|
| **PyTorch** | `torch`, `torchaudio`, `torchvision`, `triton` | GPU builds via CUDA index URL |
| **CUDA Bindings** | `cuda-bindings`, `cuda-pathfinder` | CUDA Python bindings |
| **GPU Acceleration** | `flash-attn`, `bitsandbytes`, `onnxruntime-gpu` | FlashAttention/quantization/GPU inference |
| **Distributed Training** | `deepspeed`, `pytorch-lightning`, `torchmetrics` | Multi-GPU training |
| **GPU Monitoring** | `pynvml`, `gpustat`, `nvitop` | GPU usage/temperature monitoring |
| **Inference Optimization** | `vllm`, `optimum` | High-speed LLM serving/model optimization |

> **Note:** `nvidia-*` runtime libraries are auto-resolved as `torch` dependencies and not pinned here. Pinning them breaks cross-CUDA-version compatibility.

#### data — Data Processing (`requirements-data.txt`, ~40 packages)

| Category | Packages | Description |
|----------|----------|-------------|
| **DataFrames** | `pandas`, `pyarrow`, `numpy`, `polars`, `duckdb`, `connectorx` | Data analysis/query engines |
| **DB Drivers** | `SQLAlchemy`, `alembic`, `psycopg2-binary`, `PyMySQL`, `oracledb`, `cx-Oracle`, `clickhouse-connect`, `clickhouse-driver` | PostgreSQL/MySQL/Oracle/ClickHouse |
| **Document Processing** | `pdfplumber`, `pdfminer.six`, `pypdf`, `pypdfium2`, `python-docx`, `python-pptx`, `openpyxl`, `xlsxwriter`, `lxml` | PDF/Word/Excel/PPT parsing |
| **Image** | `pillow`, `opencv-python`, `opencv-python-headless`, `scikit-image`, `ImageIO` | Image processing/CV |
| **OCR** | `easyocr`, `pytesseract` | Optical character recognition |
| **Scraping** | `beautifulsoup4` | HTML parsing/web scraping |
| **Statistics/Explainability** | `statsmodels`, `shap` | Statistical models/explainability |
| **Serialization** | `orjson`, `ormsgpack`, `jsonlines`, `ujson` | High-speed JSON/MsgPack |
| **Messaging** | `aiokafka`, `kafka-python`, `paho-mqtt` | Kafka/MQTT streaming |
| **Cloud Storage** | `boto3`, `botocore`, `s3transfer` | AWS S3 |

Optional (install on demand): `paddleocr`, `paddlepaddle`, `paddlex`, `opencv-contrib-python`, `ultralytics` — see comment at bottom of `requirements-data.txt`.

#### web — Web/API (`requirements-web.txt`, ~25 packages)

| Category | Packages | Description |
|----------|----------|-------------|
| **Frameworks** | `fastapi`, `starlette`, `uvicorn`, `uvloop`, `Flask`, `Werkzeug`, `gradio`, `gradio_client` | REST API/UI servers |
| **HTTP Clients** | `httpx`, `httpx-sse`, `httpcore`, `requests`, `requests-oauthlib`, `aiohttp` | Sync/async HTTP |
| **Server Utilities** | `h11`, `httptools`, `websockets`, `websocket-client`, `watchfiles`, `python-multipart` | High-performance server/WebSocket |
| **Templating** | `Jinja2`, `MarkupSafe`, `itsdangerous` | HTML rendering |
| **Auth/Security** | `PyJWT`, `bcrypt`, `cryptography`, `pyOpenSSL` | JWT/encryption/TLS |
| **Monitoring** | `prometheus_client`, `sentry-sdk` | Metrics/error tracking |

#### cpu — CPU Only (`requirements-cpu.txt`, 4 packages)

| Package | Description |
|---------|-------------|
| `torch`, `torchaudio`, `torchvision` | CPU builds (PyTorch CPU index URL) |
| `onnxruntime` | CPU inference engine |

#### mps — Apple Silicon (`requirements-mps.txt`, 4 packages)

| Package | Description |
|---------|-------------|
| `torch`, `torchaudio`, `torchvision` | Default PyPI builds (MPS included) |
| `onnxruntime` | CPU inference engine (no GPU version on macOS) |

**Installation combo example:** GPU workstation = `core` + `gpu` + `data` + `web` ≈ **240+ packages**

### [5/7] Node.js (optional)

Installs NVM (Node Version Manager) and Node.js LTS.

- Default selection based on profile
- Interactive mode asks for installation preference
- Lazy loading: NVM loads on first `node`/`npm` invocation, not at shell startup

### [6/7] Java (optional)

Installs SDKMAN and Java 21 (LTS).

- Default selection based on profile
- Lazy loading: Loads on first `sdk`/`java` invocation

### [7/7] Shell Integration

Adds module sourcing block to `.bashrc` and `.zshrc`.

```bash
# >>> machine_setting >>>
# Auto-source shell modules from machine_setting
for f in ~/machine_setting/shell/bashrc.d/[0-9]*.sh; do
    [ -r "$f" ] && source "$f"
done
# Source machine-local secrets (never committed)
[ -r "$HOME/.bashrc.local" ] && source "$HOME/.bashrc.local"
# <<< machine_setting <<<
```

This block loads the following shell modules in order:

| File | Role |
|------|------|
| `00-path.sh` | PATH setup (CUDA, Homebrew, uv, Maven) |
| `10-aliases.sh` | Common aliases (see table below) |
| `20-env.sh` | Environment variables |
| `30-nvm.sh` | NVM lazy loader (loads on first `node`/`npm` call) |
| `40-sdkman.sh` | SDKMAN lazy loader |
| `50-ai-env.sh` | `aienv` / `aienv-off` functions + background update check |

#### Shell Aliases (`10-aliases.sh`)

| Alias | Command | Purpose |
|-------|---------|---------|
| `py` | `python3` | Run Python |
| `pip` | `pip3` | Run pip |
| `ipy` | `ipython` | IPython |
| `gs` | `git status` | Git status |
| `gd` | `git diff` | Git diff |
| `gl` | `git log --oneline -20` | Recent 20 commits |
| `gp` | `git pull --rebase` | Git pull |
| `ms` | `cd ~/machine_setting` | Jump to repo |
| `mss` | `make status` | Sync status |
| `msu` | `make update` | Update |
| `msp` | `make push` | Push |
| `gpustat` | `nvidia-smi --query-gpu=...` | GPU status (Linux: nvidia-smi, macOS: ioreg) |

---

## Installed Components

Summary of items added to the system after installation:

### Files & Directories

| Path | Description | Removal |
|------|-------------|---------|
| `~/machine_setting/` | This repository | `rm -rf ~/machine_setting` |
| `~/ai-env/` | Python venv (global mode) | `make uninstall` |
| `~/.local/bin/uv` | uv package manager | Manual removal |
| `~/.local/share/uv/python/` | uv-managed Python builds | `make uninstall` |
| `~/.nvm/` | NVM + Node.js | `make uninstall` |
| `~/.sdkman/` | SDKMAN + Java | `make uninstall` |
| `~/.machine_setting/` | Install state/checkpoints/backups | `make uninstall` |
| `~/.machine_setting_profile` | Hardware detection results | `make uninstall` |
| `~/.bashrc.local` | User secrets (auto-generated template) | **Never deleted** |
| `~/.zshrc.local` | zsh secrets (symlink to bashrc.local) | **Never deleted** |

### NVIDIA System Files (Installed in Stage 2)

| Path | Description | Removal |
|------|-------------|---------|
| NVIDIA driver | `nvidia-driver-XXX` package | `uninstall --component nvidia` |
| `/usr/local/cuda` | CUDA Toolkit symlink | `uninstall --component nvidia` |
| `cuda-toolkit` | CUDA development tools | `uninstall --component nvidia` |
| `cudnn9-cuda-*` | cuDNN 9.x library | `uninstall --component nvidia` |
| `libnccl2`, `libnccl-dev` | NCCL multi-GPU communication | `uninstall --component nvidia` |
| `nvidia-container-toolkit` | Docker GPU support | `uninstall --component nvidia` |
| `/etc/sysctl.d/99-machine-setting-gpu.conf` | GPU kernel parameters | `uninstall --component nvidia` |
| `/etc/security/limits.d/99-machine-setting-gpu.conf` | memlock/nproc limits | `uninstall --component nvidia` |
| numactl, hwloc, nvtop, lm-sensors | System utilities | Manual removal |

### Shell RC Modifications

A marker block (`# >>> machine_setting >>>` ~ `# <<< machine_setting <<<`) is added to `.bashrc` and `.zshrc`. On removal, only this block is deleted; other user settings are preserved.

### Environment Variables (when activated)

| Variable | Value | Condition |
|----------|-------|-----------|
| `PATH` | Adds `~/.local/bin`, CUDA paths, etc. | Always |
| `CUDA_HOME` | `/usr/local/cuda` | Linux + CUDA |
| `LD_LIBRARY_PATH` | Adds CUDA lib64 | Linux + CUDA |
| `NVM_DIR` | `~/.nvm` | When Node installed |
| `NVIDIA_TF32_OVERRIDE` | `1` | When `aienv` activated (Ampere+ GPU) |

---

## Daily Usage

```bash
aienv                  # Activate venv + background update check
aienv-off              # Deactivate

make check             # Verify environment (GPU, packages)
make push              # Export packages + commit + push to remote
make update            # Pull changes + notify if packages changed
make status            # Show sync status
make export            # Export current venv to requirements files
make doctor            # Full health check
make recover           # Auto-recover broken components
```

### All Make Targets

| Target | Description |
|--------|-------------|
| `make setup` | Full bootstrap install |
| `make plan` | Pre-flight check (plan only) |
| `make preflight` | Pre-flight check then install |
| `make dry-run` | Full system dry-run diagnostic (all 7 stages) |
| `make check` | Verify AI environment (GPU, packages) |
| `make update` | Pull from remote + notify of changes |
| `make push` | Export packages + commit + push |
| `make status` | Show sync status |
| `make export` | Export venv to requirements files |
| `make venv` | Create/update venv |
| `make venv-local` | Create project-local venv |
| `make detect` | Run hardware detection |
| `make secrets` | Scan for secret leaks |
| `make doctor` | Health check |
| `make recover` | Auto-recover broken components |
| `make verify` | Verify package integrity |
| `make uninstall` | Interactive uninstall |
| `make uninstall-dry` | Preview what would be removed |
| `make reset` | Reset state and start from scratch |
| `make cloud` | Cloud/container setup (user-space only, no sudo needed) |
| `make gpu-extras` | Install GPU extras only (system tools + kernel tuning, sudo). Use when driver/CUDA already installed |

### `aienv` Details

1. Runs `~/ai-env/bin/activate` (venv activation)
2. Sets `NVIDIA_TF32_OVERRIDE=1` (FP32 ~2x acceleration on Ampere+ GPUs)
3. In cloud/container without nvcc: sets `DS_BUILD_OPS=0` (disables DeepSpeed JIT compilation)
4. Starts **background update check**:
   - Runs `git fetch origin main` every 24 hours
   - Shows update notification if local differs from remote
   - Runs fully in background with no impact on shell speed

### `make check` Output Example

```
=== AI Environment Check ===
  Venv: /root/ai-env
  Python: Python 3.12.13

  Installed packages: 379

--- Core Packages ---
  OK  transformers 4.57.6
  OK  datasets 4.6.1
  OK  accelerate 1.12.0
  ...

--- GPU Stack ---
  torch 2.10.0+cu128 (CUDA 12.8, 1 GPU(s), NVIDIA H100 PCIe)
  cuDNN 91002 (enabled=True)
  NCCL 2.27.5

--- GPU Packages ---
  bitsandbytes 0.49.2
  triton 3.6.0
  vllm 0.17.1
  deepspeed 0.18.8

--- GPU Functional Test ---
  matmul (512x512): OK
  cuDNN conv2d:     OK
  GPU memory:       39.4 GB
  Compute cap:      (9, 0)

--- Environment ---
  Container: yes
  nvcc: stub (runtime only, no JIT compile)
  Display: headless (no libGL)
```

---

## CLI Options

### Interactive (default)

```bash
./setup.sh
```

Prompts for options at each stage (Python version, venv location, Node/Java installation). Pre-flight check runs first to show current state and required actions.

### Non-interactive

```bash
# Full specification
./setup.sh --python 3.12 --venv global --node --java

# Use profile
./setup.sh --profile gpu-workstation
./setup.sh --profile mac-apple-silicon

# Selective install
./setup.sh --no-node --no-java --venv local

# Custom venv path
./setup.sh --venv /data/ai-env
```

### Dry-Run Diagnostic

```bash
# Full system dry-run (all 7 stages)
./setup.sh --dry-run
make dry-run

# Diagnose specific stage only
./scripts/dry-run.sh --stage nvidia
./scripts/dry-run.sh --stage python

# Profile-based diagnostic
./scripts/dry-run.sh --profile gpu-workstation

# JSON output (for scripting)
./scripts/dry-run.sh --json
```

Dry-run analyzes all 7 stages without installing anything:
- Detects current installation state and versions
- Plans install/upgrade/skip actions per component
- Checks conflicts and compatibility (CUDA↔PyTorch, Python↔venv, etc.)
- Reports disk usage and estimated install time
- Returns exit code 1 if blocking issues are found

### Pre-flight & Planning

```bash
# Check install plan only (no actual installation)
./setup.sh --plan
make plan

# Pre-flight check then selective install
./setup.sh --preflight
make preflight

# Direct execution (additional options)
./scripts/preflight.sh --check-only       # Status check only (= --plan)
./scripts/preflight.sh --quiet            # Non-interactive (write plan file and exit)
./scripts/preflight.sh --profile gpu-workstation  # Check against specific profile
```

### Resume & Recovery

```bash
# Resume from previous failure point
./setup.sh --resume

# Reset state and start from scratch
./setup.sh --reset

# Start from specific stage (previous stages marked complete)
./setup.sh --from 4    # Stage 4 (venv) onward
./setup.sh --from 7    # Stage 7 (shell) only

# Health check
./setup.sh --doctor

# Auto-recover
./setup.sh --recover
```

### Full Options Summary

| Flag | Description |
|------|-------------|
| `--python <ver>` | Python version (default: 3.12) |
| `--venv <mode>` | `global` / `local` / `<custom-path>` |
| `--node` / `--no-node` | Install/skip Node.js |
| `--java` / `--no-java` | Install/skip Java |
| `--profile <name>` | Use profile |
| `--cloud` | Cloud/container mode (skip driver/CUDA/kernel tuning) |
| `--dry-run` | Full system dry-run diagnostic (all 7 stages) |
| `--plan` | Run pre-flight check only |
| `--preflight` | Pre-flight check then install |
| `--resume` | Resume from failure point |
| `--reset` | Reset state and start from scratch |
| `--from <N>` | Start from Stage N (1-7) |
| `--doctor` | Health check |
| `--recover` | Auto-recover |
| `--uninstall` | Uninstall (additional flags available) |

---

## Profiles

| Profile | Platform | GPU Backend | NVIDIA Stage | Node | Java | Packages |
|---------|----------|-------------|-------------|------|------|----------|
| gpu-enterprise | Linux | CUDA (Enterprise) | Full + DCGM/FM/GDS | No | No | core+data+web+gpu |
| ngc-container | NGC/Linux | CUDA (NV symlink) | Skip (pre-installed) | No | No | core+data+web+nv-link |
| gpu-workstation | Linux | CUDA | Full (consumer) | Yes | Yes | core+data+web+gpu |
| cloud-server | Cloud/Container | CUDA (host-provided) | Skip (user-space only) | Yes | Yes | core+data+web+gpu |
| mac-apple-silicon | macOS | MPS | Skip (N/A) | Yes | No | core+data+web+mps |
| cpu-server | Linux | None | Skip (no GPU) | Yes | Yes | core+data+web+cpu |
| laptop | Any | None | Skip (no GPU) | Yes | No | core+data+web+cpu |
| minimal | Any | None | Skip | No | No | core only |

### Machine-specific Settings

Create `config/machine.conf` to override defaults (included in `.gitignore`):

```bash
cp config/machine.conf.example config/machine.conf
# Edit: Python version, Node/Java install preferences, package groups, etc.
```

---

## GPU Support

| Platform | GPU | Backend | Auto-detection |
|----------|-----|---------|----------------|
| NGC container | NVIDIA | CUDA (NV custom build symlink) | torch version check |
| Cloud/Container | NVIDIA | CUDA (host driver) | Docker/K8s/VM vendor detection + nvidia-smi |
| Linux | NVIDIA | CUDA (cu131, cu130, cu126, etc.) | lspci + nvcc |
| macOS arm64 | Apple Silicon | MPS (Metal) | uname -m |
| Any | None | CPU fallback | Auto |

### NVIDIA System-Level Install (Stage 2)

Stage [2/7] automatically installs the following system-level NVIDIA software:

```bash
# Auto mode (default) — detects GPU and installs optimal configuration
./setup.sh

# Manual: run NVIDIA script directly
./scripts/install-nvidia.sh                    # Full auto
./scripts/install-nvidia.sh --driver-only      # Driver only
./scripts/install-nvidia.sh --no-driver        # Skip driver (CUDA/cuDNN/NCCL only)
./scripts/install-nvidia.sh --extras-only      # Extras only (system tools + kernel tuning, skip driver/CUDA). Same as make gpu-extras
./scripts/install-nvidia.sh --enterprise       # Include enterprise tools
./scripts/install-nvidia.sh --dry-run          # Preview installation (deep diagnostic)
./scripts/install-nvidia.sh --uninstall        # Remove entire NVIDIA stack

# Fine-grained component selection
./scripts/install-nvidia.sh --no-cuda          # Skip CUDA (also skips cuDNN/NCCL)
./scripts/install-nvidia.sh --no-cudnn         # Skip cuDNN only
./scripts/install-nvidia.sh --no-nccl          # Skip NCCL only
./scripts/install-nvidia.sh --no-container-toolkit  # Skip Docker GPU support
./scripts/install-nvidia.sh --no-system-tools  # Skip system utilities
./scripts/install-nvidia.sh --no-kernel-tuning # Skip kernel/sysctl tuning

# Version pinning
./scripts/install-nvidia.sh --driver-version 570  # Specific driver version
./scripts/install-nvidia.sh --cuda-version 13-0   # Specific CUDA version
./scripts/install-nvidia.sh --open-kernel          # Force open kernel modules
./scripts/install-nvidia.sh --proprietary          # Force proprietary kernel modules
```

**NVIDIA configuration options** (`config/default.conf` or `config/machine.conf`):

| Setting | Default | Description |
|---------|---------|-------------|
| `INSTALL_NVIDIA` | `true` | Enable/disable entire NVIDIA stage |
| `NVIDIA_DRIVER_VERSION` | `""` (auto) | Driver version (empty = auto-recommend) |
| `NVIDIA_CUDA_VERSION` | `"13-0"` (CUDA 13.0) | CUDA version. Use e.g. `"12-6"` in machine.conf for older GPUs |
| `NVIDIA_OPEN_KERNEL` | `auto` | Open/proprietary kernel module selection |
| `NVIDIA_ENTERPRISE` | `false` | Enterprise tools (DCGM, FM, GDS, peermem) |
| `NVIDIA_NO_DRIVER` | `false` | Skip driver installation |
| `NVIDIA_CONTAINER_TOOLKIT` | `true` | Docker GPU support |
| `NVIDIA_SYSTEM_TOOLS` | `true` | Build tools, monitoring tools |
| `NVIDIA_KERNEL_TUNING` | `true` | Kernel/sysctl optimization |

### CUDA Version Matching (Python Packages)

PyTorch index URL is auto-selected based on detected CUDA version (`config/gpu-index-urls.conf`):

```
cu131=https://download.pytorch.org/whl/cu131
cu130=https://download.pytorch.org/whl/cu130
cu126=https://download.pytorch.org/whl/cu126
cu124=https://download.pytorch.org/whl/cu124
cu121=https://download.pytorch.org/whl/cu121
cpu=https://download.pytorch.org/whl/cpu
```

If the detected CUDA suffix is not in the list, it automatically falls back to the closest lower version.

### NGC Container Mode

In environments where NV custom builds (torch, flash_attn, transformer_engine) are already installed (like NGC containers), packages are symlinked into the venv instead of re-downloading from PyPI:

```bash
# Auto-detect (auto-selected for NGC containers)
./setup.sh

# Manual specification
./setup.sh --profile ngc-container
scripts/setup-venv.sh --nv-link
```

**Symlinked packages:** torch, torchvision, torchaudio, triton, flash_attn, transformer_engine

How it works:
1. Detects system site-packages path (e.g., `/usr/local/lib/python3.12/dist-packages`)
2. Symlinks target package directories to venv's site-packages
3. Also symlinks `.dist-info` directories (so pip recognizes the packages)

> **Python version mismatch detection:** If system Python (e.g. 3.10) differs from venv Python (e.g. 3.12), NV link is automatically skipped and GPU packages are installed via pip instead.

### Cloud/Container Mode

Installs only user-space tools when host provides GPU drivers (Docker, Kubernetes, cloud VMs).

```bash
# Auto-detect (activates automatically in container/cloud environments)
./setup.sh

# Explicit
./setup.sh --cloud
make cloud
```

**Auto-detection triggers:**
- `/.dockerenv` or `/run/.containerenv` exists
- cgroup contains `docker`/`containerd`/`kubepods` markers
- `KUBERNETES_SERVICE_HOST` environment variable set
- DMI vendor is AWS/GCP/Azure/DigitalOcean/Vultr/Oracle
- sudo command unavailable or access denied

**Skipped in cloud mode:** NVIDIA driver/CUDA toolkit install, kernel tuning (sysctl, limits), system packages (apt-get)

**Installed in cloud mode:** Hardware detection (read-only), Python (uv), AI venv (GPU packages included — uses host CUDA runtime), Node.js (nvm), Java (sdkman), shell integration

**Cloud-specific adaptations:**
- **Headless containers**: installs `opencv-python-headless` only (skips `opencv-python` when `libGL` is missing)
- **Runtime-only containers**: creates nvcc stub for DeepSpeed import compatibility
- **`aienv` activation**: sets `DS_BUILD_OPS=0` when nvcc is unavailable

---

## Pre-flight Check

Run `./setup.sh --plan` or `make plan` to check system state without installing.

```
+======================================================+
|            Pre-flight System Check                    |
+======================================================+

  System:  Ubuntu 22.04.5 LTS / AMD EPYC 7763 (128 cores) / 512GB RAM / 2847GB free
  GPU:     NVIDIA A100-SXM4-80GB / CUDA 12.6 (cu126)
  Profile: gpu-workstation

  #  Component            Current Status                 Proposed Action
  ---------------------------------------------------------------------------
  * 1  Hardware Profile     not generated                  -> INSTALL
       Generate ~/.machine_setting_profile
  * 2  NVIDIA GPU Stack     driver 535 / no CUDA           -> INSTALL
       Install CUDA toolkit, cuDNN, NCCL, system tools
    3  Python 3.12          3.12.8 installed + uv 0.5.14   (ok)
  * 4  AI Environment       not created                    -> INSTALL
       Create ~/ai-env + install [core data web + GPU]
    5  Node.js              v22.12.0 (NVM)                 (ok)
  * 6  Java 21              not installed                  -> INSTALL
       Install SDKMAN + Java 21
    7  Shell Integration    configured (.bashrc .zshrc)    (ok)
```

In interactive mode, you can toggle individual items to install only what you need.

---

## Reinstallation

### Full Reinstallation

```bash
# Method 1: Reset state and reinstall
./setup.sh --reset

# Method 2: Via make
make reset
```

This resets the `~/.machine_setting/install.state` file and re-runs all stages from scratch. Already-installed components (venv, Python, etc.) are checked at each stage and you're asked whether to recreate them.

### Reinstall Specific Stages

```bash
# Reinstall from Stage 4 (venv) — Stages 1-3 skipped
./setup.sh --from 4

# Reinstall Stage 7 (shell integration) only
./setup.sh --from 7
```

### Recreate venv Only

```bash
# Delete and recreate venv (full package reinstall)
rm -rf ~/ai-env
make venv

# Or run script directly (full options)
scripts/setup-venv.sh --global --python 3.12
scripts/setup-venv.sh --local                  # Project-local .venv
scripts/setup-venv.sh --path /custom/path      # Custom path
scripts/setup-venv.sh --profile gpu-workstation # Specific profile
scripts/setup-venv.sh --nv-link                # NGC container (symlink system packages)
```

### Update Packages Only

```bash
# Fetch latest requirements from remote and update venv
make update

# Manually reinstall packages in venv
scripts/setup-venv.sh
```

---

## Uninstall

### Interactive Mode (default)

```bash
make uninstall
# or
./scripts/uninstall.sh
```

Shows installed components and lets you toggle items for removal:

```
=== Machine Setting Uninstall ===

Components found:
  [1] v NVIDIA stack (driver 560.35.03, CUDA, cuDNN, tools)
  [2] v AI Virtual Environment (~/ai-env, 12G)
  [3] v Python via uv (1.8G)
  [4] v NVM + Node.js (287M)
  [5]   Java/SDKMAN (not installed)
  [6] v Shell integration (.bashrc .zshrc)
  [7] v Config & state files

Toggle numbers to select/deselect, 'a' for all, Enter to proceed:
```

### Full Removal

```bash
# Remove all components (requires typing 'UNINSTALL' to confirm)
./scripts/uninstall.sh --all

# Keep config/state, remove runtimes only
./scripts/uninstall.sh --all --keep-config
```

### Remove Specific Components

```bash
# Remove venv and Node.js only
./scripts/uninstall.sh --component venv,node

# Remove NVIDIA stack only
./scripts/uninstall.sh --component nvidia

# Available components: nvidia, venv, python, node, java, shell, config
```

### Dry-run (Preview)

```bash
make uninstall-dry
# or
./scripts/uninstall.sh --dry-run
```

### Complete Removal

After uninstall, the `~/machine_setting` repository itself remains. To fully remove:

```bash
./scripts/uninstall.sh --all
rm -rf ~/machine_setting
```

**Note:** `~/.bashrc.local` and `~/.zshrc.local` are user secret files and are never automatically deleted.

---

## Health Check & Recovery

### Doctor (Health Check)

```bash
make doctor
# or
./scripts/doctor.sh
```

Checks the following items:

| Check Item | What it verifies |
|------------|-----------------|
| Disk space | At least 1GB free at venv path |
| Hardware profile | `~/.machine_setting_profile` exists and is valid |
| Cloud environment | Cloud/container detection (Docker, K8s, cloud VM, sudo availability) |
| NVIDIA driver | Driver loaded, `nvidia-smi` functional |
| CUDA toolkit | `nvcc` exists and version (detects stub vs real nvcc) |
| cuDNN | dpkg status + **torch.backends.cudnn runtime verification** |
| NCCL | dpkg status + **torch.cuda.nccl runtime verification** |
| GPU kernel tuning | sysctl parameters applied (auto-skipped in cloud) |
| uv | uv installation and version |
| Python | uv-managed Python exists |
| Virtual environment | venv directory, bin/python, bin/activate exist |
| Key packages | **26** core packages import test (torch, transformers, anthropic, fastapi, pandas, etc.) |
| GPU packages | **7** GPU-specific packages (vllm, deepspeed, bitsandbytes, pytorch_lightning, etc.) |
| GPU functional | **GPU compute test** — matmul, cuDNN conv2d, NCCL availability |
| Node.js | NVM + Node installation status (if selected) |
| Java | SDKMAN + Java installation status (if selected) |
| Shell integration | Marker block exists in .bashrc/.zshrc |
| Platform | Xcode CLT (macOS) |

Output example (Cloud/Container):

```
=== Machine Setting Doctor ===

  [OK]   Disk space (1497GB free)
  [OK]   Hardware profile
  [OK]   Cloud environment (container detected)
  [OK]   NVIDIA driver (535.129.03, NVIDIA H100 PCIe)
  [WARN] CUDA Toolkit (stub nvcc 12.2 — runtime only, no JIT compile)
  [OK]   cuDNN (system: 8.9.6, torch: enabled v91002)
  [OK]   NCCL (system: 2.19.3, torch: 2.27.5)
  [SKIP] GPU kernel tuning (cloud/container — managed by host)
  [OK]   uv (uv 0.10.10)
  [OK]   Python (Python 3.12.13)
  [OK]   Virtual environment (~/ai-env, 379 packages)
  [OK]   Key packages (OK 26/26)
  [OK]   GPU packages (OK 7/7)
  [OK]   GPU functional (OK (NVIDIA H100 PCIe, cuDNN 91002, NCCL ok))
  [SKIP] Node.js (not installed)
  [SKIP] Java (not installed)
  [OK]   Shell integration (.bashrc)
  [OK]   Platform (Linux)

Summary: 12 ok, 0 failed, 0 warnings, 4 skipped
All checks passed!
```

### Auto-recover

```bash
# Auto-recover all failed items
make recover
# or
./scripts/doctor.sh --recover

# Recover specific component
./scripts/doctor.sh --recover nvidia
./scripts/doctor.sh --recover python
./scripts/doctor.sh --recover venv
./scripts/doctor.sh --recover shell
```

Available recovery targets: `disk`, `hardware`, `nvidia`, `uv`, `python`, `venv`, `packages`, `node`, `java`, `shell`, `platform`

Recovery actions per component:

| Component | Recovery Action |
|-----------|----------------|
| hardware | Re-run `detect-hardware.sh` |
| nvidia | Re-run `install-nvidia.sh` (driver, CUDA, cuDNN, NCCL) |
| uv | Reinstall uv (`curl ... \| sh`) |
| python | Install uv first if missing, then `uv python install` |
| venv | Recreate venv + reinstall packages |
| packages | Full venv reinstall (same as venv recovery) |
| node | Reinstall NVM + Node.js |
| java | Reinstall SDKMAN + Java |
| shell | Re-run `install-shell.sh` |
| platform | macOS: Xcode CLT guidance |
| disk | Manual cleanup guidance |

### Package Verification

```bash
make verify
# or
./scripts/doctor.sh --verify-packages
```

Verifies all packages listed in requirements files are installed:

```
=== Package Verification ===

  Missing packages (required but not installed):
    - some-package

  Extra packages (installed but not in requirements): 43
  (This is normal - they may be transitive dependencies)

  Result: 1 missing package(s)
  Run './scripts/doctor.sh --recover venv' to install missing packages.
```

---

## Cross-Machine Sync

Git-based synchronization system for maintaining identical package configurations across machines.

### Push (Current machine -> Remote)

```bash
make push
```

Actions:
1. Exports current package list from active venv to requirements files
2. `git add -A` changes
3. Auto-generates commit message: `update: sync from <hostname> at <timestamp>`
4. `git pull --rebase` then `git push`

### Pull (Remote -> Current machine)

```bash
make update
```

Actions:
1. `git pull --rebase`
2. Detects requirements file changes
3. If changed, shows `scripts/setup-venv.sh` run guidance

### Status

```bash
make status
```

Shows local changes, ahead/behind commit counts vs remote, and last commit info.

### Export

```bash
make export
```

Classifies and exports current venv packages to category-specific requirements files:
- GPU packages -> `requirements-gpu.txt`
- Data packages -> `requirements-data.txt`
- Web packages -> `requirements-web.txt`
- Others -> `requirements-core.txt`
- CPU/MPS files are manually managed

---

## Disk Health & Monitoring

Utility scripts for checking NAS/server disk health. All scripts are **read-only** (no data modification) and require `smartmontools` and `e2fsprogs`.

```bash
# Collect SMART details (all disks)
sudo ./scripts/disk-check-smart.sh [output-dir]

# Start SMART Extended Self-Test (parallel, takes hours)
sudo ./scripts/disk-check-smart-long.sh

# Bad sector scan (parallel read-only, takes hours to days)
sudo ./scripts/disk-check-badblocks.sh [output-dir]

# Monitor bad sector scan progress
./scripts/disk-check-progress.sh [output-dir]
watch -n 60 ./scripts/disk-check-progress.sh    # Auto-refresh every minute

# Convert .badblocks file to 512-byte sector ranges (for partition planning)
./scripts/disk-badblocks-to-sectors.sh <disk.badblocks> [sector-margin]
```

| Script | Purpose | sudo |
|--------|---------|------|
| `disk-check-smart.sh` | SMART detail collection + summary (Health, Reallocated, Pending) | Yes |
| `disk-check-smart-long.sh` | SMART Extended Self-Test (parallel) | Yes |
| `disk-check-badblocks.sh` | Parallel read-only bad sector scan | Yes |
| `disk-check-progress.sh` | Parse and display bad sector scan progress | No |
| `disk-badblocks-to-sectors.sh` | Convert badblocks output to sector ranges | No |

---

## Shell Integration Details

### Lazy Loading

NVM and SDKMAN use **lazy loading** to avoid impacting shell startup time:

```bash
# 30-nvm.sh: NVM loads only on first node/npm invocation
for cmd in nvm node npm npx; do
    eval "${cmd}() { unset -f nvm node npm npx; _load_nvm; ${cmd} \"\$@\"; }"
done
```

Running `node --version` for the first time triggers NVM loading; subsequent calls run directly.

### Background Update Check

Background update check occurs when `aienv` runs:

1. Checks `~/.last-update-check` timestamp
2. Skips if within 24 hours
3. `git fetch origin main --quiet` (background)
4. Shows update notification if local != remote

### Secrets

Store API keys and secrets in `~/.bashrc.local` (or `~/.zshrc.local`):

```bash
# ~/.bashrc.local (example)
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
export WANDB_API_KEY="..."
```

This file is auto-sourced at shell startup and is **never committed to Git**.

---

## Directory Structure

```
machine_setting/
├── setup.sh              # Single-entry bootstrap (7-stage pipeline)
├── Makefile              # make setup/update/push/status/doctor/uninstall
├── config/
│   ├── default.conf          # Default settings (Python 3.12, Node LTS, Java 21)
│   ├── machine.conf.example  # Machine-specific override template
│   └── gpu-index-urls.conf   # PyTorch CUDA index URL mapping
├── packages/
│   ├── requirements-core.txt   # Platform-independent AI/ML
│   ├── requirements-gpu.txt    # NVIDIA CUDA packages
│   ├── requirements-mps.txt    # Apple Silicon MPS packages
│   ├── requirements-cpu.txt    # CPU-only fallback
│   ├── requirements-data.txt   # Data/DB packages
│   └── requirements-web.txt    # Web/API packages
├── scripts/
│   ├── detect-hardware.sh      # GPU/CUDA/MPS/RAM/CPU detection
│   ├── install-nvidia.sh       # NVIDIA driver/CUDA/cuDNN/NCCL/enterprise tools
│   ├── install-python.sh       # uv + Python install
│   ├── setup-venv.sh           # venv creation + package install
│   ├── install-node.sh         # NVM + Node.js
│   ├── install-java.sh         # SDKMAN + Java
│   ├── lib-checkpoint.sh       # Checkpoint/rollback library (7-stage)
│   ├── dry-run.sh              # Full system dry-run diagnostic (all 7 stages)
│   ├── preflight.sh            # Pre-flight system check (incl. NVIDIA)
│   ├── doctor.sh               # Health check & recovery (incl. NVIDIA checks)
│   ├── uninstall.sh            # Component uninstaller (incl. NVIDIA)
│   ├── sync.sh                 # Git sync (push/pull/status)
│   ├── export-packages.sh      # venv -> requirements export
│   ├── check-env.sh            # AI environment verification
│   ├── check-secrets.sh        # Secret leak scanner
│   ├── disk-check-smart.sh    # SMART detail collection
│   ├── disk-check-smart-long.sh # SMART Extended Self-Test
│   ├── disk-check-badblocks.sh  # Parallel bad sector scan
│   ├── disk-check-progress.sh   # Bad sector scan progress monitor
│   └── disk-badblocks-to-sectors.sh # badblocks to sector range converter
├── shell/
│   ├── install-shell.sh        # Shell RC installer
│   └── bashrc.d/               # Modular shell config (bash + zsh)
│       ├── 00-path.sh          # PATH (CUDA, Homebrew, uv)
│       ├── 10-aliases.sh       # Common aliases
│       ├── 20-env.sh           # Environment variables
│       ├── 30-nvm.sh           # NVM lazy loader
│       ├── 40-sdkman.sh        # SDKMAN lazy loader
│       ├── 50-ai-env.sh        # aienv/aienv-off + update check
│       └── 90-local.sh.example # Secrets template
├── profiles/                   # Pre-configured machine profiles
│   ├── gpu-enterprise.conf      # A100/H100/B200 + enterprise tools (DCGM, FM)
│   ├── gpu-workstation.conf
│   ├── cloud-server.conf
│   ├── mac-apple-silicon.conf
│   ├── ngc-container.conf
│   ├── cpu-server.conf
│   ├── laptop.conf
│   └── minimal.conf
└── docs/                       # System documentation
    └── package-candidates-analysis.md   # Package candidates analysis (recommended/optional/skip)
```

---

## State & Configuration Files

### Runtime State Files (outside Git)

| File | Location | Purpose |
|------|----------|---------|
| `install.state` | `~/.machine_setting/` | 7-stage install progress (STAGE_1~7) |
| `backups/` | `~/.machine_setting/backups/` | .bashrc/.zshrc auto-backups (created on shell integration install/update, timestamped) |
| `.machine_setting_profile` | `~/` | Hardware detection results |
| `.last-update-check` | In repository | Last update check timestamp |
| `.preflight_plan` | `env/` | Pre-flight plan (temporary, deleted after install) |

### Configuration Files

| File | Location | Purpose | In Git |
|------|----------|---------|--------|
| `default.conf` | `config/` | Default settings | Yes |
| `machine.conf` | `config/` | Per-machine overrides | No (.gitignore) |
| `gpu-index-urls.conf` | `config/` | CUDA -> PyTorch URL mapping | Yes |
| `*.conf` | `profiles/` | Preset profiles | Yes |
| `.bashrc.local` | `~/` | User secrets | No |

---

## Troubleshooting

For issues during environment setup, see [docs/troubleshooting.md](docs/troubleshooting.md).

### Quick Diagnostics

```bash
# Full health check
make doctor

# Package integrity verification
make verify

# Check system state (no installation)
make plan

# Detailed environment check (GPU, package versions)
make check
```

### Common Issues

| Symptom | Solution |
|---------|----------|
| `aienv: command not found` | `source ~/.bashrc` or open a new terminal |
| `No venv at ~/ai-env` | `make venv` or `./setup.sh --from 4` |
| GPU not detected | `make detect` then `make doctor` |
| Package import failure | `make verify` -> `make recover` |
| Installation failed midway | `./setup.sh --resume` |
| Shell config broken | `./scripts/doctor.sh --recover shell` (restores from backup) |

---

## Security

- Secrets go in `~/.bashrc.local` or `~/.zshrc.local` (never committed)
- Pre-commit hook blocks AWS keys, GitHub PATs, API keys
- Repository is **PRIVATE**
- Run `make secrets` to scan for leaked credentials
