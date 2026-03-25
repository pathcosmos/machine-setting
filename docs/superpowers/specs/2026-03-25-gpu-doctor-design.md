# GPU Doctor Design Spec

## Overview

GPU 전용 진단 도구. NVIDIA GPU의 건강 상태를 상세히 점검하고, 문제 발견 시 원인 설명과 구체적인 조치 방법을 항목별로 제시한다.

## Motivation

RTX 5060 Ti (Blackwell) + driver 590 조합에서 Xid 79 (GPU fell off bus) 발생. nvidia-smi 불능, PCI BAR disabled 상태까지 갔으나 리부트로 복구. 이런 문제를 자동으로 감지하고 정확한 대응 방법을 안내하는 도구가 필요하다.

## Scope

- **진단 + 방법 제안** (자동 복구/예방 모니터링은 향후)
- NVIDIA CUDA GPU 전용 (MPS/CPU는 대상 아님)

## File Structure

```
scripts/gpu-doctor.sh    # 새 파일 — GPU 전용 상세 진단
scripts/doctor.sh        # 수정 — gpu-doctor.sh --summary 호출로 GPU 체크 통합
setup.sh                 # 수정 — --gpu-doctor 플래그 추가
```

## Diagnostic Sections (6 sections + summary)

### [1/6] Driver Communication

**체크 항목:**
- `nvidia-smi` 응답 여부 및 exit code
- 드라이버 버전, 커널 모듈 타입 (open/proprietary)
- GPU 이름, UUID, Bus ID

**실패 시 제안:**
- nvidia-smi exit 6 (Unknown Error) → 리부트 필요
- nvidia-smi not found → 드라이버 설치 필요 (`./setup.sh --from 2`)
- 모듈 미로드 → `sudo modprobe nvidia` 시도

### [2/6] Xid Errors

**체크 항목:**
- `dmesg`에서 최근 24시간 Xid 에러 검색
- Xid 번호별 심각도 분류:
  - **Critical (즉시 조치):** 79 (bus fall off), 154 (reboot required), 48 (DBE)
  - **Warning (모니터링):** 13 (graphics engine exception), 31 (setup failure), 45 (preemptive cleanup)
  - **Info:** 8 (dropped interrupt), 32 (invalid/legacy)
- 발생 시각, 횟수, 패턴 분석 (반복 여부)

**실패 시 제안:**
- Xid 79 → 리부트 (Xid 154 동반 시 필수), 재발 시 BIOS PCIe Gen3 다운그레이드 + PSU 확인
- Xid 48 → ECC 에러 관련, RMA 검토
- Xid 13 → 드라이버 업그레이드 시도

### [3/6] PCI Bus Status

**체크 항목:**
- `lspci -vv`에서 BAR memory 상태 (`[disabled]` 감지)
- PCIe link speed/width (현재 vs 최대)
  - 다운그레이드 감지 (예: Gen4 x16 가능인데 Gen3 x8로 동작)
- IOMMU 상태

**실패 시 제안:**
- BAR disabled → GPU가 PCI에서 이탈. 리부트 필요
- Link 다운그레이드 → 슬롯 재장착, 다른 슬롯 시도, 케이블 확인
- 지속적 다운그레이드 → BIOS에서 수동으로 Gen3 고정

### [4/6] Thermal & Power

**체크 항목:**
- `nvidia-smi`에서 GPU 온도 (현재, slowdown threshold, shutdown threshold)
- 전력 사용량 (현재 / 한도 / 최대)
- Throttle 이유 (thermal, power, etc.)
- Fan speed

**실패 시 제안:**
- 온도 > slowdown threshold → 케이스 에어플로우, 서멀 페이스트, fan curve 확인
- 전력 한도 근처 → PSU 용량 확인 (RTX 5060 Ti: 180W TDP + 시스템 전력)
- Throttle 감지 → throttle reason별 구체 대응

### [5/6] Driver Compatibility

**체크 항목:**
- GPU 아키텍처 감지 (Blackwell, Ada Lovelace, Hopper, Ampere 등)
- 드라이버 버전 ↔ 아키텍처 최소 요구 매핑:
  - Blackwell (RTX 50xx): 560+
  - Ada Lovelace (RTX 40xx): 525+
  - Hopper (H100): 525+
  - Ampere (RTX 30xx, A100): 470+
- 커널 모듈 서명 상태 (tainted kernel 감지)
- DKMS 빌드 상태 (현재 커널에 대한 모듈 존재 여부)

**실패 시 제안:**
- 드라이버 버전 낮음 → 권장 버전 안내 + 업그레이드 명령
- tainted kernel → Secure Boot 설정 확인 또는 서명된 모듈 사용
- DKMS 누락 → `sudo dkms autoinstall` 안내

### [6/6] ECC Status

**체크 항목:**
- ECC 지원 여부 (consumer GPU는 미지원 → skip)
- ECC 활성화 상태
- Single-bit / Double-bit 에러 카운트 (volatile + aggregate)
- Retired pages 카운트

**실패 시 제안:**
- Double-bit 에러 > 0 → RMA 검토 권장
- Single-bit 에러 증가 추세 → 메모리 열화 가능성, 모니터링 권장
- Retired pages 누적 → GPU 메모리 감소 경고

