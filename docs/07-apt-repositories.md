# APT Repositories & Package Sources

> 최종 점검일: 2026-03-03

## 1. 외부 APT 저장소

### NVIDIA CUDA

```
# /etc/apt/sources.list.d/cuda.list
deb [signed-by=/usr/share/keyrings/nvidia-cuda-archive-keyring.gpg] \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /
```

- **용도**: CUDA Toolkit, NVIDIA 드라이버
- **키링**: nvidia-cuda-archive-keyring.gpg

### NVIDIA Container Toolkit

```
# /etc/apt/sources.list.d/nvidia-container-toolkit.list
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] \
    https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /
```

- **용도**: nvidia-container-toolkit, libnvidia-container
- **키링**: nvidia-container-toolkit-keyring.gpg

### Docker CE

```
# /etc/apt/sources.list.d/docker.list
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
    https://download.docker.com/linux/ubuntu noble stable
```

- **용도**: docker-ce, docker-compose-plugin, docker-buildx-plugin
- **키링**: /etc/apt/keyrings/docker.asc

### GitHub CLI

```
# /etc/apt/sources.list.d/github-cli.list
deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main
```

- **용도**: gh (GitHub CLI)
- **키링**: githubcli-archive-keyring.gpg

### Amazon Corretto (Java)

```
# /etc/apt/sources.list.d/archive_uri-https_apt_corretto_aws-noble.list
deb [signed-by=/usr/share/keyrings/corretto-archive-keyring.gpg] \
    https://apt.corretto.aws stable main
```

- **용도**: OpenJDK 17 (Amazon Corretto)
- **키링**: corretto-archive-keyring.gpg

### ClickHouse

```
# /etc/apt/sources.list.d/clickhouse.list
deb https://packages.clickhouse.com/deb stable main
```

- **용도**: clickhouse-client, clickhouse-server

### NVIDIA Graphics Drivers PPA

```
# /etc/apt/sources.list.d/graphics-drivers-ubuntu-ppa-noble.sources
# Ubuntu PPA 형식 (DEB822)
```

- **용도**: 추가 NVIDIA 그래픽 드라이버

## 2. 비활성 저장소

| 파일 | 상태 | 비고 |
|------|------|------|
| nvidia-cuda-ubuntu2404.list.bak | 비활성 (.bak) | 이전 CUDA 저장소 |
| nvidia-docker.list | 확인 필요 | 레거시 nvidia-docker |

## 3. 시스템 기본 저장소

| 파일 | 용도 |
|------|------|
| ubuntu.sources | Ubuntu 24.04 공식 저장소 |
| ubuntu.sources.curtin.orig | 원본 백업 |

## 4. 키링 파일

| 키링 | 저장소 |
|------|--------|
| corretto-archive-keyring.gpg | Amazon Corretto |
| cudnn-local-08A7D361-keyring.gpg | cuDNN 로컬 |
| githubcli-archive-keyring.gpg | GitHub CLI |
| nvidia-container-toolkit-keyring.gpg | NVIDIA Container Toolkit |
| nvidia-cuda-archive-keyring.gpg | NVIDIA CUDA |
| nvidia-cuda-keyring.gpg | NVIDIA CUDA (보조) |
| /etc/apt/keyrings/docker.asc | Docker CE |

## 5. Snap 패키지

APT 외에 Snap을 통해 설치된 패키지:

| 패키지 | 버전 | 채널 |
|--------|------|------|
| core20 | 20260105 | latest/stable |
| core22 | 20260128 | latest/stable |
| core24 | 20260107 | latest/stable |
| lxd | 5.21.4 | 5.21/stable |
| ollama | v0.15.1 | latest/stable |
| snapd | 2.73 | latest/stable |
