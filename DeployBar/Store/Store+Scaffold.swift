import Foundation

// 배포 설정 자동 정리(scaffold), 규칙 점검(doctor), 버전 올리기.
extension Store {
    // ── 자동 설정 ("구조 잡기") ─────────────────────────────────────────
    /// 체크리스트의 [자동 설정] — deploy.env·predeploy.sh 를 만들고 빠진 값을 채운다.
    func autoConfigure(_ app: ManagedApp) async {
        guard !fixing.contains(app.path) else { return }
        fixing.insert(app.path)
        defer { fixing.remove(app.path) }
        let r = Scaffold.autoConfigure(app)
        // 상세는 로그 창에서 볼 수 있게 남기고, 카드에는 한 줄만
        let job = Job(title: "자동 설정 · \(app.name)")
        job.lines = r.lines
        job.running = false
        self.job = job
        AppRepo.clearCache()
        await refresh(fresh: false)   // refresh 가 fixResult 를 비우므로 결과 메시지는 그 뒤에 넣는다
        let done = r.created + r.changed
        fixResult[app.path] = done.isEmpty
            ? "고칠 것이 없었습니다"
            : "정리 완료 — \(done.joined(separator: ", "))"
    }

    /// 준비가 덜 된 앱을 한 번에 정리한다.
    func autoConfigureAll() {
        let targets = statuses.filter { $0.readiness.autoFixable }.compactMap { app(named: $0.path) }
        let job = Job(title: "전체 자동 설정 · \(targets.count)개")
        self.job = job
        guard !targets.isEmpty else {
            job.lines.append("자동으로 고칠 것이 있는 앱이 없습니다.")
            job.running = false
            return
        }
        Task {
            for app in targets {
                job.lines.append("")
                job.lines.append("━━━━━━ \(app.name) ━━━━━━")
                for line in Scaffold.autoConfigure(app).lines { job.lines.append("  \(line)") }
            }
            job.lines.append("")
            job.lines.append("══════ 정리 완료 — \(targets.count)개 앱 ══════")
            job.running = false
            AppRepo.clearCache()
            await refresh(fresh: false)
        }
    }

    // ── 배포 규칙 점검 / 템플릿 설치 ────────────────────────────────────
    // 앱 하나
    func runDoctor(_ app: ManagedApp) {
        let job = Job(title: "설정 점검 · \(app.name)")
        self.job = job
        Task {
            for c in Scaffold.doctor(app) { job.lines.append(c.line) }
            job.lines.append("")
            job.lines.append("규칙 설명: DeployBar/README.md 의 '앱 쪽 규칙' 표")
            job.running = false
        }
    }

    // 관리 중인 앱 전부 — 어떤 앱이 규칙을 못 지키고 있는지 한눈에
    func doctorAll() {
        let apps = AppRepo.registry()
        let job = Job(title: "전체 설정 점검 · \(apps.count)개")
        self.job = job
        Task {
            var needsWork: [String] = []
            for app in apps {
                let checks = Scaffold.doctor(app)
                let bad = checks.filter { $0.level != .ok }
                job.lines.append("")
                job.lines.append("━━━━━━ \(app.name) \(bad.isEmpty ? "✅ 규칙 충족" : "· 손볼 곳 \(bad.count)") ━━━━━━")
                for c in checks where c.level != .ok { job.lines.append("  \(c.line)") }
                if !bad.isEmpty { needsWork.append(app.name) }
            }
            job.lines.append("")
            job.lines.append("══════ 점검 완료 — 규칙 충족 \(apps.count - needsWork.count)/\(apps.count) ══════")
            if !needsWork.isEmpty {
                job.lines.append("손볼 앱: \(needsWork.joined(separator: ", "))")
                job.lines.append("각 앱의 [⋯ › 배포 템플릿 설치] 로 deploy.env·predeploy.sh 를 만들 수 있습니다.")
            }
            job.running = false
        }
    }

    // 수동 버전 올리기 (patch/minor/major)
    func bumpVersion(_ app: ManagedApp, _ kind: Deployer.VersionBump) async {
        guard let cur = statuses.first(where: { $0.path == app.path })?.localVersion else { return }
        let next = Deployer.bumpVersion(cur, kind)
        Deployer.applyMarketingVersion(app, to: next)
        AppRepo.clearCache()
        await refresh(fresh: true)
    }

    func laneLabel(_ lane: Deployer.Lane) -> String {
        switch lane {
        case .beta: return "TestFlight"
        case .appstore: return "App Store"
        case .check: return "게이트"
        }
    }
}
