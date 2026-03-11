# Issues Found During Preflight Implementation

발견일: 2026-03-11
컨텍스트: preflight.sh 구현 및 setup.sh 통합 테스트 중 발견된 이슈들

---

## Issue 1: SDKMAN `set -u` 호환성 문제 (수정 완료)

**파일**: `scripts/install-java.sh`
**증상**: SDKMAN의 `sdkman-init.sh`를 source할 때 `SDKMAN_CANDIDATES_API: unbound variable` 에러 발생
**원인**: `install-java.sh`가 `set -euo pipefail`로 실행되는데, SDKMAN 내부 스크립트가 초기화되지 않은 변수를 참조함
**영향**: Java 설치 실패 → 체크포인트 롤백 → SDKMAN 디렉토리 전체 삭제
**수정**: SDKMAN 관련 source/명령 전후로 `set +u` / `set -u` 추가

```bash
# Before (broken)
[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && source "$SDKMAN_DIR/bin/sdkman-init.sh"

# After (fixed)
set +u
[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && source "$SDKMAN_DIR/bin/sdkman-init.sh"
set -u
```

**교훈**: 외부 스크립트를 source할 때는 항상 strict mode 호환성을 고려해야 함. NVM도 같은 패턴이 필요할 수 있음 (현재는 lazy loading으로 회피됨).

---

## Issue 2: 체크포인트 롤백이 과도하게 공격적

**파일**: `scripts/lib-checkpoint.sh` (rollback 로직)
**증상**: Java 설치 실패 시 SDKMAN 디렉토리 전체(`~/.sdkman`)를 삭제함
**원인**: 체크포인트 trap이 stage 실패 시 해당 stage의 모든 산출물을 제거하도록 설계됨
**영향**: SDKMAN이 성공적으로 설치된 후 Java 버전 선택에서만 실패한 경우에도 SDKMAN 자체가 삭제됨
**개선 제안**:
- 롤백을 계층적으로 구성: SDKMAN 설치 성공 → Java 설치 실패 시, Java만 제거하고 SDKMAN은 유지
- 또는 롤백 범위를 사용자에게 확인: "SDKMAN is installed but Java failed. Remove SDKMAN too? [y/N]"
**상태**: 미수정 — 추후 lib-checkpoint.sh 개선 시 반영 필요

---

## Issue 3: 체크포인트 상태 파일 위치 혼란

**파일**: `scripts/lib-checkpoint.sh`, `.gitignore`
**증상**: 체크포인트 상태가 `~/.machine_setting/install.state`에 저장되지만, 코드에서는 `env/.install_state` 경로도 참조 가능
**원인**: `CHECKPOINT_STATE` 변수의 기본값이 `~/.machine_setting/install.state`이지만, env 디렉토리에도 state 관련 파일이 있어 혼란
**영향**: `rm -f env/.install_state`로 초기화하려 해도 실제 state는 `~/.machine_setting/install.state`에 있어 초기화 안 됨
**개선 제안**:
- 상태 파일 위치를 하나로 통일 (README 또는 코드 주석에 명시)
- `setup.sh --reset`이 유일한 초기화 경로임을 명확히 문서화
**상태**: 미수정

---

## Issue 4: preflight.sh GPU 패키지 sed 파싱 오류 (수정 완료)

**파일**: `scripts/preflight.sh`
**증상**: `sed: unknown option to 's'` 에러
**원인**: GPU requirements 파일 파싱 시 sed 표현식에서 세미콜론 순서 오류

```bash
# Before (broken) — 세미콜론이 s 명령 안에 들어감
sed 's/[>=<!\[].*//; s/[[:space:]]*$/; s/\+.*//'

# After (fixed) — 각 s 명령을 올바르게 분리
sed 's/[>=<!\[].*//; s/\+.*//; s/[[:space:]]*$//'
```

**교훈**: 복합 sed 표현식에서 세미콜론 분리자와 s 명령의 구분자를 혼동하지 않도록 주의

---

## Issue 5: 인터랙티브 입력이 여러 단계에 걸쳐 소비됨

