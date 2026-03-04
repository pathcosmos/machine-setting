# Docker 설치

> 최종 점검일: 2026-03-03

## 1. Docker Engine

| 항목 | 값 |
|------|-----|
| Docker CE | 29.2.1 |
| Docker CLI | 29.2.1 |
| containerd | enabled (systemd) |
| 서비스 상태 | active (running) |

### 설치된 패키지

| 패키지 | 버전 |
|--------|------|
| docker-ce | 5:29.2.1-1~ubuntu.24.04~noble |
| docker-ce-cli | 5:29.2.1-1~ubuntu.24.04~noble |
| docker-ce-rootless-extras | 5:29.2.1-1~ubuntu.24.04~noble |
| docker-buildx-plugin | 0.31.1-1~ubuntu.24.04~noble |
| docker-compose-plugin | 5.1.0-1~ubuntu.24.04~noble |
| docker-model-plugin | 1.1.8-1~ubuntu.24.04~noble |

### Docker Compose

| 항목 | 값 |
|------|-----|
| 버전 | v5.1.0 (plugin 방식) |
| 실행 | `docker compose` (V2 CLI) |

### 설치 방법

Docker 공식 APT 저장소를 통한 설치:

```
# /etc/apt/sources.list.d/docker.list
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu noble stable
```

### 사용자 권한

`lanco` 사용자가 `docker` 그룹에 포함되어 있어 sudo 없이 docker 명령 사용 가능.

```bash
groups lanco
# → ... docker
```

## 2. NVIDIA Container Toolkit

GPU 워크로드를 Docker 컨테이너에서 실행하기 위한 도구.

| 패키지 | 버전 |
|--------|------|
| nvidia-container-toolkit | 1.18.2 |
| nvidia-container-toolkit-base | 1.18.2 |
| libnvidia-container-tools | 1.18.2 |
| libnvidia-container1 | 1.18.2 |

### APT 저장소

```
# /etc/apt/sources.list.d/nvidia-container-toolkit.list
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] \
    https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /
```

### NVIDIA CUDA 베이스 이미지

```
nvidia/cuda:13.0.0-base-ubuntu24.04 (411MB)
```

### 현재 상태: ⚠️ GPU 드라이버 미로드

NVIDIA 드라이버가 로드되지 않은 상태이므로 GPU 컨테이너 실행 불가.
드라이버 문제 해결 후 아래 명령으로 테스트 가능:

```bash
docker run --rm --gpus all nvidia/cuda:13.0.0-base-ubuntu24.04 nvidia-smi
```

## 3. Docker 네트워크

| 네트워크 | 인터페이스 | IP |
|----------|-----------|-----|
| bridge (기본) | docker0 | 172.17.0.1/16 |

## 4. 디스크 사용

Docker 데이터는 기본 경로 `/var/lib/docker`에 저장 (OS 디스크, nvme0n1).
