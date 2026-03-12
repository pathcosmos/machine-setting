# Known Issues & TODOs

> 최종 점검일: 2026-03-03

## Critical Issues

### 1. ⚠️ NVIDIA GPU 드라이버 미로드

**증상**:
- `nvidia-smi` 실행 실패
- `lsmod | grep nvidia` → 출력 없음
- GPU PCI 장치에 `Kernel driver in use` 항목 없음

**환경**:
- GPU: NVIDIA RTX 5070 (PNY)
- 드라이버: nvidia-driver-590-open v590.48.01 (설치됨)
- DKMS: 3개 커널 버전에 빌드 완료
- Secure Boot: **Enabled**

**원인 추정**:
Secure Boot 환경에서 NVIDIA open kernel module의 서명 미등록.

**해결 방법**:

| 방법 | 난이도 | 설명 |
|------|--------|------|
| 재부팅 | 쉬움 | DKMS 빌드 후 미재부팅인 경우 |
| MOK 키 등록 | 중간 | `sudo mokutil --import /var/lib/shim-signed/mok/MOK.der` 후 재부팅 |
| Secure Boot 비활성화 | 쉬움 | BIOS에서 Secure Boot Off |

**영향 범위**:
- GPU 가속 컴퓨팅 불가 (CUDA, cuDNN)
- Docker GPU 컨테이너 실행 불가
- Ollama GPU 가속 불가
- nvtop GPU 모니터링 불가

---

## Warnings

### 2. ⚠️ CUDA_HOME 환경변수 미설정

**현재 상태**: PATH와 LD_LIBRARY_PATH는 설정됨, CUDA_HOME만 누락.

**권장 조치**:
```bash
# ~/.bashrc 또는 ~/.profile에 추가
export CUDA_HOME=/usr/local/cuda
```

일부 ML 프레임워크(PyTorch 빌드 등)에서 CUDA_HOME을 참조함.

### 3. ⚠️ Ollama 서비스 비활성

**현재 상태**: snap.ollama.listener.service는 enabled이지만 서비스 inactive.

**조치**:
```bash
sudo snap start ollama
```

### 4. ⚠️ MicroK8s 미실행

**현재 상태**: microk8s-llm.service enabled이지만 실행되지 않음.

**확인 필요**: 의도적 비활성화인지, 설정 이슈인지 확인.

### 5. ⚠️ 레거시 NVIDIA Docker 저장소

`/etc/apt/sources.list.d/nvidia-docker.list` 파일 존재.
현재는 nvidia-container-toolkit으로 대체되었으므로 정리 검토.

---

## Recommendations

### 환경 개선

| 항목 | 우선순위 | 설명 |
|------|---------|------|
| NVIDIA 드라이버 로드 | **높음** | GPU 사용의 전제조건 |
| CUDA_HOME 설정 | 낮음 | ML 프레임워크 호환성 |
| Ollama 시작 | 낮음 | 필요 시 수동 시작 |
| 레거시 repo 정리 | 낮음 | nvidia-docker.list 제거 |

### 추가 설치 검토

| 도구 | 용도 | 필요성 |
|------|------|--------|
| PyTorch | ML 프레임워크 | GPU 드라이버 해결 후 |
| conda / pyenv | Python 버전 관리 | 다중 프로젝트 시 유용 |
| Go / Rust | 시스템 프로그래밍 | 필요 시 |

---

## Resolution Log

> 이슈 해결 시 아래에 기록

| 날짜 | 이슈 | 해결 방법 | 결과 |
|------|------|----------|------|
| | | | |
