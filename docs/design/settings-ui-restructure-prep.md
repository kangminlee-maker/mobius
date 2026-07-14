# 설정 UI 재구성 — 핸드오프 (2026-07-12)

> **[해소됨 2026-07-12]** R1~R6 구현 완료 — "남은 확인" 4·6은 문서의 기본값(양쪽 모두 /
> '자동 전환')으로 진행. 테스트 103개 green. 현재 상태는 레포 CLAUDE.md "QA / 진행 상황"
> 참조. 남은 것: 설정 렌더·히트 타깃·계정 추가 진입점 수동 QA (사용자 실기기 확인).

> 목적: 다음 세션(컨텍스트 클리어 후)에서 설정 화면·메뉴바 footer 재구성과
> **자동 fallback의 앱별 분리**를 이어가기 위한 요구사항·코드 지도·열린 질문.
> 사용자 요구사항 원문 기반 — 구현 전 아래 "열린 질문"을 사용자에게 확인할 것.

## 고정 상태 (다음 세션에서 먼저 재검증)

- 레포: `<repo>`, branch `main`, HEAD `7ba6e68`
  **+ 미커밋 작업트리** (Codex 지원 전체 + 설정 '설치 현황' 1차 개편, 약 25파일 ±850/−280).
  `git status --short`로 확인. 커밋 여부는 사용자에게 확인 (권장: 이 상태로 1커밋 후 진행).
- 배포: `/Applications/Mobius.app`은 이 작업트리 기준 최신 빌드로 교체·실행 중.
  재배포 명령: `MOBIUS_SIGN_IDENTITY="Developer ID Application: Fastcampus Language co., ltd. (M3LMVL5V4C)" Scripts/make-app.sh`
  → 앱 종료 → `rm -rf /Applications/Mobius.app && ditto dist/Mobius.app /Applications/Mobius.app` → open.
  (서명 정체성을 반드시 이 값으로 — 바꾸면 Keychain '항상 허용' 리셋.)
- 테스트: `swift test` 100개 green (2026-07-12 기준).
- 진행 문맥: 레포 CLAUDE.md "QA / 진행 상황" + `docs/design/codex-support-prep.md`(해소됨) 참조.

## 요구사항 (2026-07-12 사용자 지시)

R1. **'설치 현황' 섹션을 설정 Form 최하단으로** 이동.

R2. [확정] **mobius CLI 항목**: **'일반' 섹션 안의 행**으로 배치, 라벨은 'mobius CLI'
    ('mobius 명령어' 아님), **설치됨/미설치를 적절한 색의 pill 뱃지**로 표시
    (스타일 참고: AccountCardView의 PRIMARY 캡슐 — 초록=설치됨, 주황/회색=미설치).
    [설치] / [재설치][삭제] 버튼 동작은 현행 유지
    (SettingsView.applyMobius — /usr/local은 관리자 권한, ~/.local은 직접).

R3. [확정] **자동 전환(구 '자동 fallback') 토글을 '일반'에서 전부 제거**하고 재배치:
    - '설치 현황' 이하 앱별 on/off는 **Claude Code CLI, Codex CLI 두 개만**:
      각각 claude/codex 풀의 자동 전환 (★ 모델 변경: autoSwitchEnabled 전역 →
      프로바이더별. M1 때 "후속 후보"로 기록해 둔 항목. 상세는 아래 "개념 영향").
    - **Claude Desktop 관련 토글 2개(동시 전환/자동 전환 시에도)는 신설 'Experimental'
      섹션으로 이동** — experimental 성격을 섹션으로 드러내고 토글은 유지.
    - **ChatGPT는 on/off 없음** — 설치 현황의 상태 행만 표시 (동시 전환 미구현).