### Summary & Actions

모든 섹션 결과를 종합하여:
1. 전체 상태 요약 (OK / WARNING / CRITICAL)
2. 조치 필요 항목을 우선순위 순서로 번호 매겨서 출력
3. 각 액션에 구체적 명령어 또는 절차 포함

## Output Format

### 상세 모드 (기본, 단독 실행)

```
=== GPU Doctor ===
  GPU: NVIDIA GeForce RTX 5060 Ti (Blackwell)
  Driver: 590.48.01 (open kernel module)

--- [1/6] Driver Communication ---
  nvidia-smi:  OK (exit 0)
  Driver:      590.48.01
  Module:      nvidia (open, loaded)
  Bus ID:      0000:01:00.0
  UUID:        GPU-829ecf29-...

--- [2/6] Xid Errors (last 24h) ---
  Found: 2 errors

  [CRITICAL] Xid 79 — GPU has fallen off the bus
    Time: 2026-03-25 06:32:14 (3h ago)
    Count: 1

  [CRITICAL] Xid 154 — Recovery action changed to Node Reboot Required
    Time: 2026-03-25 06:32:14 (3h ago)
    Count: 1

--- [3/6] PCI Bus Status ---
  BAR Memory:  enabled — OK
  Link Speed:  16 GT/s (Gen4) — OK
  Link Width:  x16 — OK

--- [4/6] Thermal & Power ---
  Temperature: 32°C / 92°C slowdown / 98°C shutdown — OK
  Power:       4W / 180W limit — OK
  Throttle:    none — OK
  Fan:         0% (idle)

--- [5/6] Driver Compatibility ---
  Architecture: Blackwell (minimum driver: 560)
  Driver:       590.48.01 — OK
  Kernel:       6.8.0-106-generic
  DKMS:         nvidia/590.48.01 built — OK
  Tainted:      yes (unsigned module)
    ℹ Non-critical: open kernel module is unsigned by default

--- [6/6] ECC Status ---
  Skipped (consumer GPU — ECC not supported)

=== Summary ===
  Status: WARNING (2 issues)

  Actions (by priority):
    1. [CRITICAL] Xid 79/154 감지 — 리부트 완료 여부 확인
       → 리부트 후 nvidia-smi 정상이면 해결
       → 재발 시: BIOS에서 PCIe Gen3으로 다운그레이드
       → 재발 시: PSU 용량 확인 (시스템 전체 300W+ 권장)

    2. [INFO] Kernel tainted (unsigned module)
       → Secure Boot 비활성화 상태면 무시 가능
       → 필요 시: sudo mokutil --disable-validation
```

### 요약 모드 (`--summary`, doctor.sh용)

```
OK|WARN|FAIL <한 줄 설명>
```

예시:
- `OK NVIDIA GeForce RTX 5060 Ti (590.48.01, 32°C, no errors)`
- `WARN NVIDIA GeForce RTX 5060 Ti (Xid 79 detected 3h ago — run gpu-doctor.sh)`
- `FAIL GPU unreachable (nvidia-smi exit 6 — reboot required)`

## Integration with doctor.sh

기존 `check_nvidia_driver()` 함수를 수정:
- `gpu-doctor.sh --summary` 실행 → exit code + stdout 파싱
- exit 0 = OK, exit 1 = WARN, exit 2 = FAIL
- FAIL/WARN 시 `→ Run './scripts/gpu-doctor.sh' for details` 안내

기존 개별 GPU 체크 함수들 (`check_cuda_toolkit`, `check_cudnn`, `check_nccl`, `check_gpu_kernel_tuning`, `check_gpu_functional`)은 그대로 유지. gpu-doctor.sh는 하드웨어/드라이버 레벨 진단에 집중.

## Integration with setup.sh

`--gpu-doctor` 플래그 추가:
```bash
--gpu-doctor)  exec bash "$SCRIPT_DIR/scripts/gpu-doctor.sh" ;;
```

## Dependencies

- `nvidia-smi` (NVIDIA 드라이버 설치 시 포함)
- `lspci` (pciutils 패키지)
- `dmesg` (커널 로그 접근 — 아래 폴백 전략 참고)
- 기존 프로젝트 패턴: `set -uo pipefail`, status helpers, `SCRIPT_DIR` 관례

### dmesg 접근 폴백 전략

Ubuntu/Debian에서 `kernel.dmesg_restrict=1`이 기본이라 일반 유저는 `dmesg` 접근 불가할 수 있음. 다음 순서로 시도:

1. `dmesg` 직접 실행 (권한 있으면 성공)
2. `journalctl -k --since "24 hours ago"` (systemd 환경, adm 그룹이면 접근 가능)
3. 둘 다 실패 시 → `[WARN] Xid check skipped (insufficient permissions)` 출력 + 해결 방법 안내:
   - `sudo sysctl kernel.dmesg_restrict=0` (임시)
   - 유저를 `adm` 그룹에 추가 (영구): `sudo usermod -aG adm $USER`

## Out of Scope (향후)

- 자동 복구 (GPU reset, 드라이버 재로드)
- systemd/cron 기반 주기적 감시
- 알림 시스템 (Slack, email)
- multi-GPU 상세 진단 (현재는 GPU 0 기준)
