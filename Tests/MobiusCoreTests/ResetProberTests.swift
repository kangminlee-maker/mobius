import XCTest
@testable import MobiusCore

final class ResetProberTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    var account: AccountProfile!
    var file: AccountsFile!

    override func setUp() {
        account = AccountProfile(id: UUID(), nickname: "a", emailAddress: "a@x",
                                 organizationName: "", tierDescription: "")
        // 소진 기록: t0-100에 리셋 도래 (프로브 대상)
        account.rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(-100),
                                          recordedAt: t0.addingTimeInterval(-18_000))
        file = AccountsFile(accounts: [account], activeAccountID: account.id)
        file.resetProbeEnabled = true
    }

    var resetsAt: Date { account.rateLimit!.resetsAt }

    func testDueRequiresFeatureOnAndPassedReset() {
        let prober = ResetProber()
        // 음성 대조: 기능 끔 → 대상이어도 빈 목록
        file.resetProbeEnabled = false
        XCTAssertEqual(prober.due(file: file, now: t0), [])
        file.resetProbeEnabled = true
        XCTAssertEqual(prober.due(file: file, now: t0).map(\.id), [account.id])

        // 리셋 시각 전이면 대상 아님
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: t0.addingTimeInterval(60),
                                                   recordedAt: t0)
        XCTAssertEqual(ResetProber().due(file: file, now: t0), [])
        // 소진 기록 없으면 대상 아님
        file.accounts[0].rateLimit = nil
        XCTAssertEqual(ResetProber().due(file: file, now: t0), [])
    }

    func testDueSkipsNeedsReauth() {
        file.accounts[0].needsReauth = true
        XCTAssertEqual(ResetProber().due(file: file, now: t0), [])
    }

    func testSuccessDeduplicatesPerWindowAndNewWindowRetriggers() {
        let prober = ResetProber()
        prober.noteSuccess(account.id, resetsAt: resetsAt)
        XCTAssertEqual(prober.due(file: file, now: t0), [])

        // 다음 소진 → 새 리셋 시각 = 새 창: 다시 대상
        let nextReset = t0.addingTimeInterval(3600)
        file.accounts[0].rateLimit = RateLimitInfo(resetsAt: nextReset, recordedAt: t0)
        XCTAssertEqual(prober.due(file: file, now: nextReset.addingTimeInterval(1)).map(\.id),
                       [account.id])
    }

    func testFailureBackoffThenExhaustion() {
        let prober = ResetProber()
        // 1차 실패 → 60초 백오프
        XCTAssertFalse(prober.noteFailure(account.id, resetsAt: resetsAt, now: t0))
        XCTAssertEqual(prober.due(file: file, now: t0.addingTimeInterval(59)), [])
        XCTAssertEqual(prober.due(file: file, now: t0.addingTimeInterval(60)).map(\.id),
                       [account.id])
        // 2차 실패 → 300초 백오프
        let t1 = t0.addingTimeInterval(60)
        XCTAssertFalse(prober.noteFailure(account.id, resetsAt: resetsAt, now: t1))
        XCTAssertEqual(prober.due(file: file, now: t1.addingTimeInterval(299)), [])
        XCTAssertEqual(prober.due(file: file, now: t1.addingTimeInterval(300)).map(\.id),
                       [account.id])
        // 3차 실패 = 시도 소진 → true(호출자가 이때만 알림), 이후 영구 제외
        let t2 = t1.addingTimeInterval(300)
        XCTAssertTrue(prober.noteFailure(account.id, resetsAt: resetsAt, now: t2))
        XCTAssertEqual(prober.due(file: file, now: t2.addingTimeInterval(9_999)), [])
        // done 이후 늦게 도착한 실패는 무시(재알림 없음)
        XCTAssertFalse(prober.noteFailure(account.id, resetsAt: resetsAt, now: t2))
    }

    func testGiveUpEndsWindowImmediately() {
        let prober = ResetProber()
        prober.noteGiveUp(account.id, resetsAt: resetsAt)
        XCTAssertEqual(prober.due(file: file, now: t0), [])
    }

    func testResetProbeEnabledRoundtripAndLegacyDefault() throws {
        var f = AccountsFile()
        XCTAssertFalse(f.resetProbeEnabled) // 기본 끔
        f.resetProbeEnabled = true
        let back = try JSONDecoder().decode(AccountsFile.self, from: JSONEncoder().encode(f))
        XCTAssertTrue(back.resetProbeEnabled)
        // 필드가 없는 기존 파일은 끔으로 디코드
        let legacy = try JSONDecoder().decode(
            AccountsFile.self, from: Data(#"{"accounts": []}"#.utf8))
        XCTAssertFalse(legacy.resetProbeEnabled)
    }
}