R4. **'설치 현황' 이하에 CLI별 등록 계정 현황 + 계정 추가 버튼**:
    - Claude Code CLI: 등록 계정 목록(요약) + [계정 추가] (기존 LoginFlow 재사용 — state.addAccount())
    - Codex CLI: 등록 계정 목록 + 추가 안내 (기존 AccountListView footer의 Codex popover
      내용 이전: `codex logout && codex login` → 자동 등록)
    - Desktop/ChatGPT 행은 계정 개념 없음 (Desktop 스냅샷은 claude 계정에 종속)

R5. **메뉴바 팝오버**: footer '계정 추가' 버튼 **삭제** (설정으로 이동, R4),
    설정(⚙)·전원 버튼을 **더 누르기 쉽게** (히트 타깃 확대 — 현재 11pt 아이콘 plain 버튼).
    [확정] 헤더의 전역 '자동 Fallback' 토글 + 안내 popover도 **제거** — 설정으로 일원화
    (안내 문구는 설정의 토글 캡션으로 이전).

R6. [신규] **용어 변경**: 사용자 노출 표기에서 '자동 fallback' → **'자동 전환'**으로 통일
    (제품이 이미 알림·CLI에서 쓰는 기존 어휘 재사용 — concept economy). 토글 캡션:
    "한도가 차면 다음 계정으로 자동으로 이어집니다". README ko/en의 'auto fallback'
    표기도 정리 (en: "auto-switch"). 계정 역할명(primary/fallback1…)은 이번 범위 아님
    — 선택적 후속.

## 개념 영향 (concept economy) — R3의 모델 변경

- `AccountsFile.autoSwitchEnabled: Bool`(전역) → 프로바이더별로. 기존 패턴 재사용:
  `autoSwitchByProvider: [Provider: Bool]` + 레거시 디코드(구 키 → 양쪽 풀에 동일 적용)
  + encode 시 레거시 키 병행 기록(다운그레이드 완충 — activeByProvider와 동일 수법).
  기본값 켬 유지.
- `AutoSwitchEngine.onRateLimitHit/onTick`: `file.autoSwitchEnabled` → 풀별 플래그로.
  (엔진은 이미 provider를 가짐 — `file.isAutoSwitchEnabled(provider)` 형태 제안.)
- `AccountStore.setAutoSwitch(_:)` → `setAutoSwitch(_:provider:)` (기본값 금지 —
  풀 변경 연산은 명시, setAutoSwitchedFromPrimary와 동일 원칙).
- CLI `mobius auto on|off` → `--provider claude|codex` 옵션 추가, 미지정 시 양쪽 모두
  (남은 확인 4의 기본값).
- AccountListView 헤더의 전역 '자동 Fallback' 토글 + fallbackInfoButton: 제거 확정 —
  안내 문구는 설정 토글 캡션으로 이전 (결정 5).
- Desktop 관련: `desktopSyncEnabled`/`desktopAutoSwitchEnabled` **모델 변경 없음** —
  두 토글을 신설 'Experimental' 섹션으로 옮기기만 (결정 2). 라벨의 '(experimental)'
  접미는 섹션명이 대신하므로 제거.
- 용어(R6): 사용자 노출 문자열의 '자동 Fallback/fallback' → '자동 전환'. L10n 키 교체
  (죽은 키 제거 포함), README ko/en 표기 정리. 알림·CLI는 이미 '자동 전환' 사용 중.

## 결정 사항 (2026-07-12 사용자 확인)

1. mobius CLI = '일반' 섹션 안의 행 ✓ (R2에 반영)
2. Desktop 토글 2개 = 신설 'Experimental' 섹션으로 ✓ (R3에 반영)
3. ChatGPT = on/off 아예 미표시, 상태 행만 ✓ (R3에 반영)
5. 메뉴바 헤더 전역 토글 제거, 설정 일원화 ✓ (R5에 반영)

## 남은 확인 (기본값으로 진행 가능)

