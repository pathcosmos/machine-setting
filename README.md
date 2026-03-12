# Machine Setting

> 🌐 [English](README_EN.md) | **한국어**

Portable AI development environment system. One command to set up Python + AI/ML packages + optional Node.js/Java on any machine, with automatic GPU/CPU detection and cross-machine sync.

**Supported platforms**: Linux (x86_64, NVIDIA CUDA) + macOS (Apple Silicon M1+, MPS)
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

# Activate AI environment
aienv
```

---

## How It Works

### Overview

`setup.sh`는 7단계 파이프라인으로 동작하며, 각 단계는 **체크포인트 시스템**으로 상태가 추적됩니다. 설치가 중간에 실패해도 완료된 단계를 건너뛰고 실패 지점부터 재개할 수 있습니다.

### Execution Flow

```
./setup.sh 실행
    │
    ├─ 1) Pre-flight Check (interactive 모드)
    │     현재 시스템 상태를 스캔하고 어떤 작업이 필요한지 표시
    │     사용자가 설치 항목을 선택/해제 가능
    │
    ├─ 2) 이전 설치 상태 확인
    │     ~/.machine_setting/install.state 파일에서 이전 진행 상태 읽기
    │     → 이전 실패 있으면: Resume / Reset / Cancel 메뉴 표시
    │     → 모두 완료 상태면: Reinstall / Cancel 메뉴 표시
    │
    └─ 3) 7단계 설치 파이프라인 실행
          각 단계마다 checkpoint 기록 → 실패 시 자동 rollback
```

### Checkpoint System

모든 설치 상태는 `~/.machine_setting/install.state`에 기록됩니다:

```
STAGE_1_HARDWARE=done
STAGE_2_NVIDIA=done
STAGE_3_PYTHON=done
STAGE_4_VENV=in_progress    ← 이 단계에서 실패
STAGE_5_NODE=pending
STAGE_6_JAVA=pending
STAGE_7_SHELL=pending
```

각 단계가 실패하면:
1. 해당 단계의 상태를 `failed`로 기록
2. **자동 롤백** 실행 (해당 단계에서 설치한 것들 제거)
3. 다음 실행 시 실패 지점부터 재개 가능

---

## Installation Flow

### [1/7] Hardware Detection

시스템 하드웨어를 자동 감지하여 `~/.machine_setting_profile`에 저장합니다.

| 감지 항목 | Linux | macOS |
|-----------|-------|-------|
| GPU | `lspci` + `nvidia-smi` | `system_profiler` (Apple Silicon) |
| CUDA 버전 | `nvcc --version` / `nvidia-smi` | N/A (MPS 사용) |
| CPU/RAM | `/proc/cpuinfo`, `/proc/meminfo` | `sysctl` |
| NGC 컨테이너 | torch NV 버전 체크 + `/opt/nvidia` 존재 | N/A |

감지 결과에 따라 최적 프로필이 자동 선택됩니다:
- NVIDIA GPU (Datacenter) → `gpu-enterprise`
- NVIDIA GPU → `gpu-workstation`
- Apple Silicon → `mac-apple-silicon`
- NGC 컨테이너 → `ngc-container`
- RAM ≥ 32GB (GPU 없음) → `cpu-server`
- RAM ≥ 8GB → `laptop`
- 그 외 → `minimal`

### [2/7] NVIDIA GPU Stack (Linux 전용)

시스템 레벨 NVIDIA GPU 소프트웨어 스택을 자동으로 설치합니다. `scripts/install-nvidia.sh`가 9개 서브 스테이지를 실행합니다.

**자동 스킵 조건:** 비-Linux OS, NVIDIA GPU 미감지, NGC 컨테이너 (이미 설치됨), `INSTALL_NVIDIA=false`

**GPU 티어 자동 분류:**

| 티어 | GPU 예시 | 동작 |
|------|----------|------|
| Consumer | GeForce RTX 3090/4090 | 기본 설치 (드라이버 + CUDA + cuDNN + NCCL) |
| Professional | RTX A6000, L40 | 기본 설치 |
| Datacenter | A100, H100, H200, B200 | 기본 + 엔터프라이즈 도구 자동 활성화 |

**설치 구성요소:**

| 구성요소 | 설명 | 설정 |
|----------|------|------|
| NVIDIA Driver | `ubuntu-drivers` 자동 추천 또는 수동 버전 지정 | `NVIDIA_DRIVER_VERSION` |
| CUDA Toolkit | `cuda-toolkit` 메타패키지, `/usr/local/cuda` 심볼릭 링크 | `NVIDIA_CUDA_VERSION` |
| cuDNN 9.x | DNN 가속 라이브러리 (`cudnn9-cuda-XX`) | 자동 |
| NCCL | 멀티 GPU 집합 통신 (단일 GPU면 스킵) | 자동 |
| Container Toolkit | Docker GPU 지원 (Docker 미설치 시 스킵) | `NVIDIA_CONTAINER_TOOLKIT` |
| Enterprise Tools | DCGM, Fabric Manager, GDS, nvidia-peermem | `NVIDIA_ENTERPRISE` |
| System Utilities | numactl, hwloc, nvtop, lm-sensors, build-essential, cmake | `NVIDIA_SYSTEM_TOOLS` |
| Kernel Tuning | sysctl (vm.max_map_count, shmmax 등), memlock limits, CPU governor | `NVIDIA_KERNEL_TUNING` |

**Open vs Proprietary Kernel Modules:**
- `NVIDIA_OPEN_KERNEL=auto` (기본): Turing+ (RTX 20xx 이상) → open, 구형 → proprietary
- `NVIDIA_OPEN_KERNEL=true`: 강제 open 커널 모듈
- `NVIDIA_OPEN_KERNEL=false`: 강제 proprietary 커널 모듈

**Secure Boot:** MOK (Machine Owner Key) 등록 안내가 자동으로 표시됩니다.

**커널 튜닝 상세:**
- `vm.max_map_count=1048576` (대규모 메모리 매핑)
- RAM 기반 동적 `shmmax`/`shmall` 계산
- `memlock unlimited` (GPU 메모리 잠금)
- TCP 버퍼 최적화 (분산 학습용)
- CPU governor → performance

### [3/7] Python Setup

[uv](https://github.com/astral-sh/uv)를 통해 Python을 설치합니다 (기본: 3.12).

- uv가 없으면 자동 설치 (`curl -LsSf https://astral.sh/uv/install.sh | sh`)
- `uv python install 3.12` 으로 관리형 Python 설치
- 시스템 Python에 영향 없음

