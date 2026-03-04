# Docker 컨테이너 서비스 현황

> 최종 점검일: 2026-03-03

## 실행 중인 서비스 (14개)

### 인프라/관리

| 컨테이너 | 이미지 | 포트 | 용도 |
|----------|--------|------|------|
| portainer | portainer/portainer-ce:latest | 8000, 9000, 9443 | Docker 관리 UI |

### CRM 시스템

| 컨테이너 | 이미지 | 포트 | 용도 |
|----------|--------|------|------|
| crm-timescaledb | timescale/timescaledb:2.14.2-pg15 | 5432 | TimescaleDB (PostgreSQL 15) |
| crm-pgadmin | dpage/pgadmin4:8.13 | 8080 | PostgreSQL 관리 UI |
| crm-clickhouse | clickhouse/clickhouse-server:24.1 | 8123, 9009, 19000 | ClickHouse 분석 DB |
| crm-clickhouse-tabix | spoonest/clickhouse-tabix-web-client:latest | 8124 | ClickHouse 웹 UI |

### IBA 시스템

| 컨테이너 | 이미지 | 포트 | 용도 |
|----------|--------|------|------|
| iba-mariadb | mariadb:11.3 | 3307 | MariaDB |
| iba-phpmyadmin | phpmyadmin/phpmyadmin:latest | 8083 | MariaDB 관리 UI |

### n8n 자동화

| 컨테이너 | 이미지 | 포트 | 용도 |
|----------|--------|------|------|
| n8n | docker.n8n.io/n8nio/n8n | 5678 (내부) | 워크플로우 자동화 |
| n8n-traefik | traefik:v3.2 | 8087(HTTP), 8084(Dashboard) | 리버스 프록시 |
| n8n-postgres | postgres:16-alpine | 5432 (내부) | n8n 메타데이터 DB |

### AI/RAG

| 컨테이너 | 이미지 | 포트 | 용도 |
|----------|--------|------|------|
| rag-chromadb | chromadb/chroma:latest | 8081 | 벡터 DB (RAG용) |

### Legal 시스템

| 컨테이너 | 이미지 | 포트 | 용도 |
|----------|--------|------|------|
| legal-postgres | pgvector/pgvector:pg16 | 5433 | PostgreSQL + pgvector |

### 애플리케이션

| 컨테이너 | 이미지 | 포트 | 용도 |
|----------|--------|------|------|
| power_checklist_app | power_checklist_app_image | 8001 | 체크리스트 앱 |
| power_checklist_db | mariadb:10.6 | 3306 (내부) | 체크리스트 DB |

## 포트 매핑 요약

| 포트 | 서비스 | 프로토콜 |
|------|--------|----------|
| 5432 | crm-timescaledb | PostgreSQL |
| 5433 | legal-postgres (pgvector) | PostgreSQL |
| 8000 | portainer (Edge Agent) | HTTP |
| 8001 | power_checklist_app | HTTP |
| 8080 | crm-pgadmin | HTTP |
| 8081 | rag-chromadb | HTTP |
| 8083 | iba-phpmyadmin | HTTP |
| 8084 | n8n-traefik (Dashboard) | HTTP |
| 8087 | n8n (via traefik) | HTTP |
| 8123 | crm-clickhouse (HTTP) | HTTP |
| 8124 | crm-clickhouse-tabix | HTTP |
| 9000 | portainer (Web UI) | HTTP |
| 9009 | crm-clickhouse (Native) | TCP |
| 9443 | portainer (HTTPS) | HTTPS |
| 19000 | crm-clickhouse (Client) | TCP |
| 3307 | iba-mariadb | MySQL |

## Docker 이미지 (빌드 포함)

| 이미지 | 태그 | 크기 |
|--------|------|------|
| power_checklist_app_image | latest | 346MB |
| realtime_app-frontend | latest | 304MB |
| realtime_app-backend | latest | 1.05GB |
| docker.n8n.io/n8nio/n8n | latest | 1.08GB |
| nvidia/cuda | 13.0.0-base-ubuntu24.04 | 411MB |
| chromadb/chroma | latest | 580MB |
| pgvector/pgvector | pg16 | 507MB |
| portainer/portainer-ce | latest | 186MB |
| phpmyadmin/phpmyadmin | latest | 742MB |
| mariadb | 10.6 | 309MB |
| postgres | 16-alpine | 276MB |
| postgres | 15-alpine | 274MB |
| chrislusf/seaweedfs | latest | 187MB |
| traefik | v3.2 | - |
| clickhouse/clickhouse-server | 24.1 | - |
| timescale/timescaledb | 2.14.2-pg15 | - |
| mariadb | 11.3 | - |
| dpage/pgadmin4 | 8.13 | - |
