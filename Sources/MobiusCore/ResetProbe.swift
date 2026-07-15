import Foundation

/// 프로브 실행 결과 (실행기 공통).
public enum ResetProbeOutcome: Equatable {
    case pinned(UsageSnapshot) // 창 시작 + 다음 리셋 시각 확정
    case unconfirmed           // 최소 호출은 성공(창은 시작됨)했으나 시각 확인 실패
    case tokenExpired          // 저장 토큰 만료 — 재시도 무의미 (리프레시 금지: 회전 위험)
    case unauthorized          // 401/403 (토큰 폐기 계열) — 재시도 무의미
}

public enum ResetProbeError: Error {
    case network(String)     // 재시도 대상 (호출자가 백오프)
    case codexFailed(String) // codex exec 실패/출력 해석 불가 — 재시도 대상
}

/// Claude 리셋 프로브 — 저장된 계정 토큰으로 최소 모델 호출 1회를 보내 5h 창을 시작시키고,
/// usage 재조회로 다음 리셋 시각을 확정한다. 비활성 계정도 전환 없이 가능.
/// 실측 근거·파라미터: docs/design/reset-probe-prep.md G1 (2026-07-12)
/// - 시스템 프롬프트 불필요 (beta 헤더만으로 OAuth 수락)
/// - usage 반영 지연 15~30초 → 확인은 지연 폴링(+15/+30/+60s)
public enum ClaudeResetProbe {
    public static let messagesEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    /// OAuth 카탈로그 실측: claude-3-5-haiku는 404 — haiku 4.5 사용. max_tokens 1이면
    /// 입력 8토큰/출력 1토큰으로 utilization에 비가시(0.0% 유지).
    public static let probeModel = "claude-haiku-4-5-20251001"
    /// usage 확정 확인 폴링 간격 (누적 +15/+30/+60초)
    public static var confirmDelays: [TimeInterval] = [15, 15, 30]

    public static func execute(keychainBlob: Data, now: Date = Date()) async throws
        -> ResetProbeOutcome {
        guard let token = UsageFetcher.accessToken(from: keychainBlob) else { return .unauthorized }
        // 만료 토큰은 호출 전에 스킵 — 리프레시는 하지 않는다 (refresh token 회전이
        // 스냅샷·Keychain 사본을 실효시키는 실패 클래스, CLAUDE.md 핵심 사실 참조).
        if let exp = UsageFetcher.expiresAt(from: keychainBlob), exp <= now {
            return .tokenExpired
        }

        var req = URLRequest(url: messagesEndpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 30
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": probeModel,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ok"]],
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw ResetProbeError.network("응답 없음")
        }
        if http.statusCode == 401 || http.statusCode == 403 { return .unauthorized }
        guard http.statusCode == 200 else {
            throw ResetProbeError.network(
                "HTTP \(http.statusCode): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }

        // 호출 성공 = 창은 시작됨. 이후는 확인만 — 실패해도 모델 재호출은 하지 않는다.
        for delay in confirmDelays {
            try? await Task.sleep(for: .seconds(delay))
            guard let snap = try? await UsageFetcher.fetch(keychainBlob: keychainBlob),
                  snap.fiveHourResetsAt != nil else { continue }
            return .pinned(snap)
        }
        return .unconfirmed
    }
}

/// Codex 리셋 프로브 — **활성 계정 전용**. `codex exec --json` 최소 1턴을 돌리고,
/// stdout의 thread_id로 rollout 파일을 특정해 rate_limits를 직접 파싱한다.
/// 실측 근거: docs/design/reset-probe-prep.md G2 (2026-07-12)
/// - stdout JSON에는 rate_limits가 없다(usage 토큰 수만) — 파일 파싱이 유일 경로
/// - 워처(tailOnly)는 일회성 턴의 신호를 놓칠 수 있어 여기서 직접 읽는다
public struct CodexResetProbe: Sendable {
    public var binaryPath: String
    public var sessionsDir: URL
    /// exec 턴 최대 대기 — 초과 시 프로세스 종료 후 실패 처리
    public var timeout: TimeInterval = 120

    public init(binaryPath: String, sessionsDir: URL) {
        self.binaryPath = binaryPath
        self.sessionsDir = sessionsDir
    }

    public func execute(now: Date = Date()) async throws -> ResetProbeOutcome {
        let stdout = try await runExec()
        guard let threadID = Self.threadID(fromJSONLines: stdout) else {
            throw ResetProbeError.codexFailed("thread_id 없음: \(stdout.prefix(200))")
        }
        // rollout 파일은 턴 완료 직후 나타난다 — 짧게 폴링
        for _ in 0..<10 {
            if let file = Self.rolloutFile(under: sessionsDir, threadID: threadID, now: now),
               let status = Self.latestStatus(inFile: file) {
                let snap = status.usageSnapshot(fetchedAt: now)
                return snap.fiveHourResetsAt != nil ? .pinned(snap) : .unconfirmed
            }
            try? await Task.sleep(for: .seconds(1))
        }
        return .unconfirmed
    }

    /// codex exec 최소 턴 — read-only 샌드박스, 낮은 reasoning effort (G2 확정 커맨드).
    private func runExec() async throws -> String {
        let binary = binaryPath, timeout = timeout
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: binary)
                proc.arguments = ["exec", "--json", "--skip-git-repo-check", "-s", "read-only",
                                  "-c", "model_reasoning_effort=low", "Reply with exactly: ok"]
                proc.currentDirectoryURL = FileManager.default.temporaryDirectory
                let out = Pipe()
                proc.standardOutput = out
                proc.standardError = Pipe()
                do { try proc.run() } catch {
                    cont.resume(throwing: ResetProbeError.codexFailed(
                        "실행 실패: \(error.localizedDescription)"))
                    return
                }
                let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killer.cancel()
                guard proc.terminationStatus == 0 else {
                    cont.resume(throwing: ResetProbeError.codexFailed(
                        "exit \(proc.terminationStatus)"))
                    return
                }
                cont.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    /// `--json` 이벤트 스트림에서 thread.started의 thread_id 추출 (실측 포맷:
    /// {"type":"thread.started","thread_id":"..."}).
    static func threadID(fromJSONLines text: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let obj = (try? JSONSerialization.jsonObject(
                      with: Data(line.utf8))) as? [String: Any],
                  obj["type"] as? String == "thread.started",
                  let id = obj["thread_id"] as? String else { continue }
            return id
        }
        return nil
    }

    /// thread_id는 rollout 파일명 suffix와 1:1 (실측: rollout-<로컬시각>-<thread_id>.jsonl).
    /// 날짜 디렉토리(YYYY/MM/DD)는 로컬 기준 — 자정 경계 대비 오늘·어제만 찾는다.
    static func rolloutFile(under root: URL, threadID: String,
                            calendar: Calendar = .current, now: Date = Date()) -> URL? {
        let fm = FileManager.default
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                continue
            }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = root.appendingPathComponent(
                String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            if let name = names.first(where: { $0.hasSuffix("-\(threadID).jsonl") }) {
                return dir.appendingPathComponent(name)
            }
        }
        return nil
    }

    /// 프로브 세션 파일(작음)에서 마지막 rate_limits 상태를 읽는다.
    static func latestStatus(inFile url: URL) -> CodexRateLimitStatus? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").reversed()
            .lazy.compactMap { CodexRateLimitParser.parse(line: String($0)) }
            .first { $0.primary != nil || $0.secondary != nil }
    }
}
