# 디스크 검사 및 배드섹터 제외 파티션

Synology NAS에서 사용하던 HDD 5개(sde, sdf, sdg, sdh, sdi)에 대한 **상세 디스크 검사** 절차와, **배드섹터가 있을 때 해당 구간을 제외하고 파티션을 나누는 방법**을 정리합니다.

---

## 1. 검사 순서 요약

| 단계 | 스크립트 | 내용 | 소요 |
|------|----------|------|------|
| 1 | `disk-check-smart.sh` | SMART 속성·건강 상태 수집 | 수 초 |
| 2 | `disk-check-smart-long.sh` | SMART Extended Self-Test (선택) | 디스크당 수 시간 |
| 3 | `disk-check-badblocks.sh` | 전체 디스크 read-only 배드섹터 검사 | 디스크당 수 시간~수십 시간 |

모든 명령은 **root 권한**으로 실행합니다.

```bash
cd /home/user/machine_setting
sudo ./scripts/disk-check-smart.sh                    # 1) SMART 수집
sudo ./scripts/disk-check-smart-long.sh                # 2) 선택: 장시간 SMART 테스트
sudo ./scripts/disk-check-badblocks.sh                 # 3) 병렬 배드섹터 검사
```

기본 결과 디렉토리: `~/disk-check-results/`

- `~/disk-check-results/smart/` — SMART 전체 리포트(`sde.txt` 등), 건강 요약
- `~/disk-check-results/badblocks/` — 배드블록 목록(`sde.badblocks` 등)
- `~/disk-check-results/logs/` — badblocks 실행 로그

---

## 2. 스크립트 상세

### 2.1 SMART 수집 — `disk-check-smart.sh`

- 5개 디스크에 대해 `smartctl -a`, `smartctl -H` 실행
- 결과: `smart/<disk>.txt`, `smart/<disk>-health.txt`
- 요약: Reallocated_Sector_Ct, Current_Pending_Sector, Offline_Uncorrectable 등 출력

```bash
sudo ./scripts/disk-check-smart.sh [/path/to/output]
```

### 2.2 SMART Extended Self-Test — `disk-check-smart-long.sh`

- 5개 디스크에 동시에 `smartctl -t long` 실행
- 디스크 내부에서 전체 표면 검사 (수 시간)
- 진행률: `sudo smartctl -a /dev/sde` 에서 "Self-test execution status" 확인

### 2.3 배드섹터 검사 — `disk-check-badblocks.sh`

- **read-only** 검사 (데이터 변경 없음)
- 5개 디스크를 **동시에** 검사, 각 디스크당 전체 블록(1024바이트 단위) 읽기
- 결과: `badblocks/<disk>.badblocks` — 한 줄에 배드블록 번호 하나
- 이미 결과 파일이 있으면 해당 디스크는 건너뜀 (재검사 시 해당 `.badblocks` 파일 삭제 후 재실행)

```bash
sudo ./scripts/disk-check-badblocks.sh [/path/to/output]
```

소요 시간: 디스크 용량과 순차 읽기 속도에 따라 다름. 예: 4TB 150MB/s → 약 7~8시간, **14TB/8TB는 수십 시간** 걸릴 수 있음.

### 2.4 대용량 디스크(sde 14TB, sdf 8TB) 진행률 확인

검사가 오래 걸리므로 진행률을 확인하려면 다음을 사용합니다.

**방법 1 — 진행률 스크립트 (권장)**  
로그에서 퍼센트/블록을 파싱해 한눈에 표시합니다.

```bash
./scripts/disk-check-progress.sh
# 1분마다 자동 갱신
watch -n 60 ./scripts/disk-check-progress.sh
```

출력 예: 디스크별 용량, 총 블록 수, 진행률(%), 로그 마지막 수정 시각, 실행 여부.

**방법 2 — 로그 실시간 보기**  
각 디스크 로그를 `tail -f`로 보면 `badblocks -s`가 찍는 진행 메시지를 실시간으로 볼 수 있습니다.

```bash
# sde (14TB) 진행 보기
tail -f ~/disk-check-results/logs/sde.log
# sdf (8TB) 진행 보기 (다른 터미널)
tail -f ~/disk-check-results/logs/sdf.log
```

**방법 3 — 프로세스 확인**  
badblocks 프로세스가 돌아가는지 확인:

```bash
ps aux | grep badblocks
```

---

## 2.5 badblocks가 찾은 배드블록이 “진짜”인지 확인하는 방법

4TB 디스크(sdg, sdh, sdi)에서 badblocks가 **하나씩** 보고했다면, 다음으로 구분할 수 있습니다.

### 가능한 경우

| 구분 | 설명 |
|------|------|
| **진짜 배드섹터** | 물리적 결함 또는 오래되어 불안정한 섹터. 재검사해도 같은 위치에서 실패. |
| **일시적 읽기 오류** | I/O 부하, 케이블/연결 불안정, 전원 떨림 등으로 그 순간만 읽기 실패. 재검사하면 안 나올 수 있음. |
| **펌웨어 재할당 직전** | 드라이브가 나중에 해당 섹터를 재할당(reallocate)할 수 있음. SMART의 Reallocated_Sector_Ct 증가와 맞을 수 있음. |

### 확인 절차 (권장)

