import Foundation

// 배포 실행 — 한 앱 배포, 전체 배포, 커밋 때문에 막힌 앱 풀기.
extension Store {
    /// Xcode·macOS 가 만든 파일 때문에 배포가 막힌 앱을 푼다.
    /// .gitignore 에 표준 항목을 넣고, 이미 추적 중인 것은 추적만 해제한 뒤 커밋한다.
    /// (파일 자체는 지우지 않는다 — Xcode 가 계속 쓰는 파일이다)
    func ignoreXcodeNoise(_ app: ManagedApp) async {
        fixing.insert(app.path)
        defer { fixing.remove(app.path) }
        let dir = URL(fileURLWithPath: app.path)
        let gitignore = dir.appendingPathComponent(".gitignore")

        var body = (try? String(contentsOf: gitignore, encoding: .utf8)) ?? ""
        let existing = Set(body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        let toAdd = GitInfo.ignoreLines.filter { !existing.contains($0) }
        if !toAdd.isEmpty {
            if !body.isEmpty && !body.hasSuffix("\n") { body += "\n" }
            body += "\n# Xcode·macOS 가 자동으로 만드는 파일 (DeployBar)\n" + toAdd.joined(separator: "\n") + "\n"
            try? body.write(to: gitignore, atomically: true, encoding: .utf8)
        }
        // 이미 추적 중이던 것은 인덱스에서만 뺀다
        let tracked = GitInfo.dirtyFiles(app.path).filter(GitInfo.isNoise)
        for f in tracked {
            _ = try? Shell.capture("/usr/bin/git", ["rm", "-r", "--cached", "--ignore-unmatch", "-q", f], cwd: dir)
        }
        _ = try? Shell.capture("/usr/bin/git", ["add", ".gitignore"], cwd: dir)
        _ = try? Shell.capture("/usr/bin/git",
                               ["commit", "-m", "chore: Xcode 가 자동 생성하는 파일을 git 추적에서 제외"], cwd: dir)

        let stillDirty = GitInfo.isDirty(app.path)
        fixResult[app.path] = stillDirty
            ? "정리했지만 커밋 안 된 변경이 남아 있습니다 — 남은 건 직접 커밋하세요"
            : "정리 완료 — .gitignore 에 넣고 커밋했습니다"
        await refresh(fresh: true)
    }

    // 앱 하나를 배포하고 로그를 job 에 스트리밍. 결과 반환.
    func runOneDeploy(_ app: ManagedApp, lane: Deployer.Lane, versionBump: Deployer.VersionBump?,
                      into job: Job,
                      batch: (index: Int, total: Int, name: String)? = nil) async -> DeployOutcome {
        job.resetProgress(app: app.name, batch: batch)

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let c = cont!
        let onLog: @Sendable (String) -> Void = { c.yield($0) }
        let consumer = Task { for await line in stream { job.lines.append(line) } }

        // 단계 보고도 로그와 같은 방식으로 순서를 지켜 흘린다.
        // Task { @MainActor } 를 이벤트마다 띄우면 순서가 뒤집혀 칸이 거꾸로 켜진다.
        var stageCont: AsyncStream<(DeployStage, StageState, String?)>.Continuation!
        let stageStream = AsyncStream<(DeployStage, StageState, String?)> { stageCont = $0 }
        let sc = stageCont!
        let onStage: Deployer.StageReport = { sc.yield(($0, $1, $2)) }
        let stageConsumer = Task { for await e in stageStream { job.report(e.0, e.1, e.2) } }

        do {
            let res = try await Deployer.deploy(app, lane: lane, versionBump: versionBump,
                                                onLog: onLog, onStage: onStage)
            c.finish(); await consumer.value
            sc.finish(); await stageConsumer.value
            job.lines.append("✅ \(app.name) — v\(res.version) (build \(res.build))")
            // 릴리즈노트 반영은 Deployer 밖(Store)에서 도므로 여기서 칸을 옮긴다
            if lane != .check {
                job.report(.notesApply, .running, nil)
                let note = await applyReleaseNotes(app, into: job)   // 언어별 릴리즈노트 자동 반영
                job.report(.notesApply, .done, note)
            } else {
                job.report(.notesApply, .skipped, "check 모드 — 배포 없음")
            }
            return .success(version: res.version, build: res.build)
        } catch {
            c.finish(); await consumer.value
            sc.finish(); await stageConsumer.value
            // 어느 칸에서 멈췄는지 그 자리에 남긴다 — 아직 시작 못 한 칸은 대기로 둔다
            job.progress?.failCurrent(note: (error as? DeployError)?.title ?? error.localizedDescription)
            let msg = error.localizedDescription
            if let de = error as? DeployError {
                job.failure = de
                job.lines.append("❌ \(app.name) · \(de.stage) — \(de.title)")
                for t in de.todo { job.lines.append("   → \(t)") }
                if !de.detail.isEmpty {
                    for line in de.detail.split(separator: "\n") { job.lines.append("   │ \(line)") }
                }
            } else {
                job.lines.append("❌ \(app.name) — \(msg)")
            }
            // 전체 배포에서 알림에 쓸 한 줄은 짧게 (할 일 목록은 창에서 본다)
            return .failure((error as? DeployError).map { "\($0.stage): \($0.title)" } ?? msg)
        }
    }

    // 개별 배포 (원 버튼: 빌드→업로드→언어별 릴리즈노트까지 자동)
    // versionBump nil = 빌드만 올리기, .patch/.minor/.major = 버전 올려 배포
    func startDeploy(_ app: ManagedApp, lane: Deployer.Lane, versionBump: Deployer.VersionBump? = nil) {
        let job = Job(title: "\(laneLabel(lane)) · \(app.name)")
        self.job = job
        Task {
            let outcome = await runOneDeploy(app, lane: lane, versionBump: versionBump, into: job)
            job.running = false
            await refresh(fresh: true)
            switch outcome {
            case .success(let v, let b):
                announce([.init(title: "✅ \(app.name) 업로드 완료",
                                body: "v\(v) (build \(b)) — App Store Connect 에서 빌드를 선택하고 심사에 제출하세요",
                                important: true)])
            case .failure(let m):
                announce([.init(title: "❌ \(app.name) 배포 실패", body: m, important: true)])
            }
        }
    }

    // 전체 배포 — '배포 준비완료' 상태의 앱을 순차로 배포
    func deployAll(lane: Deployer.Lane) {
        // statuses 순서 = 사용자가 정한 배포 순서.
        // 막힌 앱(체크리스트 ❌)과 **심사 중인 앱**은 뺀다 —
        // 심사 중에 새 빌드를 올리면 그 심사가 취소되고 처음부터 다시 시작한다.
        let targets = statuses.filter(\.deployable).compactMap { app(named: $0.path) }
        let inReview = statuses.filter(\.inReview)
        let job = Job(title: "전체 배포 · \(targets.count)개")
        self.job = job
        guard !targets.isEmpty else {
            job.lines.append("배포할 앱이 없습니다 — 막힌 곳 없는 '배포 가능' 앱만 대상입니다.")
            job.lines.append("개발 중이거나 이미 배포된 앱, 체크리스트에 ❌ 가 있는 앱은 제외됩니다.")
            job.running = false
            return
        }
        batchRunning = true
        Task {
            job.lines.append("배포 순서: \(targets.map { $0.name }.joined(separator: " → "))")
            if !inReview.isEmpty {
                job.lines.append("심사 중이라 제외: \(inReview.map { "\($0.name)(\($0.reviewLabel ?? "-"))" }.joined(separator: ", "))")
                job.lines.append("(지금 올리면 그 심사가 취소되고 새 빌드로 다시 시작합니다)")
            }
            job.lines.append("(순서는 대시보드 헤더의 ↑↓ 버튼에서 바꿉니다)")
            var ok = 0
            var fails: [String] = []
            for (i, app) in targets.enumerated() {
                job.lines.append("")
                job.lines.append("━━━━━━ [\(i + 1)/\(targets.count)] \(app.name) ━━━━━━")
                switch await runOneDeploy(app, lane: lane, versionBump: nil, into: job,
                                          batch: (i + 1, targets.count, app.name)) {
                case .success: ok += 1
                case .failure(let m): fails.append("\(app.name): \(m)")
                }
            }
            job.lines.append("")
            job.lines.append("══════ 전체 완료 — 성공 \(ok)/\(targets.count) ══════")
            job.running = false
            batchRunning = false
            await refresh(fresh: true)
            if fails.isEmpty {
                announce([.init(title: "✅ 전체 배포 완료", body: "\(ok)/\(targets.count) 성공", important: true)])
            } else {
                announce([.init(title: "⚠️ 전체 배포 — 실패 \(fails.count)건",
                                body: fails.joined(separator: "\n"), important: true)])
            }
        }
    }
}
