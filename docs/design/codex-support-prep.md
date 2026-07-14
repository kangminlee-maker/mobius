# Codex 지원 설계 준비 — 핸드오프 (2026-07-12)

> **[해소됨 2026-07-12]** 사용자 승인(A안: 기존 개념 확장 + 프로바이더 어댑터, 처음부터
> 자동 fallback·3계정 이상·앱+CLI) 후 같은 날 구현 완료. 현재 상태·남은 게이트는
> 레포 `CLAUDE.md`의 "QA / 진행 상황" 참조. 아래 OPEN 항목 중 4(스왑 실험)와
> 3(로그인 플로우 자동화)만 미해소 — 4는 조용한 시점 게이트로, 3은 adopt 방식이
> MVP를 대체해 후속으로 남음. 이 문서는 당시 실측 기록으로 보존.

> 목적: 다음 세션(컨텍스트 클리어 후)에서 "Mobius가 Claude뿐 아니라 OpenAI Codex CLI 계정도
> 전환/자동 fallback 지원"하는 기능을 **설계**하기 위한 실측 근거·열린 질문 모음.
> **설계 단계만 진행 — 사용자 승인 전 구현 금지** (coding-staged-workflow 준수).

## 현재 상태 (한 줄)

Claude 3계정 마이그레이션·등록 완료, 레포 main 클린 — Codex 지원은 실측만 끝났고 설계 미착수.

## 고정 상태 (다음 세션에서 먼저 재검증)

- 레포: `<repo>`, branch `main`, HEAD `f8f4276` (origin/main 동일), working tree 클린 (이 문서 커밋 전 기준)
- 실행 환경: `/Applications/Mobius.app` 설치·실행 중, Claude 계정 3개 등록(primary 회사 + fallback gmail 2개, 전부 Max 20X), `mobius` CLI = `~/.local/bin/mobius` symlink
- Claude 설정: 기본 위치(`~/.claude*`) 단일 사용 (구 claude-1/2/3 CONFIG_DIR 체계는 폐기됨, 프로젝트 메모리 `mobius-migration-state` 참조)

## CONFIRMED — 실측 근거 (재검증 명령 포함)

| 사실 | 근거/재검증 |
|---|---|
| codex-cli **0.144.1** 설치됨 | `codex --version` |
| 인증은 **`~/.codex/auth.json` 단일 파일(0600)**: `auth_mode`, `tokens{id_token, access_token, refresh_token, account_id}`, `last_refresh`, `OPENAI_API_KEY`(null 가능) | `ls -la ~/.codex/auth.json` + 키 덤프(값 제외) |
| 계정 식별자는 **id_token JWT payload에 로컬 추출 가능**: `email`, `name`, `https://api.openai.com/auth.{chatgpt_plan_type, chatgpt_account_id, organizations…}` (실측: 회사 계정, plan=pro) | JWT 2번째 세그먼트 base64url 디코드 (서명 검증 불필요 — 표시용) |
| 세션 로그 `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`에 **rate_limits 이벤트가 in-band 포함**: `{"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.0,"window_minutes":300,"resets_at":1783760007}…}` — resets_at는 **epoch 초** | `grep -o '"rate_limits":{[^}]*}' <최근 rollout 파일>` |
| `codex login`(브라우저 OAuth)·`codex login status`·`codex logout` 존재 | `codex login --help`, `codex logout --help` |
| `CODEX_HOME`으로 설정 루트 오버라이드 가능 (config 레이어링 문구 실측) | `codex --help \| grep -i CODEX_HOME` |
| `~/.superset/bin/codex` 래퍼 존재 — 실 바이너리 exec (claude 래퍼와 동일 패턴, 무해) | `head ~/.superset/bin/codex` |

**Claude 대비 단순한 점**: Keychain 무관(파일 하나 스왑), 사용량이 세션 로그에 직접 포함
(별도 usage 엔드포인트 불필요 → 네트워크 0 원칙 자연 충족), 이메일도 토큰 파일 자체에서 추출.

## PROPOSED / OPEN — 설계 세션에서 결정할 것

1. **요구 범위**: 사용자가 Codex 계정을 몇 개 쓰는지, 자동 fallback까지 원하는지 vs 수동 전환만
   원하는지 미확인 (설계 첫 질문). 현재 auth.json은 회사 계정 1개만 로그인된 상태.
2. **개념 설계 (concept economy)**: `AccountProfile`에 `provider` 필드 추가(기존 개념 확장)
   vs Codex 전용 병렬 스토어(분리). 프로바이더별 차이가 lifecycle·failure mode 수준인지 검토.
   관련: `MobiusEnvironment` 경로 추가, `Switcher`/`ClaudeConfigIO`의 프로바이더 추상화
   (readLive/writeLive/identity 프로토콜), `RateLimitParser`·`SessionLogWatcher` 일반화,
   `AutoSwitchEngine`(순수 상태머신)의 프로바이더별 풀 분리.
3. **로그인 플로우**: `codex login`은 localhost 콜백 브라우저 OAuth — Claude처럼 BROWSER 후킹이
   되는지, ChatGPT 쪽 "계정 선택 강제" URL 패턴이 있는지 미실측. (Claude의 실패 기록 7·13·15·16
   교훈 적용: GUI 셸 PATH 문제, URL 별칭/리다이렉트 함정.)
4. **미검증 가정**: auth.json이 유일한 자격증명 저장소라는 가정(다른 캐시 파일
   `.codex-global-state.json` 등의 역할 미확인) — 전환 설계 전 스왑 실험으로 확증 필요.
   auth.json 스왑 시 실행 중 codex 세션의 거동(Claude는 무중단이었음)도 실측 필요.
5. **UI/CLI 표면**: 카드 프로바이더 구분(아이콘/그룹), 메뉴바 아이콘 상태(두 프로바이더 소진
   조합), `mobius` CLI 명령 체계(`--provider` vs 닉네임 네임스페이스), Desktop 동시 전환의
   Codex 대응물(ChatGPT 데스크톱 앱)은 범위 제외 권장.
6. **파일 스왑 원자성**: `~/.codex`도 "바쁜 파일" 함정(실패 기록 9) 해당 여부 — auth.json은
   `last_refresh` 갱신이 있어 mtime 신호 부적합할 수 있음. 값 이중 읽기 패턴 재사용 검토.

## 다음 세션 진행 순서

1. 고정 상태 재검증: `pwd; git -C <repo> log --oneline -1; git status --short`
2. 레포 `CLAUDE.md` → 이 문서 → `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/guides/coding-staged-workflow.md` 순서로 읽기
3. OPEN 1(요구 범위)을 사용자에게 결과 언어로 질문 → 고수준 설계안 2~3개 비교(개념 영향·시간·리스크·done when) → 승인 후 구현