### [4/7] AI Environment (Virtual Environment + Packages)

venv 생성 후 패키지 그룹별로 설치합니다.

**venv 위치 옵션:**
| 모드 | 경로 | 용도 |
|------|------|------|
| global (기본) | `~/ai-env` | 모든 프로젝트에서 공유 |
| local | `./.venv` | 현재 프로젝트 전용 |
| custom | 사용자 지정 경로 | 특정 파티션 등 |

**패키지 그룹:**
| 그룹 | 파일 | 내용 |
|------|------|------|
| core | `requirements-core.txt` | transformers, accelerate, peft, wandb, numpy, mlflow, tensorboard, optuna 등 |
| data | `requirements-data.txt` | pandas, polars, duckdb, SQLAlchemy, psycopg2, pypdf, openpyxl 등 |
| web | `requirements-web.txt` | fastapi, uvicorn, httpx, gradio, cryptography 등 |
| gpu | `requirements-gpu.txt` | torch+CUDA, triton, bitsandbytes, deepspeed, vllm, pynvml, nvitop 등 |
| mps | `requirements-mps.txt` | torch (Apple Silicon MPS 포함) |
| cpu | `requirements-cpu.txt` | torch CPU-only 빌드 |

GPU/MPS/CPU 패키지는 [1/7]에서 감지된 하드웨어에 따라 자동으로 하나만 선택됩니다.

**디스크 요구사항:** 최소 15GB 여유 공간 권장 (GPU 패키지 포함 시)

### [5/7] Node.js (선택)

NVM (Node Version Manager)을 설치하고, Node.js LTS를 설치합니다.

- 프로필에 따라 기본 선택/미선택 결정
- Interactive 모드에서 설치 여부를 물어봄
- Lazy loading: 셸 시작 시 NVM을 로드하지 않고, `node`/`npm` 최초 실행 시 로드

### [6/7] Java (선택)

SDKMAN을 설치하고, Java 21 (LTS)을 설치합니다.

- 프로필에 따라 기본 선택/미선택 결정
- Lazy loading: `sdk`/`java` 최초 실행 시 로드

### [7/7] Shell Integration

`.bashrc`와 `.zshrc`에 모듈 소싱 블록을 추가합니다.

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

이 블록은 다음 셸 모듈을 순서대로 로드합니다:

| 파일 | 역할 |
|------|------|
| `00-path.sh` | PATH 설정 (CUDA, Homebrew, uv, Maven) |
| `10-aliases.sh` | 공통 별칭 (아래 표 참조) |
| `20-env.sh` | 환경변수 설정 |
| `30-nvm.sh` | NVM lazy loader (`node`/`npm` 최초 실행 시 로드) |
| `40-sdkman.sh` | SDKMAN lazy loader |
| `50-ai-env.sh` | `aienv` / `aienv-off` 함수 + 백그라운드 업데이트 체크 |

#### 쉘 별칭 목록 (`10-aliases.sh`)

| 별칭 | 명령 | 용도 |
|------|------|------|
| `py` | `python3` | Python 실행 |
| `pip` | `pip3` | pip 실행 |
| `ipy` | `ipython` | IPython |
| `gs` | `git status` | Git 상태 |
| `gd` | `git diff` | Git 변경사항 |
| `gl` | `git log --oneline -20` | 최근 커밋 20개 |
| `gp` | `git pull --rebase` | Git pull |
| `ms` | `cd ~/machine_setting` | 저장소 이동 |
| `mss` | `make status` | 동기화 상태 |
| `msu` | `make update` | 업데이트 |
| `msp` | `make push` | 푸시 |
| `gpustat` | `nvidia-smi --query-gpu=...` | GPU 상태 (Linux: nvidia-smi, macOS: ioreg) |

---

## Installed Components

설치 후 시스템에 추가되는 항목 정리:

### Files & Directories

