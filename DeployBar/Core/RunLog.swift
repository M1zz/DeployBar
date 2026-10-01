import Foundation

// 배포·점검 로그를 파일로 남긴다.
//
// 왜 필요한가: 로그 창은 **창을 닫는 순간 사라진다.** 그런데 정작 알아야 할 때는 그다음이다.
// 2026-09-08 무지개 공방 업로드가 거부됐을 때, 거부 사유(CFBundleVersion 1 은
// 이미 올라간 11 보다 낮다)는 로그 창에 분명히 흘러갔는데 창과 함께 없어졌다.
// 무슨 일이 있었는지 알아내려고 애플의 altool 로그(~/Library/Logs/ContentDelivery)를
// 뒤져야 했다 — 우리가 만든 실패를 우리가 못 읽는 상태였다.
//
// 그래서 job 에 찍히는 모든 줄은 곧바로 파일에도 쓴다. 앱이 죽어도 남게 줄마다 즉시 쓴다.
final class RunLog: @unchecked Sendable {

    /// ~/Library/Application Support/DeployBar/logs
    static var dir: URL {
        let d = Config.supportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    let url: URL
    private let handle: FileHandle?
    private let lock = NSLock()
    private var closed = false

    init?(title: String) {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        // 파일 이름에 쓸 수 없는 글자만 걷어낸다 (한글 앱 이름은 그대로 둔다)
        let slug = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: " · ", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .prefix(60)
        let url = RunLog.dir.appendingPathComponent("\(f.string(from: Date()))_\(slug).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = h
        RunLog.prune()
        write("━━ \(title)")
        write("━━ 시작 \(RunLog.stamp())")
        for line in RunLog.identity { write(line) }
    }

    /// 지금 도는 DeployBar 가 어느 것인가 — 실행 파일 위치와 빌드 시각.
    ///
    /// 2026-10-01, 고쳐서 설치까지 한 문제가 또 났다. Xcode 에서 띄워 둔 **옛 디버그 빌드**로 배포했기
    /// 때문이다. 로그만 봐서는 어느 DeployBar 가 돌았는지 알 수 없어 원인을 찾는 데 시간이 들었다.
    /// 그래서 모든 실행 로그 첫머리에 적고, 개발용 빌드면 경고한다.
    static var identity: [String] {
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let built = (try? FileManager.default.attributesOfItem(atPath: exe.path)[.modificationDate] as? Date) ?? nil
        let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"
        var out = ["🧩 DeployBar: \(Bundle.main.bundlePath) · 빌드 \(built.map(f.string) ?? "?")"]
        if isDevBuild {
            out.append("⚠️  Xcode 에서 띄운 개발용 DeployBar 입니다 — 고친 코드가 빠져 있을 수 있습니다. 배포는 /Applications 의 DeployBar 로 하세요")
        }
        return out
    }

    /// Xcode 가 만든 빌드(DerivedData)로 돌고 있나
    static var isDevBuild: Bool { Bundle.main.bundlePath.contains("/DerivedData/") }

    func write(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let handle else { return }
        // 줄마다 바로 쓴다. 버퍼에 모아 두면 크래시·강제종료 때 정작 마지막 줄을 잃는다.
        try? handle.write(contentsOf: Data("\(RunLog.stamp()) \(line)\n".utf8))
    }

    func close(_ footer: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard !closed, let handle else { return }
        if let footer { try? handle.write(contentsOf: Data("\(RunLog.stamp()) \(footer)\n".utf8)) }
        try? handle.close()
        closed = true
    }

    // ── 목록 ─────────────────────────────────────────────────────────
    /// 최근 로그 파일 (새것 먼저)
    static func recent(_ limit: Int = 20) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "log" }
            .sorted { modified($0) > modified($1) }
            .prefix(limit).map { $0 }
    }

    private static func modified(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// 오래된 것부터 지운다 — 로그가 무한정 쌓여 지원 폴더를 채우지 않게.
    private static func prune(keep: Int = 80) {
        let all = recent(1000)
        guard all.count > keep else { return }
        for u in all.dropFirst(keep) { try? FileManager.default.removeItem(at: u) }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }

    // ── 애플이 따로 남기는 로그 ───────────────────────────────────────
    /// altool 은 자기 로그를 여기에 남긴다. 업로드 거부 사유의 **원문 전체**가 여기 있다
    /// (우리가 잡은 출력은 마지막 몇 줄뿐이라, 검증 오류의 자세한 내용은 이쪽이 낫다).
    static var altoolLogDir: URL {
        Config.home.appendingPathComponent("Library/Logs/ContentDelivery/com.apple.itunes.altool")
    }
    /// 가장 최근 altool 로그 파일 (업로드 직후에 부르면 그게 방금 그 업로드다)
    static func latestAltoolLog() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: altoolLogDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".txt") }
            .max { modified($0) < modified($1) }
    }
}