4. **CLI `mobius auto on|off`의 프로바이더 미지정 시**: 기본값 = **양쪽 모두 적용**
   (기존 사용감 유지; 한쪽만은 `--provider claude|codex`). 사용자에게 설명 완료,
   이의 없으면 이 기본값으로 구현.
6. **용어**: 기본값 = **'자동 전환'** (기존 제품 어휘 재사용). 대안 '자동 이어쓰기'
   제시함 — 사용자가 달리 답하지 않으면 '자동 전환'으로.

## 코드 지도

- `Sources/MobiusApp/Views/SettingsView.swift` — 설정 Form 전체. 현재 순서:
  [온보딩] → 설치 현황(claudeCLIRow + toolRow×3) → 일반(언어/자동시작/fallback 토글 3개/게이지)
  → mobius CLI. `toolRow(_:path:version:)`, `applyMobius(paths:action:)` 재사용.
- `Sources/MobiusApp/ToolInventory.swift` — CLI/앱 감지 (locateCLI, appBundle(bundleID:),
  mobiusInstallations). ChatGPT는 번들 ID `com.openai.codex`(동명 Classic과 구분).
- `Sources/MobiusApp/Views/AccountListView.swift` — 메뉴바 팝오버. footer(계정 추가 Menu +
  ⚙/전원), 헤더의 전역 자동 Fallback 토글, Codex 추가 안내 popover(→ 설정으로 이전).
- `Sources/MobiusCore/Models.swift` — AccountsFile (autoSwitchEnabled가 여기).
  레거시 디코드/인코드 패턴은 activeByProvider 참조.
- `Sources/MobiusCore/AutoSwitchEngine.swift`, `AccountStore.swift(setAutoSwitch)`,
  `Sources/mobius/Mobius.swift(Auto 커맨드)`, `AppState.swift(setAutoSwitch, engines)`.
- pill 뱃지 스타일 참고: `AccountCardView.swift`의 PRIMARY 캡슐(폰트 8bold, Capsule 배경).
- L10n: 새 문자열은 `Sources/MobiusApp/{en,ja}.lproj/Localizable.strings`에 추가
  (키=한국어 원문, plutil -lint로 검증).

## 검증 계획

- 유닛: AccountsFile autoSwitch 레거시 디코드/roundtrip, 엔진 풀별 게이팅
  (한 풀만 꺼짐 → 그 풀만 notifyExhaustedOnly), 기존 100개 green 유지.
- 수동: 설정 렌더(섹션 순서/pill 색/토글 동작), 메뉴바 footer 히트 타깃,
  계정 추가 진입점이 설정에서 동작(LoginFlow), 재배포 후 실기기 확인.
- 검증 후 CLAUDE.md 구조·README(토글 위치 언급부) 갱신.

## 미해결 스레드 (이 작업과 별개로 진행 중)

- **회사 codex 계정 재로그인 대기**: 스냅샷 토큰 revoked(클로버+회전, CLAUDE.md 핵심 사실
  참조). 사용자가 `codex logout && codex login`(회사 계정) 후 → 즉시 프로브 턴으로 게이지
  생성·스냅샷 신선도 확보 필요. 재로그인 전까지 codex 활성은 account-A(정상 동작).
- 실소진 이벤트(rate_limit_reached_type) fixture 미확보 — 첫 실소진 때 수집.
- 작업트리 미커밋 — 커밋 메시지 제안: "feat: Codex 계정 지원 (프로바이더별 풀) + 설정 설치 현황".

## 다음 세션 진행 순서

1. 고정 상태 재검증: `pwd; git log --oneline -1; git status --short | head`, 테스트 green 확인
2. 레포 CLAUDE.md → 이 문서 → coding-staged-workflow 가이드 순서로 읽기
3. "남은 확인" 4·6은 기본값으로 진행 가능(사용자가 이 문서 작성 턴에서 설명을 들었고
   기본값 안내됨) → R3 모델 변경(autoSwitch 풀별)부터 구현 → UI 재배치 → 검증 → 재배포