| 경로 | 설명 | 삭제 대상 |
|------|------|-----------|
| `~/machine_setting/` | 이 저장소 자체 | `rm -rf ~/machine_setting` |
| `~/ai-env/` | Python venv (global 모드) | `make uninstall` |
| `~/.local/bin/uv` | uv 패키지 매니저 | 수동 삭제 |
| `~/.local/share/uv/python/` | uv가 관리하는 Python 빌드 | `make uninstall` |
| `~/.nvm/` | NVM + Node.js | `make uninstall` |
| `~/.sdkman/` | SDKMAN + Java | `make uninstall` |
| `~/.machine_setting/` | 설치 상태/체크포인트/백업 | `make uninstall` |
| `~/.machine_setting_profile` | 하드웨어 감지 결과 | `make uninstall` |
| `~/.bashrc.local` | 사용자 시크릿 (자동 생성 템플릿) | **절대 삭제 안함** |
| `~/.zshrc.local` | zsh용 시크릿 (bashrc.local 심볼릭 링크) | **절대 삭제 안함** |

### NVIDIA 시스템 파일 (Stage 2에서 설치)

| 경로 | 설명 | 삭제 대상 |
|------|------|-----------|
| NVIDIA driver | `nvidia-driver-XXX` 패키지 | `uninstall --component nvidia` |
| `/usr/local/cuda` | CUDA Toolkit 심볼릭 링크 | `uninstall --component nvidia` |
| `cuda-toolkit` | CUDA 개발 도구 | `uninstall --component nvidia` |
| `cudnn9-cuda-*` | cuDNN 9.x 라이브러리 | `uninstall --component nvidia` |
| `libnccl2`, `libnccl-dev` | NCCL 멀티 GPU 통신 | `uninstall --component nvidia` |
| `nvidia-container-toolkit` | Docker GPU 지원 | `uninstall --component nvidia` |
| `/etc/sysctl.d/99-machine-setting-gpu.conf` | GPU 커널 파라미터 | `uninstall --component nvidia` |
| `/etc/security/limits.d/99-machine-setting-gpu.conf` | memlock/nproc limits | `uninstall --component nvidia` |
| numactl, hwloc, nvtop, lm-sensors | 시스템 유틸리티 | 수동 삭제 |

### Shell RC Modifications

`.bashrc`와 `.zshrc`에 마커 블록(`# >>> machine_setting >>>` ~ `# <<< machine_setting <<<`)이 추가됩니다. 삭제 시 이 블록만 제거되며, 사용자의 다른 설정은 보존됩니다.

### Environment Variables (활성화 시)

| 변수 | 값 | 조건 |
|------|------|------|
| `PATH` | `~/.local/bin`, CUDA 경로 등 추가 | 항상 |
| `CUDA_HOME` | `/usr/local/cuda` | Linux + CUDA |
| `LD_LIBRARY_PATH` | CUDA lib64 추가 | Linux + CUDA |
| `NVM_DIR` | `~/.nvm` | Node 설치 시 |
| `NVIDIA_TF32_OVERRIDE` | `1` | `aienv` 활성화 시 (Ampere+ GPU) |

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

### 전체 Make 타겟

| 타겟 | 설명 |
|------|------|
| `make setup` | 전체 부트스트랩 설치 |
| `make plan` | Pre-flight check (설치 계획만) |
| `make preflight` | Pre-flight check 후 설치 |
| `make dry-run` | 전체 시스템 dry-run 진단 (7단계) |
| `make check` | AI 환경 검증 (GPU, 패키지) |
| `make update` | 리모트에서 pull + 변경사항 알림 |
| `make push` | 패키지 export + commit + push |
| `make status` | 동기화 상태 확인 |
| `make export` | venv → requirements 파일 export |
| `make venv` | venv 생성/업데이트 |
| `make venv-local` | 프로젝트 로컬 venv 생성 |
| `make detect` | 하드웨어 감지 실행 |
| `make secrets` | 시크릿 누출 스캔 |
| `make doctor` | 건강 체크 |
| `make recover` | 자동 복구 |
| `make verify` | 패키지 무결성 검증 |
| `make uninstall` | 대화형 삭제 |
| `make uninstall-dry` | 삭제 미리보기 |
| `make reset` | 상태 초기화 후 처음부터 |

### `aienv` 동작 상세

1. `~/ai-env/bin/activate` 실행 (venv 활성화)
2. `NVIDIA_TF32_OVERRIDE=1` 설정 (Ampere+ GPU에서 FP32 연산 ~2x 가속)
3. **백그라운드 업데이트 체크** 시작:
   - 24시간마다 `git fetch origin main` 실행
   - 로컬과 리모트가 다르면 업데이트 알림 출력
   - 완전히 백그라운드로 실행되어 셸 속도에 영향 없음

### `make check` 출력 예시

```
=== AI Environment Check ===
  Venv: /home/user/ai-env
  Python: Python 3.12.8

  Installed packages: 247

--- Core Packages ---
  OK  transformers 4.47.0
  OK  datasets 3.2.0
  OK  accelerate 1.2.1
  ...

--- GPU Packages ---
  torch 2.5.1+cu126 (CUDA 12.6, 2 GPU(s), NVIDIA RTX 4090)
  flash_attn 2.7.2
  bitsandbytes 0.45.0
```

---

## CLI Options

### Interactive (기본)

```bash
./setup.sh
```

모든 단계에서 옵션을 물어봅니다 (Python 버전, venv 위치, Node/Java 설치 여부). Pre-flight check가 먼저 실행되어 현재 상태와 필요한 작업을 보여줍니다.