1. **SMART 확인**  
   해당 디스크에서 재할당/대기/오프라인 섹터 수가 있는지 봅니다.
   ```bash
   sudo smartctl -a /dev/sdg   # sdg, sdh, sdi 각각
   ```
   - **Reallocated_Sector_Ct** > 0 → 과거에 배드로 판단된 섹터가 재할당됨(진짜에 가깝다).
   - **Current_Pending_Sector** > 0 → 읽기 실패 등으로 “의심” 중인 섹터가 있음.
   - **Offline_Uncorrectable** > 0 → 오프라인 테스트에서 복구 불가로 기록된 섹터.

2. **같은 디스크만 다시 검사 (재현 여부)**  
   한 디스크만 골라서, **같은 블록**에서 다시 실패하는지 보면 “진짜” 가능성이 높아집니다.
   ```bash
   # 예: sdg만 재검사 (기존 결과 백업 후)
   sudo mv ~/disk-check-results/badblocks/sdg.badblocks ~/disk-check-results/badblocks/sdg.badblocks.bak
   sudo badblocks -sv -o ~/disk-check-results/badblocks/sdg.badblocks /dev/sdg <총블록수>
   ```
   - 재검사에서 **같은 블록 번호**가 다시 나오면 → 그 위치는 신뢰하지 않고 파티션에서 피하는 것이 안전합니다.
   - 재검사에서 **안 나오면** → 일시적 오류였을 가능성이 큽니다. 그래도 SMART에 재할당/대기 섹터가 늘어나지 않았는지 한 번 더 확인하는 것이 좋습니다.

3. **요약**  
   - SMART에 재할당/대기/오프라인 섹터가 있고, badblocks로 **같은 블록이 반복**하면 → **진짜**로 보는 것이 맞고, 파티션에서 해당 구간을 빼는 것을 권장합니다.  
   - SMART는 정상인데 badblocks에서만 한두 개 나왔고, **재검사에서 안 나오면** → **일시적 오류**로 보는 것이 타당합니다.

---

## 3. 배드섹터가 있을 때 파티션 나누기

배드블록 목록(`*.badblocks`)은 **1024바이트 블록 번호**로 저장됩니다. 파티션을 만들 때 이 블록들을 **포함하지 않도록** 구간을 나누면 됩니다.

### 3.1 블록 번호 → 바이트/섹터

- 1 블록 = 1024 바이트 (badblocks 기본)
- 512바이트 섹터 기준: 블록 번호 `B` → 섹터 번호 ≈ `B*2` (시작), `B*2+1` (끝) 등으로 해당 구간 회피

파티션 레이아웃은 보통 **섹터(512바이트) 단위**로 잡으므로, 배드블록이 있는 구간을 “구간 [시작섹터, 끝섹터]”로 모은 뒤, 파티션 경계가 그 구간과 겹치지 않게 하면 됩니다.

### 3.2 예시: 배드블록 구간 회피

1. `sde.badblocks` 내용 예:
   ```
   12345678
   12345679
   12345680
   ```
2. 블록 12345678~12345680 → 대략 섹터 24691356~24691361 (각 블록이 2섹터)
3. 파티션을 만들 때:
   - 첫 파티션: 0 ~ (24691356 - 1)
   - 배드 구간 건너뜀: 24691356 ~ 24691361
   - 다음 파티션: 24691362 ~ ...

실제로는 **여러 배드블록이 흩어져 있으면** 구간을 여러 개 두거나, “배드가 있는 작은 구간은 사용하지 않고” 그 앞뒤로만 파티션을 잡는 방식으로 처리합니다.

### 3.3 fdisk/parted 사용 시

- **fdisk**: 섹터 단위로 시작/끝 지정 가능. 배드 구간(시작~끝 섹터)을 피해 시작/끝을 지정하면 됨.
- **parted**: `parted /dev/sde unit s print` 로 섹터 단위 확인 후, `mkpart` 로 시작/끝을 배드 구간과 겹치지 않게 지정.

자동화하려면:

1. `*.badblocks` 를 읽어서 1024바이트 블록 → 512바이트 섹터 구간으로 변환
2. 디스크 전체 섹터 범위에서 위 구간들을 “제외 구간”으로 두고
3. 나머지 연속 구간들로 파티션 후보(시작, 끝) 계산

이후 `parted`/`fdisk` 스크립트나 수동으로 해당 시작/끝으로 파티션 생성하면 됩니다.

### 3.4 요약

- 검사 결과: `~/disk-check-results/smart/`, `~/disk-check-results/badblocks/*.badblocks`
- 배드블록 = 1024바이트 블록 번호 → ×2 하면 대략 512바이트 섹터 시작점
- 파티션은 배드가 있는 섹터 구간을 포함하지 않도록 시작/끝을 잡아서 생성

---

## 4. 한 번에 실행 (권장 순서)

```bash
cd /home/user/machine_setting

# 1) SMART 스냅샷
sudo ./scripts/disk-check-smart.sh

# 2) (선택) SMART Long Test — 터미널을 닫아도 디스크에서 계속 실행됨
sudo ./scripts/disk-check-smart-long.sh

# 3) 배드섹터 검사 — 백그라운드로 5개 동시. nohup으로 실행되므로 세션 종료해도 계속됨.
sudo ./scripts/disk-check-badblocks.sh
# 진행 상황: tail -f ~/disk-check-results/logs/sde.log 등으로 확인
```

완료 후:

- SMART 재수집: `sudo ./scripts/disk-check-smart.sh`
- 배드블록 개수 확인: `wc -l ~/disk-check-results/badblocks/*.badblocks`

이 문서와 스크립트만 있으면, 상세 디스크 검사부터 “배드섹터 제외 파티션” 설계까지 일관되게 진행할 수 있습니다.
