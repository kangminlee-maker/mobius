# 여유 전환 (drain-before-switch) — 설계 준비 (2026-07-13)

> 목적: 활성 계정이 **100% 소진되는 순간 턴 도중 crash**하는 대신, **여유가 있을 때(마진)
> 세션들에게 새 작업을 시작하지 말라고 알리고, 모든 세션이 현재 작업을 마쳐 조용해지면
> (quiesce) 그 창에서 전환**한다. 벽에 부딪혀 멈추는 대신 턴 경계에서 깔끔히 멈추고 넘어간다.
> 상태: **[설계 탐색 — 방향 미확정]** 아래 능력 스파이크(3개 불확실성) 확정 전에는 구현 착수 금지.
> 사용자 요청(2026-07-13): "여유 있을 때 모든 세션에 작업 중단 명령 → 다 멈추면 자동 전환.
> subagent dispatch·subprocess 등 변수 대처 로직을 먼저 세워야."

## 1. 전제 실측 (2026-07-13, 이 문서의 근거)

이 설계의 실현 가능성을 좌우하는 능력 확인. **추측 아님 — 설치 아티팩트 실측.**

1. **두 CLI 모두 hook 시스템 보유** (실측):
   - **Claude Code**: `PreToolUse`(작업 **차단 가능** — deny/exit2), `PostToolUse`, `Stop`,
     `SubagentStop`, `SessionStart`, `UserPromptSubmit`, `Notification` 등.
   - **Codex 0.144.1**: `~/.codex/hooks.json`에 `SessionStart`/`UserPromptSubmit`/`Stop`
     (config.toml엔 `post_tool_use`도). `--dangerously-bypass-hook-trust` 플래그 존재 =
     hook은 신뢰 등록된 실행 기능. 이미 사용자 환경은 `~/.superset/hooks/notify.sh`가
     두 CLI hook을 크로스로 사용 중 — **크로스-CLI hook 배선 선례 있음**.
2. **★ 실행 중 세션은 자격증명을 메모리에 들고 있다** (기존 실측, CLAUDE.md QA):
   전환(파일/Keychain 스왑)은 **다음 세션 시작부터** 적용되고, **돌던 세션엔 반영 안 됨**.
   → 외부 전환은 running 세션을 새 계정으로 *이어달리게 만들 수 없다*. 세션 재시작 필요.
3. **Codex `notify`**: config.toml `notify=[프로그램, "turn-ended"]` — 턴 종료 시 외부
   프로그램 호출하는 별도 신호 채널도 존재(hook과 병행 가능).

## 2. 정직한 경계 (기능의 실제 이득 범위)

전제 2 때문에 이 기능이 줄 수 있는 것과 없는 것을 명확히 한다:

- ✅ **줄 수 있는 것**: "100%에서 턴 도중 crash" → "마진 구간에서 **턴 경계에 깔끔히 멈춤**
  + 전환 + '새 계정으로 전환됨, 세션 재시작 시 이어짐' 알림". 사용자 요청과 정확히 일치.
- ❌ **줄 수 없는 것(외부 전환의 한계)**: running 대화형 세션의 *무중단 자동 이어달리기*.
  drain으로 멈춘 세션은 여전히 옛 계정 cred를 메모리에 들고 있어, 재개하면 옛(소진) 계정으로
  간다 → **재시작해야 새 계정 적용**. 뫼비우스는 사용자의 대화형 터미널 REPL을 강제 재시작 못 함.
  - *무중단 이어달리기*는 **뫼비우스가 직접 띄운 세션**(예: `codex exec` 배치, 런처 래핑)에만
    가능 → 옵션 C.

## 3. 아키텍처 — drain 상태머신 (풀당 독립)

```
[활성계정 usage가 drainMargin 도달 (예: 90%, 100% 전)]
   │
   ├─ 뫼비우스: 해당 풀 "drain 플래그" 세팅 (파일: drain/<provider>.flag)
   │
   ├─ 각 세션 hook이 플래그 확인:
   │     · PreToolUse / UserPromptSubmit → 새 작업 차단(deny)
   │       = 새 턴·새 tool·새 subagent 시작 금지
   │     · 이미 in-flight인 tool/subagent/subprocess는 죽이지 않고 자연 종료 대기
   │
   ├─ 뫼비우스: 세션별 busy/idle 추적 (hook이 상태파일 기록)
   │     · SessionStart=등록, UserPromptSubmit=busy, PostToolUse=heartbeat,
   │       SubagentStop=서브에이전트 종료, Stop=idle
   │
   ├─ [풀의 모든 세션 idle + settle window] → quiesced 판정
   │
   ├─ 전환 실행 (기존 Switcher 경로)
   │
   └─ drain 플래그 해제 + 알림("→ <다음계정> 전환됨, 세션 재시작 시 이어짐")
```