### Non-interactive

```bash
# 전체 지정
./setup.sh --python 3.12 --venv global --node --java

# 프로필 사용
./setup.sh --profile gpu-workstation
./setup.sh --profile mac-apple-silicon

# 선택적 설치
./setup.sh --no-node --no-java --venv local

# Custom venv 경로
./setup.sh --venv /data/ai-env
```

### Dry-Run 진단

```bash
# 전체 시스템 dry-run (7개 전 단계 진단)
./setup.sh --dry-run
make dry-run

# 특정 단계만 진단
./scripts/dry-run.sh --stage nvidia
./scripts/dry-run.sh --stage python

# 프로필 기반 진단
./scripts/dry-run.sh --profile gpu-workstation

# JSON 출력 (스크립팅용)
./scripts/dry-run.sh --json
```

Dry-run은 실제 설치 없이 7개 전 단계를 분석합니다:
- 현재 설치 상태 및 버전 감지
- 설치/업그레이드/스킵 액션 플랜
- 충돌 및 호환성 검사 (CUDA↔PyTorch, Python↔venv 등)
- 디스크 사용량 및 예상 설치 시간
- 차단 이슈 발견 시 exit code 1 반환

### Pre-flight & Planning

```bash
# 설치 계획만 확인 (실제 설치 안함)
./setup.sh --plan
make plan

# Pre-flight check 후 선택적 설치
./setup.sh --preflight
make preflight

# 직접 실행 (추가 옵션)
./scripts/preflight.sh --check-only       # 상태 확인만 (= --plan)
./scripts/preflight.sh --quiet            # 비대화형 (계획 파일 작성 후 종료)
./scripts/preflight.sh --profile gpu-workstation  # 특정 프로필 기준 검사
```

### Resume & Recovery

```bash
# 이전 실패 지점부터 재개
./setup.sh --resume

# 상태 초기화 후 처음부터
./setup.sh --reset

# 특정 단계부터 시작 (이전 단계는 완료 처리)
./setup.sh --from 4    # Stage 4 (venv)부터
./setup.sh --from 7    # Stage 7 (shell)만

# 건강 체크
./setup.sh --doctor

# 자동 복구
./setup.sh --recover
```

### 전체 옵션 요약

| Flag | 설명 |
|------|------|
| `--python <ver>` | Python 버전 (기본: 3.12) |
| `--venv <mode>` | `global` / `local` / `<custom-path>` |
| `--node` / `--no-node` | Node.js 설치/미설치 |
| `--java` / `--no-java` | Java 설치/미설치 |
| `--profile <name>` | 프로필 사용 |
| `--dry-run` | 전체 시스템 dry-run 진단 (7단계) |
| `--plan` | Pre-flight check만 실행 |
| `--preflight` | Pre-flight check 후 설치 |
| `--resume` | 실패 지점부터 재개 |
| `--reset` | 상태 초기화 후 처음부터 |
| `--from <N>` | Stage N (1-7)부터 시작 |
| `--doctor` | 건강 체크 |
| `--recover` | 자동 복구 |
| `--uninstall` | 삭제 (추가 플래그 가능) |

---

## Profiles

| Profile | Platform | GPU Backend | NVIDIA Stage | Node | Java | Packages |
|---------|----------|-------------|-------------|------|------|----------|
| gpu-enterprise | Linux | CUDA (Enterprise) | Full + DCGM/FM/GDS | No | No | core+data+web+gpu |
| ngc-container | NGC/Linux | CUDA (NV symlink) | Skip (pre-installed) | No | No | core+data+web+nv-link |
| gpu-workstation | Linux | CUDA | Full (consumer) | Yes | Yes | core+data+web+gpu |
| mac-apple-silicon | macOS | MPS | Skip (N/A) | Yes | No | core+data+web+mps |
| cpu-server | Linux | None | Skip (no GPU) | Yes | Yes | core+data+web+cpu |
| laptop | Any | None | Skip (no GPU) | Yes | No | core+data+web+cpu |
| minimal | Any | None | Skip | No | No | core only |

### Machine-specific 설정

`config/machine.conf`를 만들어 기본 설정을 오버라이드할 수 있습니다 (`.gitignore`에 포함):

```bash
cp config/machine.conf.example config/machine.conf
# 편집: Python 버전, Node/Java 설치 여부, 패키지 그룹 등
```

---

## GPU Support

| Platform | GPU | Backend | 자동 감지 방법 |
|----------|-----|---------|---------------|
| NGC container | NVIDIA | CUDA (NV custom build symlink) | torch 버전 체크 |
| Linux | NVIDIA | CUDA (cu131, cu130, cu126 등) | lspci + nvcc |
| macOS arm64 | Apple Silicon | MPS (Metal) | uname -m |
| Any | None | CPU fallback | 자동 |

### NVIDIA System-Level Install (Stage 2)

[2/7] 단계에서 다음 시스템 레벨 NVIDIA 소프트웨어를 자동 설치합니다:

