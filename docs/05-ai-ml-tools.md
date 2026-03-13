# AI/ML Tools 설치

> 최종 점검일: 2026-03-03

## 1. Ollama

| 항목 | 값 |
|------|-----|
| 버전 | 0.15.1 |
| 설치 방법 | Snap 패키지 |
| 서비스 상태 | inactive (비활성) |

### Snap 정보

```
ollama  v0.15.1  Rev 105  latest/stable  mz2
```

### 서비스 제어

```bash
# 시작
sudo snap start ollama

# 상태 확인
systemctl status snap.ollama.ollama

# 모델 목록
ollama list
```

### 관련 systemd 서비스

- `snap.ollama.listener.service` → enabled

## 2. RAG 인프라

### ChromaDB (벡터 데이터베이스)

| 항목 | 값 |
|------|-----|
| 이미지 | chromadb/chroma:latest |
| 컨테이너 | rag-chromadb |
| 포트 | 8081 (→ 내부 8000) |
| 상태 | Running |

### pgvector (PostgreSQL 벡터 확장)

| 항목 | 값 |
|------|-----|
| 이미지 | pgvector/pgvector:pg16 |
| 컨테이너 | legal-postgres |
| 포트 | 5433 |
| 상태 | Running |

## 3. n8n (AI 워크플로우)

| 항목 | 값 |
|------|-----|
| 이미지 | docker.n8n.io/n8nio/n8n |
| 접근 URL | http://localhost:8087 |
| 상태 | Running |

AI Agent 워크플로우 자동화에 활용 가능.

## 4. CUDA/cuDNN (ML 가속)

GPU 기반 머신러닝을 위한 CUDA 스택 설치 완료.
상세 내용은 [01-nvidia-gpu-cuda.md](./01-nvidia-gpu-cuda.md) 참조.

| 항목 | 버전 |
|------|------|
| CUDA Toolkit | 13.0.2 |
| cuDNN | 9.19.1.2 |

### NVIDIA Container Toolkit

Docker 컨테이너에서 GPU 사용을 위한 런타임.
상세 내용은 [02-docker.md](./02-docker.md) 참조.

| 항목 | 버전 |
|------|------|
| nvidia-container-toolkit | 1.18.2 |

### GPU 컨테이너 이미지

```
nvidia/cuda:13.0.0-base-ubuntu24.04 (411MB)
```

## 5. 현재 상태 및 제한사항

| 항목 | 상태 | 비고 |
|------|------|------|
| Ollama | ⚠️ 비활성 | snap start 필요 |
| ChromaDB | ✅ 실행 중 | 포트 8081 |
| pgvector | ✅ 실행 중 | 포트 5433 |
| n8n | ✅ 실행 중 | 포트 8087 |
| GPU 가속 | ❌ 불가 | NVIDIA 드라이버 미로드 |
| PyTorch / TensorFlow | - | pip에 미설치 (필요 시 설치) |
