import Foundation

// UI 없이 확인만 할 때 쓰는 명령들. 앱이 뜨기 전에 처리하고 그대로 종료한다.
//
//   --status [--pull]   앱별 배포 준비 N/M + 체크리스트 전체 (--pull 이면 원격 커밋도 받아온다)
//   --audit             무엇이 관리되고, 무엇이 왜 빠졌나
//   --builds  <앱>      올린 빌드가 App Store Connect 에 도착했나
//   --prompt  <앱>      잠김 해결 지시문 (UI 의 [해결 프롬프트] 와 같은 글)
//   --doctor  [앱]      배포 규칙 점검
//   --template <앱>     설치될 deploy.env·predeploy.sh 미리보기 (--write 로 실제 설치)
//   --notes   <앱>      언어별 릴리즈노트 초안 미리보기
//   --selftest-changes  상태 변화 알림 규칙 검증
//
// App.init 에서 부른다 — Scene 이 만들어지기 전에 끝나야 창이 뜨지 않는다.
enum CLI {
    static func runIfRequested() {
    // 헤드리스 상태 조회 (테스트/CLI 용): DeployBar --status
    if CommandLine.arguments.contains("--status") {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let all = await Status.all(pull: CommandLine.arguments.contains("--pull"))
            for s in all {
                let local = "v\(s.localVersion ?? "?")/\(s.localBuild ?? "?")"
                let live = s.liveVersion.map { "v\($0)" } ?? "—"
                let mark = s.inReview ? "🟣" : (s.deployable ? "🟢" : (s.readiness.blockers.isEmpty ? "⚪️" : "🟠"))
                print("\(mark) \(s.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(s.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) local:\(local)  live:\(live)")
                let head = s.inReview ? "제출함 · \(s.reviewLabel ?? "심사 중") — 결과 기다리는 중" : s.readiness.headline
                print("   배포 준비 \(s.readiness.passedCount)/\(s.readiness.total) — \(head)")
                // 통과한 항목도 전부 보여 준다: 아무것도 안 뜨면 준비된 건지 검사를 안 한 건지 알 수 없다
                for item in s.readiness.sorted {
                    let mark = item.level == .blocked ? "❌" : (item.level == .need ? "⚠️" : "✅")
                    print("     \(mark) \(item.title) — \(item.detail)\(item.fix.map { " [\($0.label)]" } ?? "")")
                    if let todo = item.todo { print("        → \(todo)") }
                }
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
    // 헤드리스 배포 규칙 점검: DeployBar --doctor [앱이름]
    if CommandLine.arguments.contains("--doctor") {
        let filter = CommandLine.arguments.last.flatMap { $0 == "--doctor" ? nil : $0 }
        var bad = 0
        let apps = AppRepo.registry().filter { filter == nil || $0.name.contains(filter!) }
        for app in apps {
            let checks = Scaffold.doctor(app)
            let problems = checks.filter { $0.level != .ok }
            print("\n━━━ \(app.name) \(problems.isEmpty ? "✅" : "· 손볼 곳 \(problems.count)")")
            for c in checks { print("  \(c.line)") }
            if !problems.isEmpty { bad += 1 }
        }
        print("\n규칙 충족 \(apps.count - bad)/\(apps.count)")
        exit(0)
    }
    // 변화 감지 규칙 검증: DeployBar --selftest-changes
    if CommandLine.arguments.contains("--selftest-changes") {
        func app(_ name: String, live: String?, review: String?, rv: String?,
                 state: DeployState = .ready, blockers: [ReadyItem] = []) -> AppStatus {
            var s = AppStatus(name: name, path: "/tmp/\(name)", state: state)
            s.bundleId = "com.test.\(name)"
            s.liveVersion = live; s.reviewState = review; s.reviewVersion = rv
            s.readiness = Readiness(items: blockers)
            return s
        }
        let blocker = ReadyItem(key: "git", level: .blocked, title: "커밋되지 않은 변경", detail: "")
        let cases: [(String, AppStatus, AppStatus, Bool)] = [
            ("심사 대기 → 심사 중",
             app("A", live: "1.0", review: "WAITING_FOR_REVIEW", rv: "1.1"),
             app("A", live: "1.0", review: "IN_REVIEW", rv: "1.1"), true),
            ("심사 중 → 거부됨",
             app("B", live: "1.0", review: "IN_REVIEW", rv: "1.1"),
             app("B", live: "1.0", review: "REJECTED", rv: "1.1"), true),
            ("심사 중 → 출시 대기",
             app("C", live: "1.0", review: "IN_REVIEW", rv: "1.1"),
             app("C", live: "1.0", review: "PENDING_DEVELOPER_RELEASE", rv: "1.1"), true),
            ("스토어 버전 올라감(출시)",
             app("D", live: "1.0", review: "PENDING_DEVELOPER_RELEASE", rv: "1.1"),
             app("D", live: "1.1", review: nil, rv: nil), true),
            ("막힘 → 배포 가능",
             app("E", live: "1.0", review: nil, rv: nil, blockers: [blocker]),
             app("E", live: "1.0", review: nil, rv: nil), true),
            ("아무 변화 없음",
             app("F", live: "1.0", review: "IN_REVIEW", rv: "1.1"),
             app("F", live: "1.0", review: "IN_REVIEW", rv: "1.1"), false),
            ("첫 조회(과거 없음) — 알리지 않아야",
             AppStatus(name: "G", path: "/tmp/G", state: .loading),
             app("G", live: "1.0", review: "IN_REVIEW", rv: "1.1"), false),
            ("스토어 버전이 낮아짐 — 알리지 않아야",
             app("H", live: "2.0", review: nil, rv: nil),
             app("H", live: "1.9", review: nil, rv: nil), false),
        ]
        var bad = 0
        for (name, old, new, expect) in cases {
            let e = StatusChange.event(from: old, to: new)
            let ok = (e != nil) == expect
            if !ok { bad += 1 }
            print("\(ok ? "✅" : "❌") \(name)\(e.map { "  → \($0.title): \($0.body)" } ?? "  → (알림 없음)")")
        }
        print(bad == 0 ? "\n전부 통과" : "\n실패 \(bad)건")
        exit(bad == 0 ? 0 : 1)
    }
    // 관리 대상 점검: DeployBar --audit  (뭐가 관리되고, 뭐가 왜 빠졌나)
    if CommandLine.arguments.contains("--audit") {
        let apps = AppRepo.registry()
        print("루트: \(AppRepo.root)")
        print("\n관리 중 \(apps.count)개")
        for a in apps {
            let dup = AppRepo.ambiguousProjects(a.path)
            print("  ✅ \(a.name)\(dup.count > 1 ? "  ⚠️ 프로젝트 \(dup.count)개: \(dup.joined(separator: ", "))" : "")")
        }
        let hidden = AppRepo.hiddenApps()
        if !hidden.isEmpty {
            print("\n관리에서 뺌 \(hidden.count)개")
            for h in hidden { print("  🚫 \(h.name)") }
        }
        let skipped = AppRepo.skipped()
        if !skipped.isEmpty {
            print("\n자동 발견에서 빠짐 \(skipped.count)개")
            for k in skipped { print("  \(k.fixable ? "⚠️" : "·") \(k.name) — \(k.reason)") }
        }
        print("\n루트 밖의 앱은 자동 발견되지 않습니다. apps.json 에 경로를 직접 넣으면 관리됩니다.")
        exit(0)
    }
    // 업로드한 빌드가 App Store Connect 에 도착했나: DeployBar --builds 앱이름
    if let i = CommandLine.arguments.firstIndex(of: "--builds") {
        let name = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
        guard let app = AppRepo.registry().first(where: { $0.name.contains(name) }), !name.isEmpty else {
            print("앱을 찾지 못했습니다: \(name)"); exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let r = AppRepo.resolve(app)
                let info = try AppRepo.buildSettings(r)
                guard let id = try await ASCClient.appId(bundleId: info.bundleId) else {
                    print("ASC 에서 앱을 찾지 못했습니다: \(info.bundleId)"); sem.signal(); return
                }
                print("\(app.name) · \(info.bundleId) · 로컬 v\(info.marketingVersion)(\(info.buildNumber))")
                for b in try await ASCClient.recentBuilds(appId: id) {
                    print("  v\(b.version) build \(b.build)  \(b.state)  \(b.uploaded)")
                }
            } catch { print("조회 실패: \(error.localizedDescription)") }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
    // 잠김 해결 프롬프트: DeployBar --prompt 앱이름  (UI 의 [해결 프롬프트] 와 같은 글)
    if let i = CommandLine.arguments.firstIndex(of: "--prompt") {
        let name = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
        guard let app = AppRepo.registry().first(where: { $0.name.contains(name) }), !name.isEmpty else {
            print("앱을 찾지 못했습니다: \(name)"); exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let st = await Status.of(app)
            if st.readiness.passedCount == st.readiness.total {
                print("\(app.name): 배포에 필요한 \(st.readiness.total)가지가 모두 준비됐습니다 — 고칠 게 없습니다.")
            } else {
                print(st.readiness.promptText(for: st))
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
    // 템플릿 미리보기(파일을 쓰지 않음): DeployBar --template 앱이름
    if let i = CommandLine.arguments.firstIndex(of: "--template") {
        let name = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
        guard let app = AppRepo.registry().first(where: { $0.name.contains(name) }), !name.isEmpty else {
            print("앱을 찾지 못했습니다: \(name)"); exit(1)
        }
        // --write 를 주면 UI 의 [배포 템플릿 설치] 와 똑같이 파일을 만든다 (있는 파일은 안 건드림)
        if CommandLine.arguments.contains("--write") {
            for line in Scaffold.autoConfigure(app).lines { print(line) }
            exit(0)
        }
        let r = AppRepo.resolve(app)
        let report = Localization.scan(app.path)
        let locales = r.locales.isEmpty ? report.locales : r.locales
        let platform = (try? AppRepo.buildSettings(r))?.platform ?? .iOS
        // 실제 [자동 설정] 과 같은 기준으로 게이트를 정해 보여 준다 (번역 구멍이 있으면 warn)
        let gate = locales.count > 1 ? (report.ok ? "strict" : "warn") : "off"
        print("───── \(app.name)/deploy.env ─────")
        print(Scaffold.deployEnvTemplate(scheme: r.scheme, locales: locales,
                                         versionXcconfig: Scaffold.findVersionXcconfig(app.path),
                                         platform: platform, gate: gate))
        print("\n───── \(app.name)/scripts/predeploy.sh ─────")
        print(Scaffold.predeployTemplate(scheme: r.scheme, projectFlag: r.projFlag,
                                         container: (r.projContainer as NSString).lastPathComponent,
                                         isMac: platform == .macOS))
        exit(0)
    }
    // 레포에 써 둔 릴리즈노트를 제대로 읽는지: DeployBar --reponotes [앱] [버전]
    // 인자를 안 주면 관리 중인 앱 전부를 훑어 "어느 앱이 원고를 갖고 있나" 를 보여 준다.
    if let i = CommandLine.arguments.firstIndex(of: "--reponotes") {
        let rest = Array(CommandLine.arguments.dropFirst(i + 1))
        let apps = rest.isEmpty ? AppRepo.registry()
                                : AppRepo.registry().filter { $0.name.contains(rest[0]) }
        for app in apps {
            // 버전을 안 주면 그 앱의 로컬 마케팅 버전을 쓴다
            let v = rest.count > 1 ? rest[1]
                : ((try? AppRepo.buildSettings(AppRepo.resolve(app)))?.marketingVersion ?? "")
            guard !v.isEmpty else { print("· \(app.name) — 버전을 읽지 못했습니다"); continue }
            if let found = RepoNotes.read(app.path, version: v) {
                print("\n✅ \(app.name) v\(v) — \(found.source)")
                for (lang, text) in found.texts.sorted(by: { $0.key < $1.key }) {
                    print("   ── \(lang)")
                    for line in text.split(separator: "\n") { print("      \(line)") }
                }
            } else if rest.count > 0 {
                print("\n· \(app.name) v\(v) — 스토어용 절을 찾지 못했습니다")
            }
        }
        exit(0)
    }
    // 게이트까지만 돌려 보고 단계판을 그린다(업로드하지 않음): DeployBar --check 앱이름
    //
    // check 레인은 원격 받기·다국어·릴리즈노트·predeploy 까지만 하고 멈춘다.
    // UI 의 진행 패널과 **같은 보고 채널**을 쓰므로, 여기서 칸이 제대로 켜지면
    // 창에서도 제대로 켜진다. 배포를 실제로 돌리지 않고 배선을 확인할 수 있는 유일한 길이다.
    if let i = CommandLine.arguments.firstIndex(of: "--check") {
        let name = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
        guard let app = AppRepo.registry().first(where: { $0.name.contains(name) }), !name.isEmpty else {
            print("앱을 찾지 못했습니다: \(name)"); exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let box = ProgressBox()
            let verbose = CommandLine.arguments.contains("--verbose")
            // 릴리즈노트 미리 채우기는 Store(UI)가 Deployer 앞에서 도는 칸이라
            // CLI 의 check 경로에는 없다. 대기로 남겨 두면 "안 한 건가" 로 읽히므로 밝혀 둔다.
            box.report(.notesPrefill, .skipped, "check 모드 — 스토어에 쓰지 않습니다")
            do {
                _ = try await Deployer.deploy(app, lane: .check,
                                              onLog: { if verbose { print("   \($0)") } },
                                              onStage: { box.report($0, $1, $2) })
            } catch let e as DeployError {
                box.fail(e.title)
                print("\n❌ \(e.stage) — \(e.title)")
                for t in e.todo { print("   → \(t)") }
            } catch {
                box.fail(error.localizedDescription)
                print("\n❌ \(error.localizedDescription)")
            }
            print(box.board(app.name))
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
    // 릴리즈노트 미리보기(업로드하지 않음): DeployBar --notes 앱이름
    if let i = CommandLine.arguments.firstIndex(of: "--notes") {
        let name = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : ""
        guard let app = AppRepo.registry().first(where: { $0.name.contains(name) }), !name.isEmpty else {
            print("앱을 찾지 못했습니다: \(name)"); exit(1)
        }
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            var codes: [String] = []
            do {
                if let t = try await ReleaseNotes.editableVersionAndLocales(app) {
                    codes = t.localeCodes
                    print("App Store v\(t.versionString) · 편집 가능 · 언어 \(codes.count)개")
                } else {
                    print("편집 가능한 App Store 버전 없음 — 프로젝트 설정 기준으로 표시")
                }
            } catch { print("ASC 조회 실패: \(error.localizedDescription)") }
            if codes.isEmpty {
                let r = AppRepo.resolve(app)
                codes = r.locales.isEmpty ? Localization.scan(app.path).locales : r.locales
            }
            // 실제 배포 경로와 같은 기준(직전 릴리즈 = App Store 라이브 버전)으로 뽑는다
            let st = await Status.of(app)
            let d = await ReleaseNotes.draft(app, liveVersion: st.liveVersion,
                                             localVersion: st.localVersion, locales: codes)
            print("기준: \(d.note ?? "-")")
            print("커밋 \(d.commits.count)개 · 대상 언어: \(Locales.sorted(codes).joined(separator: ", "))")
            for loc in Locales.sorted(codes) {
                let text = d.texts[loc] ?? ""
                let onDevice = Locales.supportsOnDeviceTranslation(loc) ? "온디바이스 번역 가능" : "온디바이스 번역 불가 — 직접 입력 필요"
                print("\n── \(loc) (\(Locales.displayName(loc))) \(text.isEmpty ? "· 비어 있음 · \(onDevice)" : "")")
                if !text.isEmpty { print(text) }
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    }
    }
}

/// CLI 에서 단계 보고를 모아 두는 상자. Deployer 의 onStage 는 @Sendable 이라
/// 액터 밖에서 불리므로 잠금으로 감싼다 (UI 는 Job 이 MainActor 에서 같은 일을 한다).
private final class ProgressBox: @unchecked Sendable {
    private var p = DeployProgress()
    private let lock = NSLock()

    func report(_ s: DeployStage, _ state: StageState, _ note: String?) {
        lock.lock(); defer { lock.unlock() }
        if state == .running { p.begin(s) } else { p.finish(s, state, note: note) }
    }
    func fail(_ note: String) {
        lock.lock(); defer { lock.unlock() }
        p.failCurrent(note: note)
    }

    func board(_ appName: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let pct = Int((p.fraction() * 100).rounded())
        let filled = Int(p.fraction() * 30)
        let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 30 - filled)
        var out = "\n━━ \(appName) · \(bar) \(pct)% · \(p.finishedCount)/\(p.steps.count)\n"
        for s in p.steps {
            let mark: String
            switch s.state {
            case .pending: mark = "·"
            case .running: mark = "▶"
            case .done:    mark = "✅"
            case .skipped: mark = "⏭"
            case .failed:  mark = "❌"
            }
            let took = s.elapsed().map { $0 >= 1 ? "  (\($0.stageClock))" : "" } ?? ""
            let title = s.stage.title.padding(toLength: 16, withPad: " ", startingAt: 0)
            out += "  \(mark) \(title)\(s.note ?? "")\(took)\n"
        }
        return out
    }
}
