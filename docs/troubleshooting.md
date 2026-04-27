# Troubleshooting

ai-env 환경 구성 시 자주 발생하는 문제와 해결 방법.

---

## 1. torch.cuda.is_available() 가 False

### 원인 A: ai-env 미활성화 상태에서 시스템 Python 사용

```bash
# 확인
which python
# /usr/bin/python3 → 문제
# .../ai-env/bin/python → 정상

# 해결
aienv
# 또는
source ~/ai-env/bin/activate
```

### 원인 B: NV 커스텀 torch가 링크되지 않음 (NGC 컨테이너)

NGC 컨테이너에서 `--nv-link` 없이 설치하면 PyPI torch (CPU-only)가 설치됨.

```bash
# 확인: NV 빌드인지 체크
python -c "import torch; print(torch.__version__, torch.version.cuda)"
# 정상: 2.10.0+cu128  12.8
# 비정상: 2.x.x+cpu  None

# 해결: --nv-link로 재구성
scripts/setup-venv.sh --nv-link
# 또는 프로필 사용
./setup.sh --profile ngc-container
```

### 원인 C: torch가 pip install로 CPU 버전 덮어씌움

```bash
# 해결: venv 삭제 후 재구성
rm -rf ~/ai-env
./setup.sh --profile ngc-container
```

---

## 2. No module named 'transformer_engine'

NGC 컨테이너의 transformer_engine은 PyPI에 없으므로 심볼릭 링크 필수.

```bash
# 확인: 시스템에 있는지
python3 -c "import transformer_engine; print(transformer_engine.__file__)"

# 해결: --nv-link 재실행
scripts/setup-venv.sh --nv-link
```

시스템에도 없다면 NVIDIA 제공 패키지 설치가 필요. 서버 관리자에게 문의.

---

## 3. No module named 'pip'

uv로 생성된 venv에서 간혹 발생.

```bash
# uv pip 직접 사용
uv pip install -r packages/requirements-core.txt

# 또는 pip 부트스트랩
ai-env/bin/python -m ensurepip --upgrade
```

---

## 4. 시스템 Python과 ai-env 혼동

학습 스크립트 실행 시 시스템 Python이 사용되는 경우:

```bash
# 잘못된 실행
python train/sft.py

# 올바른 실행
aienv && python train/sft.py
# 또는 직접 지정
~/ai-env/bin/python train/sft.py
```

---

## 5. flash-attn 빌드 실패 (CUDA 버전 불일치)

시스템 CUDA(13.x)와 venv torch(cu128) 간 major 버전 불일치 시 발생.
nvcc 래퍼로 우회:

```bash
# 1. nvcc 래퍼 생성 (버전 보고만 12.8로 변경)
COMPAT=/tmp/.cuda-compat
mkdir -p $COMPAT/bin
cat > $COMPAT/bin/nvcc << 'WRAPPER'
#!/bin/bash
if [[ "$*" == *"--version"* ]]; then
    /usr/local/cuda/bin/nvcc --version 2>&1 | sed 's/release [0-9]*\.[0-9]*/release 12.8/; s/V[0-9]*\.[0-9]*\.[0-9]*/V12.8.0/'
else
    exec /usr/local/cuda/bin/nvcc "$@"
fi
WRAPPER
chmod +x $COMPAT/bin/nvcc

# 2. 나머지 CUDA 파일 심링크
for d in /usr/local/cuda/*/; do
    name=$(basename "$d")
    [ "$name" != "bin" ] && ln -sfn "$d" "$COMPAT/$name"
done
for f in /usr/local/cuda/bin/*; do
    [ "$(basename $f)" != "nvcc" ] && ln -sfn "$f" "$COMPAT/bin/$(basename $f)"
done

# 3. 빌드
CUDA_HOME=$COMPAT TORCH_CUDA_ARCH_LIST="9.0;10.0" MAX_JOBS=16 \
uv pip install flash-attn --no-build-isolation

# 4. 정리
rm -rf $COMPAT
```

---

## 6. 패키지 버전 충돌

requirements 업데이트 후 충돌 발생 시:

```bash
# venv 완전 재생성
rm -rf ~/ai-env
./setup.sh
```

---

## 7-A. 체크포인트 state 파일 스키마 mismatch — `make venv` 즉시 종료 (Stage rename 잔재)