```bash
# 자동 모드 (기본) — GPU 감지 후 최적 구성 자동 설치
./setup.sh

# 수동: NVIDIA 스크립트 직접 실행
./scripts/install-nvidia.sh                    # 전체 자동
./scripts/install-nvidia.sh --driver-only      # 드라이버만
./scripts/install-nvidia.sh --no-driver        # 드라이버 제외 (CUDA/cuDNN/NCCL만)
./scripts/install-nvidia.sh --enterprise       # 엔터프라이즈 도구 포함
./scripts/install-nvidia.sh --dry-run          # 설치 미리보기 (심층 진단)
./scripts/install-nvidia.sh --uninstall        # NVIDIA 스택 전체 제거

# 세부 선택 설치
./scripts/install-nvidia.sh --no-cuda          # CUDA 제외 (cuDNN/NCCL도 제외)
./scripts/install-nvidia.sh --no-cudnn         # cuDNN만 제외
./scripts/install-nvidia.sh --no-nccl          # NCCL만 제외
./scripts/install-nvidia.sh --no-container-toolkit  # Docker GPU 지원 제외
./scripts/install-nvidia.sh --no-system-tools  # 시스템 유틸리티 제외
./scripts/install-nvidia.sh --no-kernel-tuning # 커널/sysctl 최적화 제외

# 버전 지정
./scripts/install-nvidia.sh --driver-version 570  # 드라이버 버전 지정
./scripts/install-nvidia.sh --cuda-version 13-0   # CUDA 버전 지정
./scripts/install-nvidia.sh --open-kernel          # open 커널 모듈 강제
./scripts/install-nvidia.sh --proprietary          # proprietary 커널 모듈 강제
```

**NVIDIA 설정 옵션** (`config/default.conf` 또는 `config/machine.conf`):

| 설정 | 기본값 | 설명 |
|------|--------|------|
| `INSTALL_NVIDIA` | `true` | NVIDIA 스테이지 전체 활성화/비활성화 |
| `NVIDIA_DRIVER_VERSION` | `""` (자동) | 드라이버 버전 (비어있으면 추천 버전 자동 선택) |
| `NVIDIA_CUDA_VERSION` | `""` (최신) | CUDA 버전 |
| `NVIDIA_OPEN_KERNEL` | `auto` | open/proprietary 커널 모듈 선택 |
| `NVIDIA_ENTERPRISE` | `false` | 엔터프라이즈 도구 (DCGM, FM, GDS, peermem) |
| `NVIDIA_NO_DRIVER` | `false` | 드라이버 설치 스킵 |
| `NVIDIA_CONTAINER_TOOLKIT` | `true` | Docker GPU 지원 |
| `NVIDIA_SYSTEM_TOOLS` | `true` | 빌드 도구, 모니터링 도구 |
| `NVIDIA_KERNEL_TUNING` | `true` | 커널/sysctl 최적화 |

### CUDA 버전 매칭 (Python 패키지)

감지된 CUDA 버전에 따라 PyTorch index URL이 자동 선택됩니다 (`config/gpu-index-urls.conf`):

```
cu131=https://download.pytorch.org/whl/cu131
cu130=https://download.pytorch.org/whl/cu130
cu126=https://download.pytorch.org/whl/cu126
cu124=https://download.pytorch.org/whl/cu124
cu121=https://download.pytorch.org/whl/cu121
cpu=https://download.pytorch.org/whl/cpu
```

감지된 CUDA suffix가 목록에 없으면, 가장 가까운 낮은 버전으로 자동 fallback됩니다.

### NGC Container Mode

NGC 컨테이너처럼 시스템에 NV 커스텀 빌드(torch, flash_attn, transformer_engine)가 이미 설치된 환경에서는 PyPI에서 다시 받지 않고 심볼릭 링크로 venv에 연결합니다:

```bash
# 자동 감지 (NGC 컨테이너면 자동 선택)
./setup.sh

# 수동 지정
./setup.sh --profile ngc-container
scripts/setup-venv.sh --nv-link
```

**심볼릭 링크 대상 패키지:** torch, torchvision, torchaudio, triton, flash_attn, transformer_engine

동작 방식:
1. 시스템 site-packages 경로 감지 (예: `/usr/local/lib/python3.12/dist-packages`)
2. 대상 패키지 디렉토리를 venv의 site-packages에 심볼릭 링크
3. `.dist-info` 디렉토리도 함께 링크 (pip이 패키지를 인식하도록)

---

## Pre-flight Check

`./setup.sh --plan` 또는 `make plan`으로 실제 설치 없이 현재 시스템 상태를 확인합니다.

```
╔══════════════════════════════════════════════════════╗
║            Pre-flight System Check                  ║
╚══════════════════════════════════════════════════════╝

  System:  Ubuntu 22.04.5 LTS / AMD EPYC 7763 (128 cores) / 512GB RAM / 2847GB free
  GPU:     NVIDIA A100-SXM4-80GB / CUDA 12.6 (cu126)
  Profile: gpu-workstation

  #  Component            Current Status                 Proposed Action
  ─────────────────────────────────────────────────────────────────────────────
  * 1  Hardware Profile     not generated                  → INSTALL
       Generate ~/.machine_setting_profile
  * 2  NVIDIA GPU Stack     driver 535 / no CUDA           → INSTALL
       Install CUDA toolkit, cuDNN, NCCL, system tools
    3  Python 3.12          3.12.8 installed + uv 0.5.14   (ok)
  * 4  AI Environment       not created                    → INSTALL
       Create ~/ai-env + install [core data web + GPU]
    5  Node.js              v22.12.0 (NVM)                 (ok)
  * 6  Java 21              not installed                  → INSTALL
       Install SDKMAN + Java 21
    7  Shell Integration    configured (.bashrc .zshrc)    (ok)
```

