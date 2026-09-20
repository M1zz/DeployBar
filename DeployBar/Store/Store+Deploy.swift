import Foundation

// 배포 실행 — 한 앱 배포, 전체 배포, 커밋 때문에 막힌 앱 풀기.
extension Store {
    /// 전체 배포에서 이 앱이 왜 빠졌나, 한 줄로.
    static func exclusionReason(_ s: AppStatus) -> String {
        if s.inReview { return "\(s.reviewLabel ?? "심사 중") — 올리면 심사가 취소됩니다" }
        if s.state == .loading { return "조회 중" }
        if s.state == .error { return s.error ?? "오류 — 카드의 [왜 안 되나] 를 보세요" }
        if let b = s.readiness.blockers.first {
            let more = s.readiness.blockers.count > 1 ? " 외 \(s.readiness.blockers.count - 1)건" : ""
            return "잠김: \(b.title)\(more)"
        }
        if s.state == .deployed { return "올릴 것 없음 — 로컬이 이미 스토어와 같습니다" }
        return "배포 대상이 아님"
    }

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
            // 게이트에 걸리기 **전에** 빈 릴리즈노트를 채운다.
            //
            // 예전엔 순서가 거꾸로였다. 게이트는 archive 앞에서 막는데, 노트를 채우는
            // applyReleaseNotes 는 업로드가 성공한 뒤에야 돌았다. 그래서 빈 노트로 막히면
            // 채우는 코드에 영원히 도달하지 못하고, 사람이 매 버전마다 손으로
            // [릴리즈노트] 창을 열어 [빈 언어 채우기] → 적용을 눌러야 했다.
            // 닭이 있어야 달걀이 나오는데 달걀이 있어야 닭을 들여보내 주는 구조였다.
            //
            // 이제 배포가 스스로 채우고 나서 게이트 앞에 선다. 채운 뒤에도 비어 있으면
            // 그때는 진짜로 만들 수 없는 것이므로 게이트가 막는 게 맞다.
            if lane != .check {
                job.report(.notesPrefill, .running, nil)
                let note = await applyReleaseNotes(app, into: job, when: "배포 전")
                job.report(.notesPrefill, .done, note)
            } else {
                job.report(.notesPrefill, .skipped, "check 모드")
            }

            let res = try await Deployer.deploy(app, lane: lane, versionBump: versionBump,
                                                onLog: onLog, onStage: onStage)
            c.finish(); await consumer.value
            sc.finish(); await stageConsumer.value
            job.lines.append("✅ \(app.name) — v\(res.version) (build \(res.build))")
            // 배포가 "지금 다시 찍을 때" 로 판정했으면 지시문을 손에 남긴다.
            // 로그에는 이미 전문이 들어갔고, 여기서는 **나중에 꺼낼 수 있게** 들고 있는다 —
            // 전체 배포 중이면 클립보드를 앱마다 덮어쓰면 안 되므로 복사는 부르는 쪽이 정한다.
            if let prompt = res.shotPrompt {
                shotPromptReady[app.path] = prompt
                announce([.init(title: "📸 \(app.name) 스크린샷 다시 찍을 때",
                                body: res.shotReason ?? "화면이 바뀌었습니다",
                                important: false)])
            }
            // 릴리즈노트 반영은 Deployer 밖(Store)에서 도므로 여기서 칸을 옮긴다
            if lane != .check {
                // 업로드 뒤에 한 번 더. 첫 업로드 전에는 편집 가능한 App Store 버전 자체가
                // 없어서 배포 전 채우기가 할 일이 없었기 때문이다 — 그 경우는 여기서 채워진다.
                // 이미 채워진 언어는 건드리지 않으므로(fillEmptyOnly) 두 번 돈다고 덮어쓰지 않는다.
                job.report(.notesApply, .running, nil)
                let note = await applyReleaseNotes(app, into: job, when: "업로드 후")
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
            // 앱 하나만 배포했을 때만 클립보드로 — 전체 배포에서 31번 덮어쓰면 아무 뜻도 없다
            if let prompt = shotPromptReady[app.path] {
                Clipboard.copy(prompt)
                fixResult[app.path] = "📸 스크린샷 지시문을 복사했습니다 — Claude Code 에 붙여넣으세요"
            }
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
        // 빠진 앱은 **하나도 빠짐없이 이유와 함께** 적는다.
        // 예전엔 심사 중인 앱만 적고 잠긴 앱은 조용히 사라져서,
        // "31개를 눌렀는데 22개만 돌았다" 의 이유를 로그에서 찾을 수 없었다.
        let excluded = statuses.filter { !$0.deployable }
        let job = Job(title: "전체 배포 · \(targets.count)개")
        self.job = job
        // 빠진 앱은 대상이 하나도 없을 때 **더더욱** 적어야 한다 —
        // "배포할 앱이 없습니다" 만 남으면 무엇을 풀어야 하는지 알 길이 없다.
        func reportExcluded() {
            guard !excluded.isEmpty else { return }
            job.lines.append("")
            job.lines.append("── 이번에 빠진 앱 \(excluded.count)개 ──")
            for s in excluded { job.lines.append("   · \(s.name) — \(Store.exclusionReason(s))") }
            if excluded.contains(where: \.inReview) {
                job.lines.append("   (심사 중인 앱은 지금 올리면 그 심사가 취소되고 처음부터 다시 시작합니다)")
            }
            if excluded.contains(where: { !$0.inReview && !$0.readiness.blockers.isEmpty }) {
                job.lines.append("   (잠긴 앱은 카드의 ⋯ ▸ [잠긴 채로 그래도 배포] 로 하나씩 밀어붙일 수 있습니다)")
            }
            job.lines.append("")
        }
        guard !targets.isEmpty else {
            job.lines.append("배포할 앱이 없습니다 — 막힌 곳 없는 '배포 가능' 앱만 대상입니다.")
            reportExcluded()
            job.running = false
            return
        }
        batchRunning = true
        Task {
            job.lines.append("배포 순서: \(targets.map { $0.name }.joined(separator: " → "))")
            reportExcluded()
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
