# CUDA 프로세스 격리 & 방어 패턴

> 최종 점검일: 2026-03-30

PyTorch custom model과 GPU service(Ollama, vLLM, TGI 등)가 같은 GPU를 공유할 때 발생하는 CUDA 드라이버 오염 문제와 3-tier 방어 패턴을 정리한다.

---

## 1. 문제 정의

Custom PyTorch 모델을 `model.to("cuda:0")`로 직접 로딩하면서 동시에 Ollama 등 GPU service가 실행 중일 때:

1. **VRAM 경합**: 두 프로세스가 GPU 메모리를 동시에 점유 → OOM
2. **CUDA context 오염**: `cudaErrorLaunchFailure` 등이 발생하면 해당 프로세스의 CUDA context가 복구 불가 상태가 됨
3. **드라이버 레벨 오염**: 심한 경우 `nvidia-smi`까지 무응답 → GPU service(Ollama)도 함께 사망

### 핵심 함정: `torch.cuda.is_available()`

```python
# import 시점에 캐시됨 — 이후 드라이버가 오염돼도 True 반환
torch.cuda.is_available()  # True (거짓말)

# nvidia-smi subprocess 호출은 현재 상태를 정확히 반영
subprocess.run(["nvidia-smi", ...], timeout=5)  # 실패 → 드라이버 오염 감지
```

**`torch.cuda.is_available()`은 import 시점 캐시이므로 런타임 GPU 상태 판단에 사용하면 안 된다.** `nvidia-smi` subprocess 호출로 동적 확인해야 한다.

---

## 2. 3-Tier 방어 모델

| Tier | 이름 | 범위 | 메커니즘 | 방어 대상 |
|------|------|------|----------|-----------|
| **1** | 프로세스 격리 | Application | Subprocess JSON line protocol | CUDA 오류가 메인 프로세스에 전파되지 않음 |
| **2** | CUDA 메모리 정리 | Process | gc + synchronize + empty_cache | VRAM 누수, stale context |
| **3** | 시스템 복구 | OS/Driver | nvidia-smi reset + service restart + CPU fallback | 드라이버 오염, service hang |

---

## 3. Tier 1: 프로세스 격리 (Subprocess Isolation)

**원칙**: 모든 `torch.load()` / `model.to("cuda")` 코드를 별도 subprocess에서 실행한다.

### 패턴: JSON Line Protocol

```
[Parent Process]                    [Worker Subprocess]
     │                                     │
     │──── {"action":"load"} ────────────▶│ load_model()
     │◀─── {"ok":true} ──────────────────│
     │                                     │
     │──── {"action":"generate",...} ────▶│ generate()
     │◀─── {"response":"...",...} ────────│
     │                                     │
     │──── {"action":"quit"} ────────────▶│ unload_model(); exit
```

- **Parent** → **Worker**: `stdin`으로 JSON 명령 전송
- **Worker** → **Parent**: `stdout`으로 JSON 응답
- **Worker의 print()** → `stderr`로 리다이렉트 (부모 콘솔에 표시)
- **Timeout 감지**: `select.select([proc.stdout], [], [], timeout)` — 무응답 시 worker kill

### Worker 사망 시 복구

```python
# Worker가 segfault/CUDA error로 사망하면:
proc.stdout.readline()  # → "" (빈 줄)
proc.poll()             # → non-zero exit code
# Parent는 영향받지 않음 — 새 worker 시작 가능
```

### 적용 시점

- Custom PyTorch model을 GPU에 로딩할 때 (특히 실험적/unstable 모델)
- Ollama/vLLM/TGI가 동시에 GPU를 사용 중일 때
- 안정성이 검증되지 않은 checkpoint를 테스트할 때

---

## 4. Tier 2: CUDA 메모리 정리 (Memory Cleanup)

모델 로딩 실패 또는 추론 완료 후 CUDA 리소스를 정리하는 시퀀스:

```python
def cuda_cleanup():
    """CUDA 실패 후 최대한 정리"""
    # Step 1: Python 레벨 GC — 참조 해제
    gc.collect()

    if torch.cuda.is_available():
        # Step 2: 대기 중인 CUDA 연산 완료 대기
        try:
            torch.cuda.synchronize()
        except Exception:
            pass  # 드라이버 오염 시 실패할 수 있음

        # Step 3: GPU 캐시 메모리 해제
        try:
            torch.cuda.empty_cache()
        except Exception:
            pass

        # Step 4: Peak 메모리 통계 리셋
        try:
            torch.cuda.reset_peak_memory_stats()
        except Exception:
            pass
```

### 모델 로딩 패턴

```python
try:
    model = Model(config)
    model = model.to("cuda:0")
except Exception as e:
    del model          # 참조 해제 먼저
    cuda_cleanup()     # CUDA 리소스 정리
    # GPU 상태 동적 확인 (nvidia-smi)
    if not gpu_is_healthy():
        print("GPU 드라이버 오염 감지")
    raise
```

### 중요: 각 단계의 try-except

`synchronize()`, `empty_cache()` 등은 **드라이버가 이미 오염된 경우 자체적으로 실패**할 수 있다. 따라서 각 단계를 개별 try-except로 감싸서, 하나가 실패해도 나머지 정리를 시도한다.

---

## 5. Tier 3: 시스템 레벨 복구 (System Recovery)

### 5.1 GPU 건강 검사 (Dynamic Health Probe)

```bash
# nvidia-smi로 현재 GPU 상태 확인 (5초 타임아웃)
nvidia-smi --query-gpu=name --format=csv,noheader
```

- 정상 응답 → GPU OK
- 타임아웃/에러 → 드라이버 오염

```bash
# 자동화 진단
./scripts/cuda-defense-check.sh
./scripts/gpu-doctor.sh
```