Interactive 모드에서는 항목별로 토글하여 원하는 것만 설치할 수 있습니다.

---

## Reinstallation

### 전체 재설치

```bash
# 방법 1: 상태 리셋 후 재설치
./setup.sh --reset

# 방법 2: make 사용
make reset
```

이 명령은 `~/.machine_setting/install.state` 파일을 초기화하고, 모든 단계를 처음부터 다시 실행합니다. 이미 설치된 컴포넌트(venv, Python 등)는 각 단계에서 "이미 존재" 여부를 확인하여 재생성 여부를 물어봅니다.

### 특정 단계만 재설치

```bash
# Stage 4 (venv)부터 재설치 — Stage 1~3은 건너뜀
./setup.sh --from 4

# Stage 7 (shell integration)만 재설치
./setup.sh --from 7
```

### venv만 재생성

```bash
# 기존 venv 삭제 후 재생성 (패키지 전체 재설치)
rm -rf ~/ai-env
make venv

# 또는 스크립트 직접 실행 (전체 옵션)
scripts/setup-venv.sh --global --python 3.12
scripts/setup-venv.sh --local                  # 프로젝트 로컬 .venv
scripts/setup-venv.sh --path /custom/path      # 커스텀 경로
scripts/setup-venv.sh --profile gpu-workstation # 프로필 지정
scripts/setup-venv.sh --nv-link                # NGC 컨테이너용 (시스템 패키지 심볼릭 링크)
```

### 패키지만 업데이트

```bash
# 리모트에서 최신 requirements 가져와서 venv 업데이트
make update

# 수동으로 venv에 패키지 재설치
scripts/setup-venv.sh
```

---

## Uninstall

### Interactive 모드 (기본)

```bash
make uninstall
# 또는
./scripts/uninstall.sh
```

설치된 컴포넌트 목록을 보여주고, 토글 방식으로 삭제할 항목을 선택합니다:

```
=== Machine Setting Uninstall ===

Components found:
  [1] ✓ NVIDIA stack (driver 560.35.03, CUDA, cuDNN, tools)
  [2] ✓ AI Virtual Environment (~/ai-env, 12G)
  [3] ✓ Python via uv (1.8G)
  [4] ✓ NVM + Node.js (287M)
  [5]   Java/SDKMAN (not installed)
  [6] ✓ Shell integration (.bashrc .zshrc)
  [7] ✓ Config & state files

Toggle numbers to select/deselect, 'a' for all, Enter to proceed:
```

### 전체 삭제

```bash
# 모든 컴포넌트 삭제 (확인 필요: 'UNINSTALL' 입력)
./scripts/uninstall.sh --all

# config/state는 유지하고 런타임만 삭제
./scripts/uninstall.sh --all --keep-config
```

### 특정 컴포넌트만 삭제

```bash
# venv와 Node.js만 삭제
./scripts/uninstall.sh --component venv,node

# NVIDIA 스택만 삭제
./scripts/uninstall.sh --component nvidia

# 사용 가능한 컴포넌트: nvidia, venv, python, node, java, shell, config
```

### Dry-run (삭제 미리보기)

```bash
make uninstall-dry
# 또는
./scripts/uninstall.sh --dry-run
```

### 완전 삭제

uninstall 후에도 `~/machine_setting` 저장소 자체는 남아있습니다. 완전히 제거하려면:

```bash
./scripts/uninstall.sh --all
rm -rf ~/machine_setting
```

**주의:** `~/.bashrc.local`과 `~/.zshrc.local`은 사용자 시크릿 파일이므로 절대 자동 삭제되지 않습니다.

---

## Health Check & Recovery

### Doctor (건강 체크)

```bash
make doctor
# 또는
./scripts/doctor.sh
```

다음 항목을 점검합니다:

| 체크 항목 | 확인 내용 |
|-----------|-----------|
| Disk space | venv 경로에 1GB 이상 여유 |
| Hardware profile | `~/.machine_setting_profile` 존재 및 유효성 |
| NVIDIA driver | 드라이버 로드 상태, `nvidia-smi` 동작 확인 |
| CUDA toolkit | `nvcc` 존재 및 버전, `/usr/local/cuda` 심볼릭 링크 |
| cuDNN | cuDNN 라이브러리 설치 상태 |
| NCCL | NCCL 라이브러리 설치 상태 |
| GPU kernel tuning | sysctl 파라미터 (vm.max_map_count 등) 적용 여부 |
| uv | uv 설치 및 버전 |
| Python | uv로 관리되는 Python 존재 |
| Virtual environment | venv 디렉토리, bin/python, bin/activate 존재 |
| Key packages | torch, transformers, anthropic import 가능 |
| Node.js | NVM + Node 설치 상태 (설치 선택 시) |
| Java | SDKMAN + Java 설치 상태 (설치 선택 시) |
| Shell integration | .bashrc/.zshrc에 마커 블록 존재 |
| Platform | Xcode CLT (macOS) |

출력 예시:

