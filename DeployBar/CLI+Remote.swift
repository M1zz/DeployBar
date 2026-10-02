import AppKit

// 명령줄 배포 — 떠 있는 DeployBar 에 요청을 넘기고 결과를 기다린다 (받는 쪽은 Store+Remote).
//
//   DeployBar --ready                         지금 배포할 수 있는 앱 / 심사 중 / 막힌 앱
//   DeployBar --deploy <앱> [--bump patch|minor|major] [--check] [--no-wait] [--quiet] [--timeout <분>]
//
// 폰에서 Claude Code(Remote Control)로 이 Mac 의 세션에 "달빛 배포해줘" 라고 하면 그 세션이 이걸 부른다.
// 버튼을 누른 것과 똑같이 돈다 — 진행판·알림·로그가 창에도 그대로 뜬다.
// 끝 코드: 0 성공 · 2 미완(업로드는 됐지만 심사에 못 냄) · 1 실패 · 3 거절(막힘·이름 모호·다른 배포 중)
enum RemoteCLI {
    static let bundleId = "com.leeo.deploybar"

    static func run() -> Never {
        let a = CommandLine.arguments
        func value(_ flag: String) -> String? {
            a.firstIndex(of: flag).flatMap { a.count > $0 + 1 && !a[$0 + 1].hasPrefix("--") ? a[$0 + 1] : nil }
        }
        guard ensureRunning() else {
            print("❌ DeployBar 앱이 응답하지 않습니다 — /Applications/DeployBar.app 을 직접 열어 보세요"); exit(1)
        }

        if a.contains("--ready") {
            guard let r = ask(["kind": "ready"], until: ["list"], timeout: 30) else { print("❌ 응답 없음"); exit(1) }
            print(r["message"] ?? ""); exit(0)
        }

        guard let name = value("--deploy") else {
            print("사용법: DeployBar --deploy <앱> [--bump patch|minor|major] [--check] [--no-wait] [--quiet]"); exit(1)
        }
        var req = ["kind": "deploy", "app": name, "lane": a.contains("--check") ? "check" : "appstore"]
        if let b = value("--bump") {
            guard ["patch", "minor", "major"].contains(b) else { print("--bump 은 patch · minor · major 중 하나"); exit(1) }
            req["bump"] = b
        }
        // 받기 전에 그 앱만 다시 조회하므로(xcodebuild·ASC) 넉넉히 기다린다
        guard let first = ask(req, until: ["accepted", "rejected"], timeout: 180, keepListening: true) else {
            print("❌ 응답 없음 — DeployBar 가 바쁘거나 이 기능이 없는 옛 빌드일 수 있습니다"); exit(1)
        }
        if first["kind"] == "rejected" { print("⛔️ \(first["message"] ?? "")"); exit(3) }
        print("🚀 \(first["message"] ?? "")")
        let log = first["log"] ?? ""
        if !log.isEmpty { print("   로그: \(log)") }
        if a.contains("--no-wait") { exit(0) }

        // 끝날 때까지 — 로그 파일의 새 줄을 그대로 흘려 보낸다 (처리 대기까지 길면 한 시간)
        let minutes = Double(value("--timeout") ?? "") ?? 90
        let deadline = Date().addingTimeInterval(minutes * 60)
        let quiet = a.contains("--quiet")
        var offset: UInt64 = 0
        while Date() < deadline {
            if !quiet, !log.isEmpty, let h = FileHandle(forReadingAtPath: log) {
                try? h.seek(toOffset: offset)
                let data = h.readDataToEndOfFile()
                offset += UInt64(data.count)
                try? h.close()
                if let s = String(data: data, encoding: .utf8), !s.isEmpty { print(s, terminator: "") }
            }
            if let done = Inbox.shared.take("done") {
                let line = done["message"] ?? ""
                print("\n🏁 \(line)")
                exit(line.hasPrefix("✅") ? 0 : line.hasPrefix("⚠️") ? 2 : 1)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(1))
        }
        print("\n⏱ \(Int(minutes))분이 지나도 끝나지 않았습니다 — 배포는 계속 돕니다. 창이나 `--logs last` 로 확인하세요")
        exit(2)
    }

    // ── 주고받기 ───────────────────────────────────────────────────────
    /// 이번 명령이 보낸 요청의 답만 모은다 (id 로 가른다 — 다른 명령줄이 동시에 물어도 섞이지 않게)
    final class Inbox {
        static let shared = Inbox()
        var id = UUID().uuidString
        private var got: [[String: String]] = []
        private var token: NSObjectProtocol?
        func start() {
            guard token == nil else { return }
            token = DistributedNotificationCenter.default().addObserver(
                forName: RemoteDeploy.reply, object: nil, queue: nil
            ) { [weak self] note in
                guard let self, let info = note.userInfo as? [String: String], info["id"] == self.id else { return }
                self.got.append(info)
            }
        }
        func take(_ kinds: Set<String>) -> [String: String]? {
            guard let i = got.firstIndex(where: { kinds.contains($0["kind"] ?? "") }) else { return nil }
            return got.remove(at: i)
        }
        func take(_ kind: String) -> [String: String]? { take([kind]) }
    }

    static func ask(_ req: [String: String], until kinds: Set<String>, timeout: TimeInterval,
                    keepListening: Bool = false) -> [String: String]? {
        let inbox = Inbox.shared
        inbox.start()
        var body = req
        body["id"] = inbox.id
        DistributedNotificationCenter.default().postNotificationName(
            RemoteDeploy.request, object: nil, userInfo: body, deliverImmediately: true)
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let r = inbox.take(kinds) { return r }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        return nil
    }

    /// 창 앱이 떠 있고 요청을 듣고 있는가. 안 떠 있으면 띄우고, 들을 때까지 기다린다.
    static func ensureRunning() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .contains { $0.processIdentifier != me }
        if !running {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-b", bundleId]   // -g: 앞으로 끌어오지 않는다 (원격에서 부를 때 화면을 뺏지 않게)
            try? p.run(); p.waitUntilExit()
        }
        // 막 뜬 앱은 Store 가 만들어진 뒤에야 듣는다 — 짧게 여러 번 묻는다
        for _ in 0..<20 {
            if ask(["kind": "ping"], until: ["pong"], timeout: 2) != nil { return true }
        }
        return false
    }
}