`./setup.sh` 또는 `make venv` 실행 시 `Installing core packages... → Audited N packages`까지 출력된 직후 곧바로 종료(`Error 1`). 추가 출력 없음.

### 증상

```bash
$ make venv
...
  Installing core packages...
Audited 185 packages in 28ms
make: *** [Makefile:35: venv] Error 1     ← 다음 그룹으로 넘어가지 않고 즉사
```

`bash -x` 추적 시 `checkpoint_add_group_done core` 함수 안 `current=$(checkpoint_read_key STAGE_4_GROUPS_DONE)` 라인에서 멈춤.

### 원인

`~/.machine_setting/install.state`에 **이전 6-stage 스키마**(`STAGE_3_GROUPS_DONE`)가 남아 있고 현재 7-stage 코드는 `STAGE_4_GROUPS_DONE`을 조회. `checkpoint_read_key` 함수가 `set -o pipefail` + `set -e` 하에서 동작하는데 grep 매치 실패가 변수 할당으로 전파되어 스크립트 전체 종료.

```bash
# 버그가 있던 구현 (lib-checkpoint.sh)
checkpoint_read_key() {
    local key="$1"
    if [ -f "$CHECKPOINT_STATE" ]; then
        grep "^${key}=" "$CHECKPOINT_STATE" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"'
    fi    # grep miss → pipefail로 exit 1 → 호출자에서 set -e 트리거
}
```

### 해결 (방어 처리됨, 2026-04-27 fix)

`lib-checkpoint.sh:checkpoint_read_key`가 누락 키를 안전하게 빈 문자열로 반환하도록 수정. 이후엔 자동 복구되며 별도 조치 불필요.

기존 머신에서 옛 state 파일이 남아 있다면:

```bash
# 안전한 리셋 (백업 후 재초기화)
mv ~/.machine_setting/install.state ~/.machine_setting/install.state.bak.$(date +%s)
make venv
# checkpoint_init이 7-stage 스키마로 새 state 파일 생성
```

`./setup.sh --reset` 도 동일 효과.

---

## 7-B. cx-Oracle 빌드 실패 — `ModuleNotFoundError: No module named 'pkg_resources'`

신규 venv 생성 시 `requirements-data.txt`의 `cx-Oracle==8.3.0` 빌드 단계에서 발생.

### 증상

```
× Failed to build `cx-oracle==8.3.0`
├─▶ The build backend returned an error
╰─▶ Call to `setuptools.build_meta.build_wheel` failed (exit status: 1)
    ...
    ModuleNotFoundError: No module named 'pkg_resources'
```

### 원인

setuptools **70.0.0** 부터 `pkg_resources`가 `setuptools` 본체에서 분리되어 별도 import 보장이 없음. uv가 build isolation을 위해 임시 환경에 최신 setuptools를 자동으로 가져오면서 cx-Oracle의 `setup.py` 안 `from pkg_resources import ...` 가 깨짐.