```
=== Machine Setting Doctor ===

  [OK]   Disk space (2847GB free)
  [OK]   Hardware profile
  [OK]   NVIDIA driver (560.35.03)
  [OK]   CUDA toolkit (12.6, /usr/local/cuda)
  [OK]   cuDNN (9.x)
  [OK]   NCCL (2.x)
  [OK]   GPU kernel tuning (vm.max_map_count=1048576)
  [OK]   uv (uv 0.5.14)
  [OK]   Python (Python 3.12.8)
  [OK]   Virtual environment (~/ai-env, 247 packages)
  [OK]   Key packages (torch: ok, transformers: ok, anthropic: ok)
  [OK]   Node.js (v22.12.0)
  [SKIP] Java (not installed)
  [OK]   Shell integration (.bashrc .zshrc)

Summary: 13 ok, 0 failed, 0 warnings, 1 skipped
All checks passed!
```

### Auto-recover (자동 복구)

```bash
# 모든 실패 항목 자동 복구
make recover
# 또는
./scripts/doctor.sh --recover

# 특정 컴포넌트만 복구
./scripts/doctor.sh --recover nvidia
./scripts/doctor.sh --recover python
./scripts/doctor.sh --recover venv
./scripts/doctor.sh --recover shell
```

사용 가능한 복구 대상: `disk`, `hardware`, `nvidia`, `uv`, `python`, `venv`, `packages`, `node`, `java`, `shell`, `platform`

각 컴포넌트별 복구 동작:

| 컴포넌트 | 복구 동작 |
|----------|-----------|
| hardware | `detect-hardware.sh` 재실행 |
| nvidia | `install-nvidia.sh` 재실행 (드라이버, CUDA, cuDNN, NCCL) |
| uv | uv 재설치 (`curl ... \| sh`) |
| python | uv가 없으면 먼저 설치, 그 후 `uv python install` |
| venv | venv 재생성 + 패키지 재설치 |
| packages | venv 전체 재설치 (= venv 복구) |
| node | NVM + Node.js 재설치 |
| java | SDKMAN + Java 재설치 |
| shell | `install-shell.sh` 재실행 |
| platform | macOS: Xcode CLT 안내 |
| disk | 수동 정리 안내 |

### Package Verification (패키지 무결성 검증)

```bash
make verify
# 또는
./scripts/doctor.sh --verify-packages
```

requirements 파일에 명시된 패키지가 모두 설치되어 있는지 확인합니다:

```
=== Package Verification ===

  Missing packages (required but not installed):
    - some-package

  Extra packages (installed but not in requirements): 43
  (This is normal — they may be transitive dependencies)

  Result: 1 missing package(s)
  Run './scripts/doctor.sh --recover venv' to install missing packages.
```

---

## Cross-Machine Sync

여러 머신에서 동일한 패키지 구성을 유지하기 위한 Git 기반 동기화 시스템입니다.

### Push (현재 머신 → 리모트)

```bash
make push
```

동작:
1. 활성화된 venv에서 현재 패키지 목록을 requirements 파일로 export
2. 변경사항 `git add -A`
3. 자동 커밋 메시지 생성: `update: sync from <hostname> at <timestamp>`
4. `git pull --rebase` 후 `git push`

### Pull (리모트 → 현재 머신)

```bash
make update
```

동작:
1. `git pull --rebase`
2. requirements 파일 변경 여부 감지
3. 변경되었으면 `scripts/setup-venv.sh` 실행 안내 출력

### Status

```bash
make status
```

로컬 변경사항, 리모트 대비 ahead/behind 커밋 수, 마지막 커밋 정보를 보여줍니다.

### Export

```bash
make export
```

현재 venv의 패키지를 카테고리별 requirements 파일로 분류/export합니다:
- GPU 패키지 → `requirements-gpu.txt`
- Data 패키지 → `requirements-data.txt`
- Web 패키지 → `requirements-web.txt`
- 나머지 → `requirements-core.txt`
- CPU/MPS 파일은 수동 관리

---

## Disk Health & Monitoring

NAS/서버 디스크 건강 상태를 점검하는 유틸리티 스크립트 모음입니다. 모든 스크립트는 **읽기 전용** (데이터 변경 없음)이며, `smartmontools`와 `e2fsprogs`가 필요합니다.

```bash
# SMART 상세 수집 (전 디스크)
sudo ./scripts/disk-check-smart.sh [출력디렉토리]

# SMART Extended Self-Test 시작 (병렬, 수 시간 소요)
sudo ./scripts/disk-check-smart-long.sh

# 배드섹터 검사 (병렬 read-only, 수 시간~수십 시간)
sudo ./scripts/disk-check-badblocks.sh [출력디렉토리]

# 배드섹터 검사 진행률 모니터링
./scripts/disk-check-progress.sh [출력디렉토리]
watch -n 60 ./scripts/disk-check-progress.sh    # 1분마다 자동 갱신

# .badblocks 파일을 512바이트 섹터 구간으로 변환 (파티션 설계용)
./scripts/disk-badblocks-to-sectors.sh <disk.badblocks> [섹터여유]
```

| 스크립트 | 용도 | sudo |
|----------|------|------|
| `disk-check-smart.sh` | SMART 상세 수집 + 요약 (Health, Reallocated, Pending) | Yes |
| `disk-check-smart-long.sh` | SMART Extended Self-Test 병렬 실행 | Yes |
| `disk-check-badblocks.sh` | 병렬 read-only 배드섹터 검사 | Yes |
| `disk-check-progress.sh` | 배드섹터 검사 진행률 파싱/표시 | No |
| `disk-badblocks-to-sectors.sh` | badblocks 결과를 섹터 구간으로 변환 | No |

