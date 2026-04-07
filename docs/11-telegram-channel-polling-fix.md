# Telegram Channel Polling 충돌 수정

> **날짜**: 2026-04-07
> **상태**: 완료
> **영향**: Claude Channel (Telegram) 메시지 수신 불가 해소

## 문제 현상

Telegram 봇이 메시지에 응답하지 않는 현상이 반복 발생.

## 근본 원인 분석

### Telegram Bot API의 제약

Telegram Bot API의 `getUpdates` (long-polling) 방식은 **하나의 연결만 허용**한다. 두 개 이상의 클라이언트가 동시에 polling하면 `409 Conflict` 에러가 발생하고, 메시지가 유실되거나 한쪽만 수신한다.

### 경쟁 구조

```
[Claude Channel 세션]  ──→ bun server.ts ──→ getUpdates (polling)
                                                    ↕ 409 Conflict
[일반 Claude Code 세션] ──→ bun server.ts ──→ getUpdates (polling)
                                                    ↕ 409 Conflict
[좀비 bun 프로세스]     ──→ bun server.ts ──→ getUpdates (polling)
```

**왜 여러 개가 뜨나?**

1. `~/.claude/settings.json`에서 `enabledPlugins.telegram@claude-plugins-official: true`로 설정됨
2. 이 설정 때문에 **모든** Claude Code 세션이 텔레그램 MCP 플러그인을 로드
3. 각 플러그인 인스턴스가 독립적으로 `~/.claude/channels/telegram/.env`에서 봇 토큰을 읽음
4. 각각 `bot.start()`로 long-polling 시작 → 서로 경쟁

### 발견 당시 상태 (2026-04-07)

| PID | 시작 시간 | 위치 | 역할 |
|-----|----------|------|------|
| 23394/23400 | 07:21 AM | s001 | **좀비** — 이전 세션에서 남은 프로세스 |
| 5408/5411 | 10:08 PM | s002 | 채널 세션 (정상) |
| 4323/4325 | 09:59 PM | s000 | 현재 대화 세션 (의도치 않은 경쟁자) |

3개의 polling 인스턴스가 동시에 동작하면서 메시지 수신 불가.

## 해결책: 토큰 격리 (Token Isolation)

### 핵심 아이디어

봇 토큰을 `.env` 파일에서 제거하여 **채널 세션만** 토큰을 가질 수 있도록 격리한다.

### server.ts의 토큰 로딩 로직 (활용 포인트)

```javascript
// 1. .env 파일에서 읽되, 이미 환경변수가 있으면 무시
for (const line of readFileSync(ENV_FILE, 'utf8').split('\n')) {
  const m = line.match(/^(\w+)=(.*)$/)
  if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2]
}

// 2. 토큰 없으면 종료
if (!TOKEN) {
  process.exit(1)
}
```

**환경변수 우선순위**: `process.env`에 이미 있으면 `.env` 파일을 무시한다.

### 변경 사항

#### 1. 토큰 파일 분리

```
~/.claude/channels/telegram/
├── .env        ← 비움 (코멘트만 남김)
├── .bot-token  ← 실제 토큰 저장 (래퍼만 읽음)
└── access.json
```

**`.env` (변경 후)**:
```
# Token moved to .bot-token — only the channel wrapper injects it.
```

**`.bot-token` (신규)**:
```
TELEGRAM_BOT_TOKEN=<token>
```

#### 2. 래퍼 스크립트 업데이트 (`~/.claude/claude-channels-wrapper.sh`)

```bash
# 토큰 파일 읽기
TOKEN_FILE="$HOME/.claude/channels/telegram/.bot-token"
export TELEGRAM_BOT_TOKEN
TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' "$TOKEN_FILE" | cut -d= -f2-)

# tmux 세션 시작 — 환경변수가 자동 전파됨
# wrapper → tmux → claude → bun server.ts
tmux new-session -d -s claude-telegram -x 200 -y 50 \
  'claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official'
```

### 동작 원리

```
[채널 세션]
  래퍼 → export TELEGRAM_BOT_TOKEN → tmux → claude → bun server.ts
  → process.env.TELEGRAM_BOT_TOKEN 존재 → polling 시작 ✅

[일반 Claude Code 세션]
  claude → bun server.ts
  → process.env.TELEGRAM_BOT_TOKEN 없음
  → .env 읽기 → 토큰 없음
  → process.exit(1) → polling 안 함 ✅
```

## 시도했다가 폐기한 접근법

### 1. 경쟁 프로세스 kill (pkill)

- 래퍼에서 `pkill -f "bun.*telegram.*server.ts"` 실행
- **문제**: 현재 대화 세션의 MCP 연결까지 끊어버림 → 대화 중 텔레그램 도구 사용 불가
- **폐기 사유**: 부작용이 크고, 새 세션이 뜰 때마다 재발

### 2. 전역 플러그인 비활성화 (enabledPlugins: false)

- `settings.json`에서 `telegram@claude-plugins-official: false`
- **문제**: `--channels` 플래그도 이 설정을 따름 → 채널 세션에서도 플러그인 로드 안 됨
- **폐기 사유**: 채널 기능 자체가 죽음

### 3. 30초 감시 루프 (monitoring loop)

- 래퍼에서 30초마다 채널 세션 외의 telegram bun 프로세스를 kill
- **문제**: 프로세스 트리 추적이 복잡하고, 여전히 MCP 연결 끊김 부작용
- **폐기 사유**: 토큰 격리 방식이 더 깔끔하고 부작용 없음

## 검증 결과

수정 후 확인 사항:
- [x] 채널 세션: bun 프로세스 1개만 동작 (polling 정상)
- [x] 일반 세션: 토큰 없어서 플러그인 자동 종료 (경쟁 없음)
- [x] 래퍼 스크립트: 토큰 파일 읽기 + 환경변수 주입 정상
- [x] 기존 기능: 채널 메시지 수신/응답 정상

## 향후 참고사항

- 새로운 Claude Code 세션을 열어도 텔레그램 플러그인은 토큰이 없어서 자동 종료됨
- 추가 플러그인/기능이 추가되어도 이 구조에 영향 없음
- 봇 토큰 변경 시 `~/.claude/channels/telegram/.bot-token` 파일만 수정하면 됨
- `enabledPlugins: true`는 유지 — 채널 세션에서 플러그인 로드에 필요