### 5.2 GPU 리셋

```bash
# nvidia-smi로 GPU 리셋 시도 (root 또는 CUDA 프로세스 없는 상태에서)
nvidia-smi --gpu-reset -i 0
```

**제한사항**:
- root 권한 또는 CUDA 프로세스가 없는 상태에서만 작동
- 일반 유저: "Insufficient Permissions" 에러 가능
- 실패 시 → 리부팅 필요

### 5.3 GPU Service 2-Phase 종료

Ollama 등 GPU service를 안전하게 종료하는 패턴:

```bash
# Phase 1: Graceful (SIGTERM) — 5초 대기
pkill -f "ollama serve"
sleep 5

# Phase 2: Forceful (SIGKILL) — 완전 종료
pkill -9 -f "ollama"
sleep 3
```

### 5.4 CPU Fallback

GPU 복구 불가 시 service를 CPU 모드로 재시작:

```bash
# GPU 사용 비활성화 후 재시작
CUDA_VISIBLE_DEVICES="" ollama serve
```

평가/추론 속도는 크게 떨어지지만 서비스 가용성을 유지한다.

### 5.5 트랙/배치 간 Health Check

여러 모델을 순차적으로 실행하는 배치 작업에서 **모델 전환 시마다** GPU 상태를 확인:

1. 현재 모델 언로드
2. `nvidia-smi` health probe → 이상 시 service 재시작
3. 쿨다운 대기 (기본 10초)
4. 다음 모델 로딩

---

## 6. GPU 전략 설정

Custom model과 GPU service의 GPU 공유 방법:

| 전략 | Custom Model | GPU Service | 위험도 | 속도 | 설명 |
|------|-------------|-------------|--------|------|------|
| `custom_cpu` | CPU | GPU 유지 | 안전 | 느림 | 기본값. Custom model은 CPU에서 실행, service는 GPU 유지 |
| `service_suspend` | GPU | 정지→재시작 | 중간 | 빠름 | Service 정지 → custom model GPU 사용 → service 재시작 |

### `custom_cpu` (기본, 권장)

```bash
export CUSTOM_GPU_STRATEGY="custom_cpu"
```

- Custom model: CPU에서 실행 (느리지만 안전)
- GPU service: 중단 없이 GPU 계속 사용
- CUDA 충돌 위험 없음

### `service_suspend`

```bash
export CUSTOM_GPU_STRATEGY="service_suspend"
```

전환 흐름:
```
Ollama GPU 실행 중
  → Ollama 정지 (2-phase 종료)
    → Custom model GPU 로딩 (subprocess)
      → Custom model 추론
    → Custom model 언로드
  → Ollama GPU 재시작 (health check 포함)
```

**주의**: Custom model의 CUDA 오류가 드라이버를 오염시키면 이후 Ollama GPU 재시작이 실패할 수 있음 → CPU fallback 필요.

---

## 7. 진단 도구

| 명령 | 설명 |
|------|------|
| `make cuda-defense-check` | CUDA 프로세스 레벨 전체 진단 (4섹션) |
| `make cuda-defense-summary` | 한 줄 요약 |
| `./scripts/cuda-defense-check.sh --json` | 자동화용 JSON 출력 |
| `make gpu-doctor` | GPU 하드웨어 + 프로세스 진단 (7섹션) |
| `make doctor` | 시스템 전체 건강 검사 (GPU 포함) |

---

## 8. 알려진 실패 패턴

| 실패 모드 | 증상 | 방어 Tier | 복구 방법 |
|-----------|------|-----------|-----------|
| CUDA OOM | `torch.cuda.OutOfMemoryError` | 1 (subprocess dies) | Parent 무사, 새 worker 시작 |
| cudaErrorLaunchFailure | Kernel 실행 실패 | 1+2 (subprocess + cleanup) | Worker 사망 → parent가 감지 |
| 드라이버 오염 | `nvidia-smi` hang/무응답 | 3 (gpu-reset) | `nvidia-smi --gpu-reset` 또는 리부팅 |
| Service hang | Ollama API 무응답 (프로세스 존재) | 3 (2-phase 종료) | `pkill -9` → 재시작 |
| VRAM 누수 | 모델 언로드 후에도 메모리 미해제 | 2 (cleanup) | `empty_cache()` + `gc.collect()` |
| 프로세스 레벨 CUDA 오염 | `nvidia-smi` 정상이나 `torch.cuda` 실패 | 1 (subprocess 격리) | 해당 subprocess만 종료, 새 프로세스에서 CUDA 정상 |

### 가장 까다로운 시나리오: nvidia-smi OK + CUDA context 오염

`nvidia-smi`는 응답하지만 **같은 프로세스 내** PyTorch CUDA context가 오염된 경우:
- Tier 1(subprocess 격리)이 없으면 **메인 프로세스에서 CUDA 복구 불가**
- 별도 프로세스(Ollama 등)는 정상 동작할 수 있음
- **핵심**: subprocess 격리가 이 시나리오의 유일한 방어책

---

## 참조

- [01-nvidia-gpu-cuda.md](./01-nvidia-gpu-cuda.md) — GPU/CUDA 하드웨어 설정
- [troubleshooting.md](./troubleshooting.md) — GPU 트러블슈팅
- [08-issues-and-todos.md](./08-issues-and-todos.md) — 알려진 이슈
- `scripts/gpu-doctor.sh` — GPU 하드웨어 + 프로세스 진단 ([7/7] CUDA Process Health)
- `scripts/cuda-defense-check.sh` — CUDA 프로세스 레벨 전용 진단
- `scripts/gpu-persist-fix.sh` — GPU 안정성 시스템 설정
