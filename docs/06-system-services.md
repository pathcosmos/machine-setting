# System Services & Infrastructure

> 최종 점검일: 2026-03-03

## 1. SSH

| 항목 | 값 |
|------|-----|
| 상태 | active (running) |
| 접근 | 192.168.1.100:22 |

## 2. Samba (파일 공유)

| 항목 | 값 |
|------|-----|
| 버전 | 4.19.5-Ubuntu |
| smbd | enabled |
| nmbd | enabled |
| samba-ad-dc | enabled |

사용자 `user`가 `smbuser` 그룹에 포함.

## 3. LXD (컨테이너 가상화)

| 항목 | 값 |
|------|-----|
| 버전 | 5.21.4-8caf727 |
| 설치 방법 | Snap |
| 서비스 | snap.lxd.activate.service (enabled) |

사용자 `user`가 `lxd` 그룹에 포함.

## 4. MicroK8s

| 항목 | 값 |
|------|-----|
| 상태 | 미실행 (not running) |
| 서비스 | microk8s-llm.service (enabled) |

사용자 `user`가 `microk8s` 그룹에 포함.
`llmadmin` 그룹도 존재 → LLM 관련 Kubernetes 워크로드 운영 목적으로 추정.

## 5. 커스텀 서비스: file_monitor

| 항목 | 값 |
|------|-----|
| 서비스 파일 | /etc/systemd/system/file_monitor.service |
| 상태 | enabled |
| 실행 경로 | /home/user/projects/file-monitor |
| 실행 | Python venv 기반 |

### 서비스 설정

```ini
[Unit]
Description=File Monitoring and Auto-Upload Service
After=network.target

[Service]
Type=simple
User=user
Group=user
WorkingDirectory=/home/user/projects/file-monitor
ExecStart=.../venv/bin/python .../src/main.py
Restart=always
RestartSec=5
```

파일 변경을 감시하고 자동 업로드하는 서비스.

## 6. 방화벽 (UFW)

| 항목 | 값 |
|------|-----|
| ufw.service | enabled |
| 상태 | sudo 필요하여 미확인 |

## 7. 주요 시스템 서비스 (enabled)

### 핵심 서비스

| 서비스 | 용도 |
|--------|------|
| docker.service | Docker 데몬 |
| containerd.service | 컨테이너 런타임 |
| ssh (implicit) | SSH 서버 |
| smbd.service | Samba 파일 공유 |
| nmbd.service | Samba NetBIOS |
| snap.ollama.listener.service | Ollama LLM |
| file_monitor.service | 파일 모니터링 자동 업로드 |

### NVIDIA 관련

| 서비스 | 용도 |
|--------|------|
| nvidia-hibernate.service | GPU 하이버네이트 |
| nvidia-resume.service | GPU 레쥼 |
| nvidia-suspend.service | GPU 서스펜드 |
| nvidia-cdi-refresh.service | Container Device Interface |
| gpu-manager.service | GPU 관리 |

### 시스템 기본

| 서비스 | 용도 |
|--------|------|
| systemd-resolved.service | DNS 리졸버 |
| systemd-timesyncd.service | 시간 동기화 |
| systemd-networkd.service | 네트워크 관리 |
| apparmor.service | 보안 프레임워크 |
| unattended-upgrades.service | 자동 보안 업데이트 |
| cron.service | 크론 작업 |
| rsyslog.service | 시스템 로그 |
| thermald.service | 열 관리 |
| smartmontools.service | 디스크 S.M.A.R.T 모니터링 |
| sysstat.service | 시스템 통계 수집 |

## 8. 네트워크 인터페이스

| 인터페이스 | 유형 | 드라이버 | IP | 상태 |
|------------|------|---------|-----|------|
| lo | Loopback | - | 127.0.0.1 | UP |
| enp5s0 | Ethernet | r8169 | 192.168.1.100/24 | UP |
| wlo1 | WiFi | iwlwifi | - | DOWN |
| docker0 | Docker Bridge | bridge | 172.17.0.1/16 | UP |