### 3.1 subagent/subprocess 변수 대처 (사용자가 지목한 핵심)

| 변수 | 대처 | 근거 |
|---|---|---|
| **subagent dispatch** | `PreToolUse(Task)`로 신규 차단, `SubagentStop`으로 종료 관측 | claude hook 확실 |
| **subprocess (Bash 등)** | `PreToolUse(Bash)`로 신규 차단. 돌던 subprocess는 **안 죽이고** `PostToolUse` 올 때까지 busy 유지 → quiesce가 대기 | 죽이지 않음 = 데이터 안전 |
| **in-flight 1턴의 잔여 소비** | 신규만 막으므로 진행 중 턴이 마진을 더 갉음 → `drainMargin`을 **최악 1턴 소비량 이상**으로 (핵심 튜닝값·잔여 리스크) | 흡수 전략 |
| **세션이 어느 계정인지 hook이 모름** | **풀(프로바이더) 단위 일괄 drain** — Claude 풀 전환 시 Claude 세션 전부 잠깐 멈춤 | 계정 단위 식별 난이 |
| **hung tool / 장기 subprocess** | busy 유지가 안전측 오류(전환 지연)로 수렴. 상한 타임아웃 두면 강제 전환 옵션(위험) | 보수적 기본 |

## 4. 구현 전 확정할 불확실성 (능력 스파이크 — 값싼 실측)

설계가 이 3개에 의존. **확정 전 구현 금지.**

1. **Codex hook이 작업을 *차단*할 수 있나?** claude `PreToolUse` deny는 확실. codex
   `UserPromptSubmit`/`post_tool_use`가 **deny를 지원하는지 미확인**. 관측만 되고 차단이
   안 되면 codex는 옵션 A(기회적)만 가능.
2. **running 세션이 cred 파일 변경을 리로드하나?** 실측 기록은 "안 함(재시작 필요)"이나
   현재 버전·drain-resume 경로로 **재확인**. 리로드되면 *무중단 이어달리기*까지 열림(설계 확장).
3. **quiesce 신호 정확도** — hook 상태파일이 hung tool·장기 subprocess를 안전하게 busy로
   유지하는지, Stop이 실제 idle과 일치하는지.

## 5. 방식 옵션 (outcome 기준)

| | 무엇 | 이득 | 비용/리스크 |
|---|---|---|---|
| **A. 기회적 전환** | drain 명령 없이, 자연 idle 구간(로그/hook 관측)에서 마진 넘으면 전환 | 가장 단순·저위험, 차단 hook 불필요 | idle 틈 없으면 여전히 벽 |
| **B. 협조적 drain** (요청안) | hook으로 신규 작업 차단→quiesce→전환 | 안전 창을 능동 생성, 목표에 정확히 부합 | hook 설치 필요, codex 차단 미검증, in-flight 잔여 |
| **C. 뫼비우스 런처** | 뫼비우스가 띄운 세션을 PID 추적·재시작 | *진짜 무중단 이어달리기* | 사용자 직접 띄운 터미널 미적용, 빌드 최대 |

**추천 경로**: ①능력 스파이크(4장)로 3개 확정 → ②A를 저위험 1차 증분 → ③B를 opt-in 확장
(차단 가능 확인 시). A/B가 같은 busy/idle 추적을 공유 → 낭비 없음. 전부 **기본 꺼짐 opt-in**
([[reset-probe-prep]]과 동일 원칙: 네트워크·침습 기능은 실험실 opt-in).

## 6. 열린 질문 (사용자 결정 대기)

- 방향: 스파이크 먼저 / prep 확정 / A부터 최소 구현 / 재검토 중 무엇으로?
- drain 시 **풀 단위 일괄 멈춤**(모든 Claude 세션 잠깐 정지)이 수용 가능한가?
- hook을 뫼비우스가 사용자 설정에 **설치/확장**해도 되는가(기존 superset hook과 공존)?
- 대화형 세션은 "재시작하면 이어짐" 알림까지가 현실적 목표 — 이 경계를 수용하는가?

## 참고
- 현재 자동 전환(소진 후)은 `AutoSwitchEngine`(순수 상태머신, 풀당 1). 이 설계는 그 앞단에
  "전환 시점을 100%→마진+quiesce로 당기는" 계층을 추가하는 것 — 엔진 자체는 재사용.
- 관련: [[reset-probe-prep]](리셋 시점 확정), [[codex-support-prep]](프로바이더 풀·hook 관측).
