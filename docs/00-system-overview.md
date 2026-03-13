# System Overview

> 최종 점검일: 2026-03-03

## Hardware Specification

| 항목 | 사양 |
|------|------|
| CPU | 13th Gen Intel Core i5-13500 (14코어 / 20스레드) |
| RAM | 64GB DDR |
| GPU (Discrete) | NVIDIA RTX 5070 (PNY) |
| GPU (Integrated) | Intel AlderLake-S GT1 (UHD 770) |
| Motherboard | MSI (Raptor Lake 칩셋) |
| Storage (OS) | NVMe SSD (1TB) → `/` 마운트 |
| Storage (Home) | NVMe SSD (2TB) → `/home` 마운트 |
| NIC (Wired) | Realtek RTL8125 2.5GbE |
| NIC (Wireless) | Intel Raptor Lake-S PCH CNVi WiFi |
| Audio | Intel Raptor Lake HD Audio + NVIDIA HDMI Audio |

## OS & Kernel

| 항목 | 버전 |
|------|------|
| OS | Ubuntu 24.04.3 LTS (Noble Numbat) |
| Kernel | 6.8.0-101-generic (PREEMPT_DYNAMIC) |
| Timezone | Asia/Seoul (KST, +0900) |
| Secure Boot | Enabled |

## Disk Layout

```
nvme0n1 (953.9G) - NVMe SSD (1TB)
├── nvme0n1p1 (1G)    vfat   /boot/efi
└── nvme0n1p2 (952.8G) ext4  /

nvme1n1 (1.8T) - NVMe SSD (2TB)
└── nvme1n1p1 (1.8T)   ext4  /home
```

## Network

| 인터페이스 | 유형 | IP |
|------------|------|-----|
| enp5s0 | Realtek 2.5GbE (유선) | 192.168.1.100/24 |
| wlo1 | Intel WiFi | (미연결) |
| docker0 | Docker bridge | 172.17.0.1/16 |

## User & Groups

- **사용자**: `user`
- **그룹**: user, adm, cdrom, sudo, dip, plugdev, lxd, microk8s, llmadmin, smbuser, docker

## 문서 목록

| 문서 | 내용 |
|------|------|
| [01-nvidia-gpu-cuda.md](./01-nvidia-gpu-cuda.md) | NVIDIA 드라이버, CUDA, cuDNN 설치 |
| [02-docker.md](./02-docker.md) | Docker, Docker Compose, NVIDIA Container Toolkit |
| [03-docker-services.md](./03-docker-services.md) | Docker 컨테이너 서비스 현황 |
| [04-development-tools.md](./04-development-tools.md) | 개발 도구 (Python, Node.js, Java, Git 등) |
| [05-ai-ml-tools.md](./05-ai-ml-tools.md) | AI/ML 도구 (Ollama 등) |
| [06-system-services.md](./06-system-services.md) | 시스템 서비스 및 인프라 |
| [07-apt-repositories.md](./07-apt-repositories.md) | APT 저장소 및 패키지 소스 |
| [08-issues-and-todos.md](./08-issues-and-todos.md) | 알려진 이슈 및 해결 과제 |
