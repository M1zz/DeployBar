import SwiftUI

@main
struct DeployBarApp: App {
    @StateObject private var store = Store()

    init() {
        // 헤드리스 상태 조회 (테스트/CLI 용): DeployBar --status
        if CommandLine.arguments.contains("--status") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let all = await Status.all()
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
        // 최초 실행 시 apps.json / 설정 파일이 존재하도록 시드
        _ = AppRepo.registry()
        // 배포 성공·실패 알림 권한 요청
        Notifier.requestAuth()
    }

    var body: some Scene {
        // 실행 시 뜨는 메인 창 (노치에 가린 메뉴바 아이콘을 못 찾아도 항상 보임).
        // WindowGroup 은 MenuBarExtra 가 있어도 실행 시 창을 자동으로 연다.
        WindowGroup("배포 콘솔", id: "dashboard") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 460, minHeight: 420)
        }
        .defaultSize(width: 460, height: 600)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            // 앱 아이콘과 같은 도형에서 뽑은 템플릿 이미지 (scripts/make_icon.swift).
            // 템플릿이라 밝은/어두운 메뉴바에 맞춰 macOS 가 알아서 칠한다.
            Image("MenuBarIcon").renderingMode(.template)
        }
        .menuBarExtraStyle(.window)

        Window("배포 로그", id: "log") {
            LogView().environmentObject(store)
        }
        .defaultSize(width: 660, height: 440)

        Window("릴리즈노트", id: "notes") {
            NotesView().environmentObject(store)
        }
        .defaultSize(width: 560, height: 560)

        Window("사용법", id: "guide") {
            GuideView().environmentObject(store)
        }
        .defaultSize(width: 560, height: 640)
    }
}