---

## Shell Integration Details

### Lazy Loading

NVM과 SDKMAN은 **lazy loading** 방식으로 구현되어 셸 시작 시간에 영향을 주지 않습니다:

```bash
# 30-nvm.sh: node/npm 최초 실행 시에만 NVM 로드
for cmd in nvm node npm npx; do
    eval "${cmd}() { unset -f nvm node npm npx; _load_nvm; ${cmd} \"\$@\"; }"
done
```

실제 `node --version`을 처음 실행하면 그때 NVM이 로드되고, 이후에는 직접 실행됩니다.

### Background Update Check

`aienv` 실행 시 백그라운드에서 업데이트 체크가 이루어집니다:

1. `~/.last-update-check` 타임스탬프 확인
2. 24시간 이내면 skip
3. `git fetch origin main --quiet` (백그라운드)
4. 로컬 ≠ 리모트이면 업데이트 알림 출력

### Secrets

`~/.bashrc.local`(또는 `~/.zshrc.local`)에 API 키 등 시크릿을 저장합니다:

```bash
# ~/.bashrc.local (example)
export ANTHROPIC_API_KEY="sk-ant-..."
export OPENAI_API_KEY="sk-..."
export WANDB_API_KEY="..."
```

이 파일은 셸 시작 시 자동으로 source되며, **절대 Git에 커밋되지 않습니다**.

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
│   ├── dry-run.sh              # 전체 시스템 dry-run 진단 (7단계)
│   ├── preflight.sh            # Pre-flight system check (NVIDIA 포함)
│   ├── doctor.sh               # Health check & recovery (NVIDIA 체크 포함)
│   ├── uninstall.sh            # Component uninstaller (NVIDIA 포함)
│   ├── sync.sh                 # Git sync (push/pull/status)
│   ├── export-packages.sh      # venv → requirements export
│   ├── check-env.sh            # AI environment verification
│   ├── check-secrets.sh        # Secret leak scanner
│   ├── disk-check-smart.sh    # SMART 상세 수집
│   ├── disk-check-smart-long.sh # SMART Extended Self-Test
│   ├── disk-check-badblocks.sh  # 병렬 배드섹터 검사
│   ├── disk-check-progress.sh   # 배드섹터 검사 진행률 모니터
│   └── disk-badblocks-to-sectors.sh # badblocks→섹터 구간 변환
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
│   ├── mac-apple-silicon.conf
│   ├── ngc-container.conf
│   ├── cpu-server.conf
│   ├── laptop.conf
│   └── minimal.conf
└── docs/                       # System documentation
```

---

## State & Configuration Files

### 런타임 상태 파일 (Git 외부)

| 파일 | 위치 | 용도 |
|------|------|------|
| `install.state` | `~/.machine_setting/` | 7단계 설치 진행 상태 (STAGE_1~7) |
| `backups/` | `~/.machine_setting/backups/` | .bashrc/.zshrc 자동 백업 (셸 통합 설치/업데이트 시 타임스탬프별 생성) |
| `.machine_setting_profile` | `~/` | 하드웨어 감지 결과 |
| `.last-update-check` | 저장소 내 | 마지막 업데이트 체크 타임스탬프 |
| `.preflight_plan` | `env/` | Pre-flight 계획 (임시, 설치 후 삭제) |

### 설정 파일

| 파일 | 위치 | 용도 | Git 포함 |
|------|------|------|----------|
| `default.conf` | `config/` | 기본 설정 | Yes |
| `machine.conf` | `config/` | 머신별 오버라이드 | No (.gitignore) |
| `gpu-index-urls.conf` | `config/` | CUDA→PyTorch URL 매핑 | Yes |
| `*.conf` | `profiles/` | 프리셋 프로필 | Yes |
| `.bashrc.local` | `~/` | 사용자 시크릿 | No |

---

## Troubleshooting

환경 구성 중 문제가 발생하면 [docs/troubleshooting.md](docs/troubleshooting.md)를 참고하세요.

### 빠른 진단

```bash
# 전체 건강 체크
make doctor

# 패키지 무결성 검증
make verify

# 시스템 상태 확인 (설치 안함)
make plan

# 환경 상세 확인 (GPU, 패키지 버전)
make check
```

### 자주 발생하는 문제

| 증상 | 해결 |
|------|------|
| `aienv: command not found` | `source ~/.bashrc` 또는 새 터미널 열기 |
| `No venv at ~/ai-env` | `make venv` 또는 `./setup.sh --from 4` |
| GPU가 감지되지 않음 | `make detect` 후 `make doctor` |
| 패키지 import 실패 | `make verify` → `make recover` |
| 설치 중간에 실패 | `./setup.sh --resume` |
| 셸 설정이 깨짐 | `./scripts/doctor.sh --recover shell` (백업에서 복원) |

---

## Security

- Secrets go in `~/.bashrc.local` or `~/.zshrc.local` (never committed)
- Pre-commit hook blocks AWS keys, GitHub PATs, API keys
- Repository is **PRIVATE**
- Run `make secrets` to scan for leaked credentials
