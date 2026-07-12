import Foundation

/// ~/.claude/projects/**/*.jsonl 을 주기 스캔해 "새로 추가된" rate-limit 이벤트만 돌려준다.
/// 네트워크 요청 없음. 앱/CLI 어느 쪽에서든 타이머로 scan()을 호출한다.
/// 첫 스캔에서는 기존 내용을 파싱하지 않고 오프셋만 기록한다 (과거 이벤트로 오탐 방지).
public final class SessionLogWatcher: @unchecked Sendable {
    let env: MobiusEnvironment
    private var offsets: [String: UInt64] = [:]   // 파일 경로 → 읽은 위치
    private var primed = false                    // 첫 스캔 여부
    private let lock = NSLock()
    /// 이 시간 안에 수정된 파일만 본다
    public var recentWindow: TimeInterval = 600

    public init(env: MobiusEnvironment) { self.env = env }

    public func scan(now: Date = Date()) -> [RateLimitHit] {
        lock.lock(); defer { lock.unlock() }
        var hits: [RateLimitHit] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: env.projectsDir,
                                     includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        for case let url as URL in en where url.pathExtension == "jsonl" {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast
            guard mtime > now.addingTimeInterval(-recentWindow) || offsets[url.path] == nil else {
                continue
            }
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            // 첫 스캔 이후 새로 나타난 파일은 전체가 "새 내용" (start=0)
            let start = offsets[url.path] ?? 0
            if start > end { // 파일이 잘렸으면(로테이션) 기준점만 리셋
                offsets[url.path] = end
                continue
            }
            guard start < end else { continue } // 새 내용 없음

            if !primed {
                // 첫 스캔: 파싱 없이 오프셋만 기록하되, 마지막 개행까지만 전진 —
                // 쓰기 도중인 부분 라인은 남겨두어 완성되면 다음 스캔에서 온전히 파싱된다
                offsets[url.path] = offsetAfterLastNewline(in: handle, start: start, end: end) ?? start
                continue
            }

            try? handle.seek(toOffset: start)
            guard let data = try? handle.read(upToCount: Int(end - start)) else { continue }
            // 마지막 개행(0x0A)까지만 완성 라인으로 취급. 개행이 없으면 오프셋 유지(부분 라인 대기).
            guard let lastNewline = data.lastIndex(of: 0x0A) else { continue }
            let completeLen = data.distance(from: data.startIndex, to: lastNewline) + 1
            offsets[url.path] = start + UInt64(completeLen)
            guard let text = String(data: data.prefix(completeLen), encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                if let hit = RateLimitParser.parse(line: String(line), now: now) { hits.append(hit) }
            }
        }
        primed = true
        return hits
    }

    /// [start, end) 구간에서 마지막 개행(0x0A)의 다음 오프셋을 찾는다.
    /// 큰 파일 전체를 읽지 않도록 뒤에서부터 청크 단위로 역방향 스캔. 개행이 없으면 nil.
    private func offsetAfterLastNewline(in handle: FileHandle,
                                        start: UInt64, end: UInt64) -> UInt64? {
        let chunkSize: UInt64 = 64 * 1024
        var high = end
        while high > start {
            let low = high > start + chunkSize ? high - chunkSize : start
            guard (try? handle.seek(toOffset: low)) != nil,
                  let chunk = try? handle.read(upToCount: Int(high - low)) else { return nil }
            if let idx = chunk.lastIndex(of: 0x0A) {
                return low + UInt64(chunk.distance(from: chunk.startIndex, to: idx)) + 1
            }
            high = low
        }
        return nil
    }
}
