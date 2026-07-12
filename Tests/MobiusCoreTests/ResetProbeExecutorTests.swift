import XCTest
@testable import MobiusCore

final class ResetProbeExecutorTests: XCTestCase {

    // MARK: Claude — 네트워크 전에 판정되는 경로

    func testClaudeProbeSkipsExpiredTokenWithoutNetwork() async throws {
        // expiresAt은 실측처럼 13자리 epoch ms여야 한다 (작은 값은 초로 해석돼 미만료 오판)
        let now = Date()
        let blob = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": "tok",
                              "expiresAt": (now.timeIntervalSince1970 - 60) * 1000],
        ])
        let outcome = try await ClaudeResetProbe.execute(keychainBlob: blob, now: now)
        XCTAssertEqual(outcome, .tokenExpired)
    }

    func testClaudeProbeRejectsBlobWithoutToken() async throws {
        let blob = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": [:]])
        let outcome = try await ClaudeResetProbe.execute(keychainBlob: blob)
        XCTAssertEqual(outcome, .unauthorized)
    }

    // MARK: Codex — stdout/파일 해석 (G2 실측 포맷 기반 fixture)

    /// codex exec --json stdout 실측 4이벤트 (2026-07-12)
    let execStdout = """
    {"type":"thread.started","thread_id":"019f56d0-b261-77b0-97ac-fb3203f57ab1"}
    {"type":"turn.started"}
    {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}
    {"type":"turn.completed","usage":{"input_tokens":18774,"cached_input_tokens":9984,"output_tokens":5,"reasoning_output_tokens":0}}
    """

    /// rollout 로그의 token_count 이벤트 실측 구조 (CodexRateLimitParser 문서와 동일)
    let tokenCountLine = """
    {"timestamp":"2026-07-12T14:52:31.371Z","type":"event_msg","payload":{"type":"token_count",\
    "info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":17.0,\
    "window_minutes":300,"resets_at":1784311137},"secondary":{"used_percent":92.0,\
    "window_minutes":10080,"resets_at":1784786460},"plan_type":"pro",\
    "rate_limit_reached_type":null}}}
    """

    func testThreadIDParsedFromExecStdout() {
        XCTAssertEqual(CodexResetProbe.threadID(fromJSONLines: execStdout),
                       "019f56d0-b261-77b0-97ac-fb3203f57ab1")
        XCTAssertNil(CodexResetProbe.threadID(fromJSONLines: "{\"type\":\"turn.started\"}"))
        XCTAssertNil(CodexResetProbe.threadID(fromJSONLines: "비JSON 출력"))
    }

    func testRolloutFileFoundByThreadIDSuffixInRecentDayDirs() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codex-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        let c = Calendar.current.dateComponents([.year, .month, .day], from: now)
        let dayDir = root.appendingPathComponent(
            String(format: "%04d/%02d/%02d", c.year!, c.month!, c.day!))
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let threadID = "019f56d0-b261-77b0-97ac-fb3203f57ab1"
        let file = dayDir.appendingPathComponent("rollout-2026-07-12T23-52-25-\(threadID).jsonl")
        try Data(tokenCountLine.utf8).write(to: file)
        // 같은 날 다른 세션 파일은 무시된다
        try Data().write(to: dayDir.appendingPathComponent("rollout-2026-07-12T00-00-00-others.jsonl"))

        XCTAssertEqual(CodexResetProbe.rolloutFile(under: root, threadID: threadID, now: now),
                       file)
        XCTAssertNil(CodexResetProbe.rolloutFile(under: root, threadID: "없는-id", now: now))
    }

    func testLatestStatusReadsRateLimitsFromRolloutFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rollout-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        // rate_limits 없는 라인들 사이에서 token_count를 찾아낸다
        let content = """
        {"timestamp":"2026-07-12T14:52:26Z","type":"session_meta","payload":{"type":"session_meta"}}
        \(tokenCountLine)
        {"timestamp":"2026-07-12T14:52:32Z","type":"event_msg","payload":{"type":"agent_message"}}
        """
        try Data(content.utf8).write(to: url)

        let status = try XCTUnwrap(CodexResetProbe.latestStatus(inFile: url))
        XCTAssertEqual(status.primary?.usedPercent, 17.0)
        XCTAssertEqual(status.primary?.resetsAt, Date(timeIntervalSince1970: 1_784_311_137))
        let snap = status.usageSnapshot(fetchedAt: Date())
        XCTAssertNotNil(snap.fiveHourResetsAt) // → .pinned 경로
        XCTAssertEqual(snap.sevenDayPercent, 92.0)
    }
}
