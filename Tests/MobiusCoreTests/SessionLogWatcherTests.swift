import XCTest
@testable import MobiusCore

final class SessionLogWatcherTests: XCTestCase {
    var tmp: URL!; var env: MobiusEnvironment!; var log: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mobius-watch-\(UUID().uuidString)")
        env = MobiusEnvironment(home: tmp, localUser: "tester")
        try FileManager.default.createDirectory(
            at: env.projectsDir.appendingPathComponent("proj1"),
            withIntermediateDirectories: true)
        log = env.projectsDir.appendingPathComponent("proj1/session.jsonl")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    /// 레거시 epoch 포맷의 hit 라인 (timestamp 없음 → 파서는 now 기준으로 sanity 검사)
    func legacyHitLine(epoch: Int) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"text","text":"Claude AI usage limit reached|\#(epoch)"}]}}"#
    }

    func currentFormatLine(text: String) -> String {
        #"{"type":"assistant","error":"rate_limit","isApiErrorMessage":true,"apiErrorStatus":429,"message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    func append(_ line: String) throws {
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try handle.close()
    }

    func testDetectsOnlyNewlyAppendedHits() throws {
        let now = Date()
        let epoch = Int(now.addingTimeInterval(3600).timeIntervalSince1970)
        // 기존 내용에 이미 hit이 있어도 첫 스캔에서는 무시해야 함
        try (legacyHitLine(epoch: epoch) + "\n").write(to: log, atomically: true, encoding: .utf8)

        let watcher = SessionLogWatcher(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 첫 스캔: 오프셋만 기록

        // 새 줄 append → 감지되어야 함
        try append(legacyHitLine(epoch: epoch))

        let hits = watcher.scan(now: now)
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].resetsAt, Date(timeIntervalSince1970: TimeInterval(epoch)))

        XCTAssertTrue(watcher.scan(now: now).isEmpty) // 같은 내용 재감지 없음
    }

    func testCurrentFormatHitAndServerSideExclusion() throws {
        let now = Date()
        try "".write(to: log, atomically: true, encoding: .utf8)
        let watcher = SessionLogWatcher(env: env)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)

        // 서버측 제한(제외 대상) + 일반 라인 → hit 아님
        try append(currentFormatLine(
            text: "API Error: Server is temporarily limiting requests (not your usage limit) · Rate limited"))
        try append(#"{"type":"user","message":{"content":[{"type":"text","text":"hello"}]}}"#)
        XCTAssertTrue(watcher.scan(now: now).isEmpty)

        // 현행 포맷의 계정 한도(월간 지출 — 리셋 시각 없음) → hit
        try append(currentFormatLine(
            text: "You've hit your monthly spend limit · raise it at claude.ai/settings/usage"))
        let hits = watcher.scan(now: now)
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits[0].resetsAt)
    }
}
