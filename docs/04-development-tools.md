# Development Tools 설치

> 최종 점검일: 2026-03-03

## 1. Python

| 항목 | 값 |
|------|-----|
| 버전 | Python 3.12.3 |
| 경로 | /usr/bin/python3 |
| pip | 24.0 |
| 설치 방법 | Ubuntu 시스템 패키지 |

### 가상환경 도구

- conda: 미설치
- pyenv: 미설치
- venv: 시스템 기본 제공 (`python3 -m venv`)

### 참고

프로젝트별 venv 사용 중 (예: `file_monitor` 서비스는 자체 venv 사용).

## 2. Node.js

| 항목 | 값 |
|------|-----|
| 버전 | v22.18.0 |
| npm | 11.5.2 |
| 경로 | /home/user/.nvm/versions/node/v22.18.0/bin/node |
| 설치 방법 | NVM (Node Version Manager) |

### NVM

```
설치 경로: ~/.nvm/
설치된 버전: v22.18.0
```

## 3. Java

| 항목 | 값 |
|------|-----|
| 버전 | OpenJDK 17.0.18 LTS (2026-01-20) |
| 설치 방법 | Amazon Corretto APT 저장소 |

### APT 저장소

```
# /etc/apt/sources.list.d/archive_uri-https_apt_corretto_aws-noble.list
deb [signed-by=/usr/share/keyrings/corretto-archive-keyring.gpg] \
    https://apt.corretto.aws stable main
```

## 4. Maven

| 항목 | 값 |
|------|-----|
| 버전 | Apache Maven 3.9.4 |
| 경로 | /home/user/maven/apache-maven-3.9.4 |
| 설치 방법 | 수동 설치 (PATH에 추가) |

```bash
# PATH 설정
/home/user/maven/apache-maven-3.9.4/bin
```

## 5. C/C++ Build Tools

| 도구 | 버전 |
|------|------|
| GCC | 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1) |
| GNU Make | 4.3 |
| CMake | 3.28.3 |

## 6. Git

| 항목 | 값 |
|------|-----|
| 버전 | 2.43.0 |

## 7. GitHub CLI

| 항목 | 값 |
|------|-----|
| 버전 | 2.87.3 (2026-02-23) |
| 설치 방법 | APT (GitHub 공식 저장소) |

### APT 저장소

```
# /etc/apt/sources.list.d/github-cli.list
deb [arch=amd64 signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main
```

## 8. Oracle Instant Client

2개 버전 설치:

| 버전 | 경로 |
|------|------|
| 19.8 | /usr/local/oracle/instantclient_19_8 |
| 19.28 | /opt/oracle/instantclient_19_28/instantclient_19_28 |

### 환경 변수

```bash
# PATH
/usr/local/oracle/instantclient_19_8
/opt/oracle/instantclient_19_28/instantclient_19_28

# LD_LIBRARY_PATH
/usr/local/oracle/instantclient_19_8
/opt/oracle/instantclient_19_28/instantclient_19_28
```

## 9. ClickHouse Client

| 항목 | 값 |
|------|-----|
| 버전 | 26.2.3.2 (official build) |
| 설치 방법 | APT (ClickHouse 공식 저장소) |

### APT 저장소

```
# /etc/apt/sources.list.d/clickhouse.list
deb https://packages.clickhouse.com/deb stable main
```

## 10. 유틸리티 도구

| 도구 | 버전 | 용도 |
|------|------|------|
| tmux | 3.4 | 터미널 멀티플렉서 |
| vim | 9.1 | 텍스트 에디터 |
| curl | 8.5.0 | HTTP 클라이언트 |
| wget | 1.21.4 | 파일 다운로더 |
| htop | 3.3.0 | 프로세스 모니터 |
| nvtop | 3.0.2 | GPU 모니터 |

## 11. 미설치 도구

| 도구 | 상태 |
|------|------|
| Go | 미설치 |
| Rust | 미설치 |
| conda / pyenv | 미설치 |
