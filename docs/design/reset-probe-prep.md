# 한도 리셋 프로브 — 설계 준비 (2026-07-12)

> 목적: 소진됐던 계정의 한도 창이 리셋된 뒤 **첫 호출 전까지 다음 리셋 시점이 미정**인
> 문제를, 리셋 도래 시 **최소 호출 1회로 창을 즉시 시작**해 해소한다.
> 다음 리셋 시점 확정 + 게이지 신선화 + "초기화됨/다음 초기화 시각" 알림.
> Experimental 토글(기본 끔).
> 상태: **[구현됨 2026-07-13]** 게이트 G1·G2 실측 통과(2026-07-12, 사용자 승인 하에
> 실호출) 후 구현 완료 — ResetProber(판단부)/ResetProbe(실행기)/AppState 배선/토글.
> 유닛 11개 추가(총 114 green). 미검증 잔여: 실제 리셋 이벤트로 tick 전체 경로 라이브 관측.
> 결정 확정: 토글은 전역 1개(사용자), 시스템 프롬프트 불필요(실측으로 G3 소멸).

## 전제 실측 (2026-07-12, 이 문서의 근거)

1. **Claude 5h 창은 첫 호출 전까지 미정** — 유휴 계정(account-A)의 usage 응답:
   `five_hour: {utilization: 0.0, resets_at: null}`. 전제 성립.
2. **주간 창은 유휴여도 확정돼 있음** — 같은 계정에서 `seven_day.resets_at` 존재.
   주간 창은 7일 완전 유휴가 아닌 한 항상 진행 중 → **프로브의 주 대상은 5h 창**
   (주간은 프로브 부산물로 함께 확정/갱신됨).
3. **usage 조회(GET)는 창을 시작시키지 않는다** — 앱이 게이지로 반복 조회해 왔는데도
   null 유지. 확정에는 **실제 모델 호출**이 필요하다.
4. **Codex도 동일 의미론** — 세션 로그 6/30~7/12(token_count 13,188행) 분석:
   새 5h 창은 항상 `resets_at = 첫 관측 시각 + 5.00h`, used 0%에서 시작.
   단 Codex는 in-band뿐이라 **유휴 중엔 신호 자체가 없다**(호출 없으면 데이터 없음).
