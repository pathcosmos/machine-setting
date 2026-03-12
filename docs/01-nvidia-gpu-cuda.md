# NVIDIA GPU, CUDA & cuDNN 설치

> 최종 점검일: 2026-03-03

## 1. GPU 하드웨어

```
01:00.0 VGA compatible controller: NVIDIA Corporation [RTX 5070] (rev a1)
        Subsystem: PNY
```

- **GPU**: RTX 5070 계열
- **제조사**: PNY
- **iGPU**: Intel AlderLake-S GT1 (i915 드라이버로 정상 작동 중)

## 2. NVIDIA 드라이버

### 설치된 패키지

| 패키지 | 버전 |
|--------|------|
| nvidia-driver-590-open | 590.48.01 |
| nvidia-dkms-590-open | 590.48.01 |
| nvidia-kernel-source-590-open | 590.48.01 |
| nvidia-kernel-common-590 | 590.48.01 |
| nvidia-compute-utils-590 | 590.48.01 |
| nvidia-utils-590 | 590.48.01 |
| nvidia-settings | 590.48.01 |
| nvidia-firmware-590 | 590.48.01 |
| nvidia-prime | 0.8.17.2 |
| libnvidia-gl-590 | 590.48.01 |
| libnvidia-compute-590 | 590.48.01 |
| libnvidia-encode-590 | 590.48.01 |
| libnvidia-decode-590 | 590.48.01 |
| xserver-xorg-video-nvidia-590 | 590.48.01 |

### DKMS 빌드 상태

```
nvidia/590.48.01, 6.8.0-86-generic, x86_64:  installed
nvidia/590.48.01, 6.8.0-100-generic, x86_64: installed
nvidia/590.48.01, 6.8.0-101-generic, x86_64: installed
```

3개 커널 버전 모두 DKMS 빌드 완료.

### modprobe 설정

```
# /etc/modprobe.d/blacklist-framebuffer.conf
blacklist nvidiafb

# /etc/modprobe.d/nvidia-graphics-drivers-kms.conf
options nvidia_drm modeset=1
options nvidia NVreg_PreserveVideoMemoryAllocations=1
options nvidia NVreg_TemporaryFilePath=/var
```

### 현재 상태: ⚠️ 드라이버 미로드

- `lsmod | grep nvidia` → 출력 없음 (모듈 미로드)
- `nvidia-smi` → 실패 ("couldn't communicate with the NVIDIA driver")
- **Secure Boot**: Enabled

### 원인 분석

Secure Boot가 활성화된 상태에서 DKMS 모듈은 서명이 필요합니다.
NVIDIA open kernel module이 Secure Boot 환경에서 로드되지 않는 것이 원인으로 추정됩니다.

### 해결 방법

**Option A: MOK (Machine Owner Key) 등록**
```bash
# DKMS 설치 시 생성된 MOK 키 등록 확인
sudo mokutil --list-new
# 또는 수동 등록
sudo mokutil --import /var/lib/shim-signed/mok/MOK.der
# 재부팅 후 MOK Manager에서 키 등록 승인
sudo reboot
```

**Option B: Secure Boot 비활성화**
BIOS 설정에서 Secure Boot를 Disabled로 변경 후 재부팅.

**Option C: 재부팅 시도**
DKMS 빌드 후 아직 재부팅하지 않았다면 재부팅만으로 해결 가능.
```bash
sudo reboot
```

## 3. CUDA Toolkit

### 설치 정보

| 항목 | 값 |
|------|-----|
| 버전 | CUDA 13.0.2 |
| 설치 경로 | /usr/local/cuda-13.0 |
| 심볼릭 링크 | /usr/local/cuda → /usr/local/cuda-13.0 |
| 설치 방법 | APT (NVIDIA 공식 저장소) |

### 주요 CUDA 패키지

| 패키지 | 버전 |
|--------|------|
| cuda-toolkit-13-0 | 13.0.2 |
| cuda-nvcc-13-0 | 13.0.88 |
| cuda-cudart-13-0 | 13.0.96 |
| cuda-libraries-13-0 | 13.0.2 |
| cuda-libraries-dev-13-0 | 13.0.2 |
| cuda-compiler-13-0 | 13.0.2 |
| cuda-gdb-13-0 | 13.0.85 |
| cuda-nsight-compute-13-0 | 13.0.2 |
| cuda-nsight-systems-13-0 | 13.0.2 |
| nsight-compute-2025.3.1 | 2025.3.1.4 |

### 환경 변수

```bash
# PATH에 포함됨
/usr/local/cuda/bin

# LD_LIBRARY_PATH에 포함됨
/usr/local/cuda/lib64

# CUDA_HOME은 미설정 (설정 권장)
# export CUDA_HOME=/usr/local/cuda
```

### APT 저장소

```
# /etc/apt/sources.list.d/cuda.list
deb [signed-by=/usr/share/keyrings/nvidia-cuda-archive-keyring.gpg] \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /
```

## 4. cuDNN

| 항목 | 값 |
|------|-----|
| 버전 | cuDNN 9.19.1.2 |
| CUDA 호환 | CUDA 13 |

### 설치된 패키지

| 패키지 | 버전 |
|--------|------|
| cudnn9-cuda-13 | 9.19.1.2 |
| cudnn9-cuda-13-1 | 9.19.1.2 |
| libcudnn9-cuda-13 | 9.19.1.2 |
| libcudnn9-dev-cuda-13 | 9.19.1.2 |
| libcudnn9-headers-cuda-13 | 9.19.1.2 |
| libcudnn9-static-cuda-13 | 9.19.1.2 |

## 5. 기타 NVIDIA 라이브러리

| 패키지 | 버전 | 용도 |
|--------|------|------|
| libcufile-13-0 | 1.15.1.6 | GPUDirect Storage |
| libcusolver-13-0 | 12.0.4.66 | Linear solver |
| libnvptxcompiler-13-0 | 13.0.88 | PTX compiler |
| libnvvm-13-0 | 13.0.88 | NVVM IR compiler |

## 6. 관련 systemd 서비스

| 서비스 | 상태 | 용도 |
|--------|------|------|
| nvidia-hibernate.service | enabled | GPU 하이버네이트 |
| nvidia-resume.service | enabled | GPU 레쥼 |
| nvidia-suspend.service | enabled | GPU 서스펜드 |
| nvidia-cdi-refresh.service | enabled | Container Device Interface 갱신 |
| gpu-manager.service | enabled | GPU 관리자 |