cx-Oracle 8.x는 더 이상 적극 유지보수되지 않으며, Oracle 공식 후속은 pure-Python 드라이버인 [`oracledb`](https://python-oracledb.readthedocs.io/) (이미 `requirements-data.txt`에 동시 수록).

### 해결 (자동, 2026-04-27 fix)

`setup-venv.sh`가 cx-Oracle 감지 시 venv에 `setuptools<70` + `wheel`을 사전 설치하고 `--no-build-isolation`로 빌드:

```bash
# scripts/setup-venv.sh — cx-Oracle 사전 처리
if grep -q "cx-Oracle" "$REQ_FILE" 2>/dev/null; then
    $UV_PIP install $INSTALL_ARGS "setuptools<70" wheel
    $UV_PIP install $INSTALL_ARGS cx-Oracle --no-build-isolation
fi
```

수동 우회가 필요한 경우:

```bash
uv pip install --python ~/ai-env/bin/python "setuptools<70" wheel
uv pip install --python ~/ai-env/bin/python cx-Oracle==8.3.0 --no-build-isolation
```

신규 코드에선 `cx-Oracle` 대신 `oracledb` 사용 권장. 기능 동일 + 빌드 불필요.

---

## 7-C. setup-venv.sh 검증 단계가 `torch: not installed` false negative

torch가 정상 설치되어 있는데도 마지막 verify 단계에서 `torch: not installed`만 출력.

### 증상

```bash
$ make venv
...
  Installed: 379 packages
  Verifying key packages...
    torch: not installed         ← 실제로는 설치됨
    transformers 5.6.2
    anthropic 0.84.0

# 직접 확인하면 정상
$ ~/ai-env/bin/python -c "import torch; print(torch.__version__)"
2.10.0+cu130
```

### 원인

검증 스니펫이 `python -c "..."` 형태로 전달되었고, Python f-string 내부 `{", ".join(backends)}`의 `"`가 bash 파서에서 외곽 `"..."`을 닫고 다시 여는 것으로 해석되어 결과 Python 코드가 `({, .join(backends)})` 같이 깨짐 → `SyntaxError` → fallback 메시지 출력.

추가로 `torch.cuda.is_available()` 호출 시 `pynvml` deprecation warning이 stderr로 나가 잡음.

### 해결 (자동, 2026-04-27 fix)

검증 코드를 단일 인용 heredoc(`<<'PYEOF'`)으로 전환하여 bash 인용 문제 자체를 제거하고 `warnings.filterwarnings("ignore")`로 deprecation 잡음 차단:

```bash
"$VENV_PATH/bin/python" - 2>/dev/null <<'PYEOF' || echo "    torch: not installed"
import warnings
warnings.filterwarnings("ignore")
import torch
...
print(f"    torch {torch.__version__} ({', '.join(backends)})")
PYEOF
```

---

## 8. /home 디스크 용량 부족

일부 서버에서 /home은 5GB 제한. venv을 다른 경로에 생성:

```bash
./setup.sh --venv /PROJECT/path/to/ai-env
# 또는
scripts/setup-venv.sh --path /PROJECT/path/to/ai-env
```

활성화 시에도 경로 지정:

```bash
aienv /PROJECT/path/to/ai-env
```

---

## GPU 하드웨어 및 안정성 문제

### Xid 79 — GPU has fallen off the bus

PCIe 전원 관리가 GPU를 절전 모드로 전환하면서 발생하는 문제입니다.

**증상:**
- `nvidia-smi` 실패
- dmesg에 `NVRM: Xid 79` 메시지
- GPU 관련 작업 중 시스템 프리즈

**해결:**
```bash
# 1. 먼저 리부트
sudo reboot

# 2. 재발 시 영구 수정 적용
sudo ./scripts/gpu-persist-fix.sh

# 3. 리부트 후 상태 확인
./scripts/gpu-persist-fix.sh --check
```

### GPU 온도/전력 문제

```bash
# GPU 상세 진단 (온도, 전력, 스로틀링 확인)
./scripts/gpu-doctor.sh
```

- 온도 >= 90°C → FAIL (쿨링 점검 필요)
- 온도 >= 80°C → WARN
- 전력 >= 95% → WARN

### PCIe 링크 속도 저하

gpu-doctor.sh [3/6] PCI Bus Status 섹션에서 확인:
- Link Speed / Width가 max보다 낮으면 WARN
- BAR Memory disabled → GPU 버스 이탈 상태

```bash
# PCIe 상태 확인
./scripts/gpu-doctor.sh
# 또는
lspci -vv -s $(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader)
```

### CUDA 프로세스 격리 문제 (PyTorch + Ollama 공존)

Custom PyTorch 모델과 Ollama가 같은 GPU를 공유할 때 발생하는 문제.
상세 방어 패턴: [10-cuda-defense-patterns.md](./10-cuda-defense-patterns.md)

**Ollama가 갑자기 죽음 (custom model CUDA 실행 후)**
- 원인: custom model의 CUDA 오류가 드라이버를 오염시켜 Ollama도 사망
- 대응: Tier 1 — subprocess 격리로 CUDA 코드를 별도 프로세스에서 실행
- 진단: `make cuda-defense-check`

**nvidia-smi 무응답 (GPU 프로세스 실행 후)**
- 원인: 심각한 CUDA 드라이버 오염 (cudaErrorLaunchFailure 등)
- 대응: Tier 3 — `nvidia-smi --gpu-reset -i 0` 또는 리부팅
- 진단: `./scripts/gpu-doctor.sh` (Section [7/7] CUDA Process Health)

**VRAM 누수 (모델 언로드 후에도 메모리 미해제)**
- 원인: 좀비 CUDA 프로세스 또는 cleanup 미수행
- 대응: Tier 2 — `gc.collect()` + `torch.cuda.empty_cache()`, 좀비 프로세스 kill
- 진단: `make cuda-defense-check` → [1/4] CUDA 프로세스 상태 섹션