5. `codex exec` 존재(0.144.1 실측): 비대화형 1턴, `-m <model>`, `-c key=value` 오버라이드.
6. 부가 발견: usage 응답에 `limits[]`(kind: session/weekly_all/**weekly_scoped** —
   모델 스코프 주간 한도, is_active/severity 포함)와 spend/extra_usage 블록.
   weekly_scoped(예: Fable 스코프 100% critical)는 현 게이지에 미노출 — 별건 후속 후보.

## 합리성 판정

- **가치**: ① 다음 리셋 시점 확정 → 풀 회전(어느 계정이 언제 여유가 생기나) 예측 가능,
  ② 창 조기 시작 = 다음 리셋 조기 도래(가용성 ↑), ③ 리셋 알림(사용자 인지).
- **비용**: 리셋당 최소 호출 1회(계정당 하루 최대 ~5회), 5h 창 소비 ~0–1%.
- **원칙 충돌**: 기존 "네트워크 최소/자동 트래픽 없음" 원칙의 예외 →
  **opt-in Experimental 기본 끔**(default-off 원칙)으로 상쇄. 켠 사용자만 감수.

## 프로바이더 적용성

| | Claude | Codex |
|---|---|---|
| 창 의미론(첫 호출 시작) | ✅ 실측 | ✅ 실측 |
| 리셋 시점 확인 수단 | usage 엔드포인트 (GET, 프로브 후 재조회) | 프로브 턴 자신의 rate_limits (in-band) |
| 프로브 수단 | 저장 토큰으로 직접 API 모델 호출 | `codex exec` 최소 1턴 |
| 비활성 계정 프로브 | ✅ 전환 없이 가능 (계정별 토큰 보유) | ❌ v1 제외 — 스냅샷으로 턴 실행 시 토큰 회전→실효/클로버 위험(실측된 실패 클래스) |
| 제약 | access token 만료 시 스킵 (**리프레시 금지** — refresh token 회전이 스냅샷·Keychain 사본을 실효시키는 실패 클래스) | 활성 계정만. 자동 복귀 직후의 primary가 주 사용 사례라 커버됨 |
| 게이트 실측 | ✅ G1 통과 (아래) | ✅ G2 통과 (아래) |

## 설계 (개념 영향)

- `AccountsFile += resetProbeEnabled: Bool` (기본 false). **v1은 전역 토글 1개** —
  같은 개념 하나이고 experimental이므로 프로바이더별 분리는 수요 확인 후 (결정 1).
- 신규 `ResetProber`(MobiusCore): 순수 판단부 + 주입된 프로브 실행기(테스트 가능).
  - **트리거**: tick에서 `rateLimit != nil && now ≥ resetsAt`인 계정 (소진→리셋 도래).
    기존 개념(rateLimit/resetsAt) 재사용 — 새 감지 경로 없음.
  - Claude 실행기: expiresAt 유효성 검사 → 최소 모델 호출 1회(G1 확정 파라미터) →
    usage 재조회(반영 지연 있음 — +15s/+30s/+60s 폴링) → `usage[id]` 갱신.
  - Codex 실행기: 대상이 활성 계정일 때만 `codex exec --json` 1턴 →
    stdout의 thread_id로 rollout 파일 특정 → **CodexRateLimitParser로 직접 파싱**
    (워처는 tailOnly라 일회성 턴을 놓칠 수 있음 — G2 참조) → `usage[id]` 갱신.
- **성공 시**: `profile.rateLimit` 해제(확정된 새 창이 진실) + 알림
  "%@ 한도 초기화 — 다음 초기화 HH:mm". 창당 1회 (디듀프 키 = accountID + resetsAt).
- **실패 시**: 백오프 재시도 총 3회(서킷브레이커 — 리트라이 스톰 금지 원칙),
  최종 실패 시 이 창 포기(알림 문구는 결정 3).
- **가드**: 로그인 플로우/Desktop 캡처/전환 진행 중 프로브 금지(기존 tick 가드 재사용),
  동시 프로브 1건, 앱 재시작 시 rateLimit이 남아 있으면 트리거 재평가(자연 복원).

## UI

Experimental 섹션(최하단)에 토글 추가:
- 라벨(안): "한도 초기화 확정 (최소 호출)"
- 캡션(안): "초기화된 계정에 최소한의 호출 1회를 보내 다음 초기화 시점을 확정하고
  알림으로 알려줍니다. 호출은 소량의 사용량을 소비합니다."

## 게이트 실측 결과 (2026-07-12, 사용자 승인 하에 실호출 — 구현 시 재검증 불필요)

### G1 (Claude) — 통과. account-A(5h 유휴, resets_at null 전 검사 = 음성 대조)

- **시스템 프롬프트 불필요**: `/v1/messages` + `Authorization: Bearer` +
  `anthropic-beta: oauth-2025-04-20` + `anthropic-version: 2023-06-01`로
  시스템 프롬프트 없이 200. ToS 그레이존(Claude Code 모사) 우려 소멸.
- **모델 카탈로그 주의**: `claude-3-5-haiku-20241022`는 404(OAuth 카탈로그에 없음) —
  `claude-haiku-4-5-20251001` 사용. 404 응답은 창을 시작시키지 않음(실측).
- **확정 파라미터**: model=claude-haiku-4-5-20251001, max_tokens=1, messages=[user:"ok"]
  → 입력 8토큰/출력 1토큰. utilization 0.0% 유지(프로브 비용은 % 단위에서 비가시).
- **창 확정 확인**: 14:49:50 호출 → resets_at null → `19:39:59Z`.
  ★ **리셋 시각은 10분 그리드로 스냅**(관측치 전부 :10 배수) — 호출+5h에서 내림.
- ★ **반영 지연**: 호출 +3초엔 여전히 null, +30초엔 확정 — 프로브 후 usage 재조회는
  **지연 재시도 필요(+15s/+30s/+60s 폴링)**.

### G2 (Codex) — 통과. 활성 계정 account-A@example.com에서 `codex exec` 최소 턴

- 커맨드: `codex exec --json --skip-git-repo-check -s read-only
  -c model_reasoning_effort="low" "Reply with exactly: ok"` — 정상 완료.
  비용: 출력 5토큰, 입력 ~18.8k(캐시 ~10k) = 일반적인 1턴. used_percent 변화 없음(17%→17%).
- 턴 직후 새 rollout 파일에 `rate_limits` 기록 확인(5h 17%, resets 17:58:57,
  window_minutes=300) — 새 파일이므로 CodexStatusRouter가 현재 활성에 귀속(설계 일치).
- ★ **워처로는 못 받는다**: SessionLogWatcher tailOnly 정책이 "처음 본 파일은 끝까지
  스킵"이라, 일회성 프로브 턴의 유일한 token_count는 타이밍에 따라 유실된다.
  → **프로버가 rollout 파일을 직접 파싱**해야 함.
- ★ **파일 특정 방법 확정**: `--json` stdout의 `thread.started.thread_id`가 rollout
  파일명 suffix와 1:1 매칭(`rollout-<ts>-<thread_id>.jsonl`, 실측 확인).
  stdout JSON에는 rate_limits가 **없다**(usage 토큰 수만) — 파일 파싱이 유일 경로.
  기존 `CodexRateLimitParser` 재사용. 픽스처: `--json` stdout 4이벤트
  (thread.started/turn.started/item.completed/turn.completed) 실측 확보.

## 결정 사항 (확정)

1. 토글 범위: **전역 1개** (사용자 확정, 2026-07-12).
2. 시스템 프롬프트: 불필요(실측) — 결정 소멸.
3. 프로브 최종 실패 시 알림: "확정 실패 — 다음 사용 시 창이 시작됩니다" 1회(기본값 제안,
   이견 없으면 이대로).
4. v1 트리거는 5h 창(소진 기록 기반)만 — 7일 완전 유휴 계정의 주간 창 프로브는 제외(희귀).

## 검증 계획

- 유닛: ResetProber 트리거/창당 1회 디듀프/백오프·서킷브레이커(시계 주입),
  rateLimit 해제 경로, 만료 토큰 스킵.
- 통합: G1/G2 실측을 E2E로 재사용(전/후 usage·로그 비교 = 음성 대조 포함 —
  프로브 전 null 확인 후 프로브 후 시각 확인).
- 실패 주입: 401 스킵, 네트워크 실패 백오프, 활성 아닌 codex 계정 스킵.

## 구현 순서 (게이트 통과 후)

1. 모델(resetProbeEnabled) + ResetProber 판단부 + 유닛테스트
2. Claude 실행기(G1 확정 파라미터) → 알림 배선
3. Codex 실행기(G2 확정 파라미터, 활성 한정)
4. 설정 UI 토글 + L10n → 검증 → CLAUDE.md/README 갱신 → 재배포
