# Machine Setting - 자동화 시스템 관리

## 프로젝트 개요
이 디렉토리는 lanco의 Mac에서 돌아가는 모든 자동화 시스템의 설정과 관리를 다룬다.

## 시스템 구성

### Claude Channel (Telegram)
- 봇: (access.json 참조)
- 실행: tmux 세션 `claude-telegram` → `claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official`
- 래퍼: `~/.claude/claude-channels-wrapper.sh` (launchd: `com.anthropic.claude-channels`)
- 플러그인: `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram`
- 접근 제어: `~/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/access.json`
- 허용 사용자: access.json에서 관리 (DM allowlist)
- **주의**: `--channels`는 인터랙티브 TUI 전용. launchd에서 직접 실행 불가 → tmux로 PTY 제공 필수.
- **토큰 격리**: 봇 토큰은 `.env`가 아닌 `~/.claude/channels/telegram/.bot-token`에 보관. 래퍼만 환경변수로 주입하여 채널 세션만 polling. 일반 세션은 토큰 없어서 플러그인 자동 종료. (상세: `docs/11-telegram-channel-polling-fix.md`)

### NLP Chrome 수집 시스템
- 프로젝트: `/Users/lanco/taketimes/nlp-chrome/`
- DB: Docker `nlp-chrome-db` (PostgreSQL 16, port 5432)
- 수집 대상 (8개 사이트): itssa, naver_news, mlbpark, ilbe, joongang_news, chosun_news, donga_news, fmkorea
- 댓글 수집: comments 테이블 (5개 사이트)
- 분석: smilegate-ai/kor_unsmile 혐오 감지 모델
- API: FastAPI `http://localhost:8000`

### Docker 컨테이너 (5개)
- `nlp-chrome-db` — PostgreSQL
- `nlp-api` — FastAPI 서버
- `nlp-analyzer` — 혐오 감지 분석기
- `nlp-collectors` — 8개 사이트 수집기 (Xvfb 가상 디스플레이)
- `nlp-comment-backfill` — 댓글 역수집
- Docker 런타임: Colima (`colima start`로 시작)

## 스크립트 폴더

```
~/.openclaw/workspace/
├── .env                    ← 공통 credential (EMAIL, RAPIDAPI, BIZINFO)
└── scripts/
    ├── rental-car/         ← 렌트카 모니터링 (rental_combined.py 등)
    ├── flight-search/      ← 항공편 검색
    ├── gov-support/        ← 정부지원사업 모니터 (Playwright 크롤링)
    ├── nlp-report/         ← NLP 리포트 + 시스템 감시
    │   ├── nlp_daily_report.py    — 일일 리포트 (글 + 댓글)
    │   ├── collector_watchdog.py  — 수집 상태 점검 스크립트
    │   └── chrome_monitor.sh     — Chrome 프로세스 감시 데몬
    └── daily-briefing/     ← 일일 브리핑 + 토큰 리포트
```

## Cron Jobs (launchd, 활성 6개)

| 이름 | 스케줄 | launchd Label | 스크립트 |
|------|--------|---------------|----------|
| 시스템 감시 Watchdog | 3시간마다 | com.lanco.system-watchdog | nlp-report/collector_watchdog.py |
| NLP Chrome Daily Report | 매일 19:00 | com.lanco.nlp-daily-report | nlp-report/nlp_daily_report.py |
| 정부지원사업 모니터 (9AM) | 매일 09:00 | com.lanco.gov-support-9am | gov-support/main.py |
| 정부지원사업 모니터 (7PM) | 매일 19:00 | com.lanco.gov-support-7pm | gov-support/main.py |
| 렌트카 통합 검색 (9AM) | 매일 09:00 | com.lanco.rental-car-9am | rental-car/rental_combined.py |
| Daily Briefing (10PM) | 매일 22:00 | com.lanco.daily-briefing | daily-briefing/daily_briefing.py |

## launchd 서비스

| 서비스 | 상태 | 역할 |
|--------|------|------|
| com.anthropic.claude-channels | 활성 | Claude Channel (Telegram) — tmux 래퍼 |
| com.lanco.chrome-monitor | 활성 | 불필요 Chrome 프로세스 감시/종료 |
| com.lanco.log-rotate | 활성 | 로그 로테이션 |
| com.lanco.system-watchdog | 활성 | NLP 수집 상태 점검 (3시간마다) |
| com.lanco.nlp-daily-report | 활성 | NLP 일일 리포트 (19:00) |
| com.lanco.gov-support-9am | 활성 | 정부지원사업 (09:00) |
| com.lanco.gov-support-7pm | 활성 | 정부지원사업 (19:00) |
| com.lanco.rental-car-9am | 활성 | 렌트카 검색 (09:00) |
| com.lanco.daily-briefing | 활성 | 일일 브리핑 (22:00) |

## 핵심 규칙

1. **fmkorea는 Docker 내부에서만 수집** — 네이티브(launchd) 서비스 절대 재활성화 금지. Chrome 창이 뜨는 원인이었음.
2. **credential은 .env에서 관리** — 스크립트에 하드코딩 금지. 경로: `~/.openclaw/workspace/.env`
3. **watchdog은 최근 1h/3h 기준** — CURRENT_DATE 사용 금지 (UTC 자정 리셋 오탐 방지)
4. **RapidAPI (Priceline) 구독 만료** — 렌트카 API 검색은 현재 작동하지 않음. 링크 발송만 동작.
5. **수집 중단 감지 시 자동 복구** — watchdog이 3시간마다 점검, 문제 시 이메일 알림
6. **Claude Channel은 tmux 필수** — `--channels` 플래그는 인터랙티브 TUI 모드에서만 동작. launchd 래퍼가 tmux 세션을 생성.
7. **OpenClaw은 제거됨** — 2026-04-07 기준 모든 cron/gateway를 launchd + Claude Channel로 이관 완료. OpenClaw 재활성화 금지.
8. **텔레그램 봇 토큰은 .bot-token에만** — `.env`에 토큰 넣지 말 것. 여러 세션이 polling 경쟁하여 메시지 유실됨. 래퍼가 환경변수로 주입.

## 자주 쓰는 명령어

```bash
# Claude Channel (Telegram)
tmux has-session -t claude-telegram       # 채널 세션 확인
tmux capture-pane -t claude-telegram -p   # 채널 화면 확인
launchctl stop com.anthropic.claude-channels && sleep 2 && launchctl start com.anthropic.claude-channels  # 채널 재시작

# Cron Job 관리
launchctl list | grep com.lanco          # 전체 작업 목록
launchctl start com.lanco.system-watchdog # 수동 실행

# NLP 수집 확인
docker exec nlp-chrome-db psql -U nlp -d nlp_chrome -t -A -c "SELECT site, COUNT(*) FROM raw_texts WHERE collected_at > NOW() - INTERVAL '1 hour' GROUP BY site ORDER BY COUNT(*) DESC"

# 댓글 확인
docker exec nlp-chrome-db psql -U nlp -d nlp_chrome -t -A -c "SELECT s.name, COUNT(c.id) FROM comments c JOIN sources s ON c.source_id = s.id WHERE c.scraped_at > NOW() - INTERVAL '1 hour' GROUP BY s.name ORDER BY COUNT(*) DESC"

# Docker
docker ps --format "{{.Names}} {{.Status}}" | grep nlp
docker restart nlp-collectors
docker logs nlp-collectors --tail 50

# Colima (Docker 런타임)
colima status                             # VM 상태
colima start                              # VM 시작 (재부팅 후)
```