**파일**: `setup.sh`
**증상**: pipe로 입력(`echo "Y" | setup.sh`)할 때, preflight의 "Proceed?" 프롬프트가 stdin을 소비한 후 checkpoint resume 메뉴에 입력이 남지 않음
**원인**: preflight.sh와 checkpoint resume 메뉴가 모두 stdin에서 read함
**영향**: 비대화형 환경(CI/CD, pipe)에서 예측하기 어려운 동작
**개선 제안**:
- `--preflight` 모드에서는 resume 메뉴를 건너뛰도록 로직 추가
- 또는 preflight plan이 존재하면 resume 메뉴 대신 plan을 우선 적용
- `--yes` / `--auto-approve` 플래그 추가로 모든 프롬프트를 자동 수락
**상태**: 미수정 — 우선순위 중간

---

## Issue 6: setup.sh --preflight에서 profile 미반영 가능성

**파일**: `setup.sh`
**증상**: `--preflight` 단독 사용 시 profile이 CLI에서 지정되지 않으면, preflight가 auto-detect한 profile을 사용하지만, setup.sh의 기존 profile 로딩 로직과 이중으로 동작할 수 있음
**원인**: preflight.sh가 자체적으로 profile을 감지/로드하고, setup.sh도 hardware detection 후 profile을 로드함
**영향**: preflight에서 보여준 profile과 실제 setup에서 적용되는 profile이 다를 수 있음 (plan 파일에 PREFLIGHT_PROFILE은 있지만 setup.sh가 이를 사용하지 않음)
**개선 제안**:
- setup.sh에서 `USE_PLAN=true`일 때 `PREFLIGHT_PROFILE` 값을 `PROFILE` 변수에 반영
- 또는 plan 파일에서 profile 정보도 함께 적용
**상태**: 미수정 — 우선순위 낮음 (대부분 auto-detect 결과가 동일)

---

## Issue 7: preflight.sh에서도 SDKMAN set -u 문제 (수정 완료)

**파일**: `scripts/preflight.sh`
**증상**: SDKMAN 설치 후 preflight --check-only 실행 시 출력 없이 exit 1
**원인**: Issue 1과 동일 — `check_java()`에서 `sdkman-init.sh`를 source할 때 unbound variable
**수정**: Issue 1과 동일한 `set +u` / `set -u` 패턴 적용

**교훈**: SDKMAN을 source하는 모든 위치에 일관되게 `set +u` 가드를 적용해야 함. 검색 필요:
```bash
grep -r "sdkman-init" scripts/
```

---

## Issue 8: doctor.sh에서도 SDKMAN set -u 문제 (수정 완료)

**파일**: `scripts/doctor.sh`
**증상**: doctor 실행 시 Java 체크에서 동일한 unbound variable 에러
**수정**: Issue 1, 7과 동일한 패턴 적용

**결론**: SDKMAN `set -u` 문제는 프로젝트 전체에서 3곳에서 발생함:
- `scripts/install-java.sh` (2곳)
- `scripts/preflight.sh` (1곳)
- `scripts/doctor.sh` (1곳)

향후 SDKMAN을 source하는 코드를 추가할 때는 반드시 `set +u` 가드를 포함할 것.

---

## 우선순위 정리

| # | 이슈 | 심각도 | 상태 | 파일 |
|---|---|---|---|---|
| 1 | SDKMAN set -u 호환 | 높음 | 수정 완료 | install-java.sh |
| 2 | 롤백 과도 공격적 | 중간 | 미수정 | lib-checkpoint.sh |
| 3 | 상태 파일 위치 혼란 | 낮음 | 미수정 | lib-checkpoint.sh |
| 4 | sed 파싱 오류 | 높음 | 수정 완료 | preflight.sh |
| 5 | 인터랙티브 stdin 충돌 | 중간 | 미수정 | setup.sh |
| 6 | profile 이중 로딩 | 낮음 | 미수정 | setup.sh |
| 7 | preflight SDKMAN set -u | 높음 | 수정 완료 | preflight.sh |
| 8 | doctor.sh SDKMAN set -u | 높음 | 수정 완료 | doctor.sh |
