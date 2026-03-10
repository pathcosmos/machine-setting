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

## 7. /home 디스크 용량 부족

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
