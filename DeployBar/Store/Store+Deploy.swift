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
                      batch: (index: Int, total: Int, name: String)? = nil,
                      deferStore: Bool = false) async -> DeployOutcome {
        job.resetProgress(app: app.name, batch: batch)
        // 어느 DeployBar 로 배포하는지 창에도 남긴다 — 개발용 빌드면 여기서 바로 보이게
        if RunLog.isDevBuild { for line in RunLog.identity { job.lines.append(line) } }

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

            let replaceShots = lane == .appstore && shotRefresh.contains(app.path)
            let res = try await Deployer.deploy(app, lane: lane, versionBump: versionBump,
                                                replaceShots: replaceShots,
                                                onLog: onLog, onStage: onStage)
            c.finish(); await consumer.value
            sc.finish(); await stageConsumer.value
            job.lines.append("✅ \(app.name) — v\(res.version) (build \(res.build))")
            // 배포가 "지금 다시 찍을 때" 로 판정했으면 지시문을 손에 남긴다.
            // 로그에는 이미 전문이 들어갔고, 여기서는 **나중에 꺼낼 수 있게** 들고 있는다 —
            // 전체 배포 중이면 클립보드를 앱마다 덮어쓰면 안 되므로 복사는 부르는 쪽이 정한다.
            // 첫 출시의 사람 몫은 **✕ 로 지울 때까지 남는 배너**로도 알린다.
            // 로그는 창을 닫으면 찾아 들어가야 하는데, 이건 "다음에 할 일" 이라 눈에 남아야 한다.
            if !res.humanTodo.isEmpty {
                humanTodoReady[app.path] = res.humanTodo
                announce([.init(title: "🙋 \(app.name) — 스토어에 내려면 사람이 할 일 \(res.humanTodo.count)가지",
                                body: res.humanTodo.map { $0.components(separatedBy: " — ").first ?? $0 }
                                    .joined(separator: " · ") + " (로그에 자세히 적어 뒀습니다)",
                                important: true)])
            }
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
            // '스크린샷 교체' 를 체크했는데 준비가 덜 됐으면 심사에 내지 않는다.
            // 옛 그림으로 심사가 시작되면 되돌리는 데 심사가 한 번 더 든다. 체크는 남겨 둔다 —
            // 그림을 채우고 다시 누르면 그때 교체된다.
            if let why = res.shotsRefused {
                job.report(.attach, .skipped, "스크린샷 준비 미완")
                job.report(.submit, .skipped, why)
                return .incomplete(version: res.version, build: res.build, reason: why)
            }
            if replaceShots { shotRefresh.remove(app.path) }   // '이번 배포' 한 번만
            // 빌드 연결 → 심사 제출. 애플 처리를 기다리느라 길게는 수십 분 걸린다.
            // 전체 배포는 앱마다 여기서 기다리면 줄 전체가 멈추므로, 업로드를 다 끝낸 뒤 한꺼번에 한다
            // (그사이 앞 앱들의 처리가 끝나 있어서 대개 기다릴 게 없다).
            var storeNote: String?
            if lane != .appstore {
                let why = lane == .check ? "check 모드 — 배포 없음" : "\(laneLabel(lane)) 배포 — 스토어 제출 없음"
                job.report(.attach, .skipped, why)
                job.report(.submit, .skipped, why)
            } else if !deferStore {
                let fin = await finishOnStore(app, version: res.version, build: res.build, into: job)
                storeNote = fin.summary
                if let why = fin.unfinished {
                    return .incomplete(version: res.version, build: res.build, reason: why)
                }
            }
            return .success(version: res.version, build: res.build, store: storeNote)
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

    /// 빌드 연결·심사 제출을 돌리고 칸과 로그를 job 에 흘린다.
    /// runOneDeploy 와 같은 이유로 스트림을 쓴다 — 이벤트마다 Task 를 띄우면 칸이 거꾸로 켜진다.
    func finishOnStore(_ app: ManagedApp, version: String, build: Int, into job: Job) async -> StorePublish.Finish {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let c = cont!
        let consumer = Task { for await line in stream { job.lines.append(line) } }
        var stageCont: AsyncStream<(DeployStage, StageState, String?)>.Continuation!
        let stageStream = AsyncStream<(DeployStage, StageState, String?)> { stageCont = $0 }
        let sc = stageCont!
        let stageConsumer = Task { for await e in stageStream { job.report(e.0, e.1, e.2) } }

        let fin = await StorePublish.finish(app, version: version, build: build,
                                            onLog: { c.yield($0) }, onStage: { sc.yield(($0, $1, $2)) })
        c.finish(); await consumer.value
        sc.finish(); await stageConsumer.value
        if !fin.blockers.isEmpty {
            humanTodoReady[app.path] = fin.blockers
            announce([.init(title: "🙋 \(app.name) — 심사에 내려면 사람이 할 일 \(fin.blockers.count)가지",
                            body: fin.blockers.map { $0.components(separatedBy: " — ").first ?? $0 }
                                .joined(separator: " · "),
                            important: true)])
        }
        return fin
    }

    // 개별 배포 (원 버튼: 빌드→업로드→언어별 릴리즈노트까지 자동)
    // versionBump nil = 빌드만 올리기, .patch/.minor/.major = 버전 올려 배포
    func startDeploy(_ app: ManagedApp, lane: Deployer.Lane, versionBump: Deployer.VersionBump? = nil) {
        let job = Job(title: "\(laneLabel(lane)) · \(app.name)")
        self.job = job
        Task {
            let outcome = await runOneDeploy(app, lane: lane, versionBump: versionBump, into: job)
            // 로그 맨 끝에 한 줄로 판정한다 — 수백 줄을 거슬러 올라가지 않아도 되게.
            // '업로드 완료' 와 '스토어에 냈다' 를 섞지 않는다.
            switch outcome {
            case .success(let v, let b, let store):
                job.verdict = .success(store ?? (lane == .check ? "점검 통과 — 올리지는 않았습니다"
                                                                 : "v\(v) (build \(b)) 업로드 완료"))
            case .incomplete(let v, let b, let why):
                job.verdict = .incomplete("v\(v) (build \(b)) 업로드는 됐지만 심사에 내지 못했습니다 · \(why)")
            case .failure(let m):
                job.verdict = .failed(m)
            }
            if let v = job.verdict {
                job.lines.append("")
                job.lines.append("🏁 결과: \(v.line)")
            }
            job.running = false
            await refresh(fresh: true)
            // 앱 하나만 배포했을 때만 클립보드로 — 전체 배포에서 31번 덮어쓰면 아무 뜻도 없다
            if let prompt = shotPromptReady[app.path] {
                Clipboard.copy(prompt)
                fixResult[app.path] = "📸 스크린샷 지시문을 복사했습니다 — Claude Code 에 붙여넣으세요"
            }
            switch outcome {
            case .success(let v, let b, let store):
                announce([.init(title: "✅ \(app.name) 배포 완료",
                                body: store ?? "v\(v) (build \(b)) 업로드 완료",
                                important: true)])
            case .incomplete(let v, let b, let why):
                announce([.init(title: "⚠️ \(app.name) 배포 미완 — 심사에 내지 못함",
                                body: "v\(v) (build \(b)) 업로드는 됐습니다 · \(why) (로그 끝에 할 일을 적어 뒀습니다)",
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
            var unfinished: [String] = []   // 업로드는 됐지만 심사에 못 낸 앱
            // 업로드가 끝난 앱 — 끝에서 빌드 연결·심사 제출을 이어 한다. 그때 칸을 이어 그리려고 진행 상태도 들고 있는다.
            var uploaded: [(app: ManagedApp, version: String, build: Int, progress: DeployProgress?)] = []
            for (i, app) in targets.enumerated() {
                job.lines.append("")
                job.lines.append("━━━━━━ [\(i + 1)/\(targets.count)] \(app.name) ━━━━━━")
                switch await runOneDeploy(app, lane: lane, versionBump: nil, into: job,
                                          batch: (i + 1, targets.count, app.name),
                                          deferStore: lane == .appstore) {
                case .success(let v, let b, _):
                    ok += 1
                    uploaded.append((app, v, b, job.progress))
                case .incomplete(_, _, let why):   // deferStore 라 여기 오지 않지만, 오면 미완으로 센다
                    ok += 1
                    unfinished.append("\(app.name): \(why)")
                case .failure(let m): fails.append("\(app.name): \(m)")
                }
            }
            var storeLines: [String] = []
            if lane == .appstore, !uploaded.isEmpty {
                job.lines.append("")
                job.lines.append("══════ 빌드 연결 · 심사 제출 — \(uploaded.count)개 ══════")
                for (i, u) in uploaded.enumerated() {
                    job.lines.append("")
                    job.lines.append("━━━━━━ [\(i + 1)/\(uploaded.count)] \(u.app.name) · 스토어 ━━━━━━")
                    // 이 앱의 업로드까지 칸을 되살려 그 뒤를 이어 칠한다
                    job.progress = u.progress
                    job.batch = (i + 1, uploaded.count, u.app.name)
                    let fin = await finishOnStore(u.app, version: u.version, build: u.build, into: job)
                    storeLines.append("\(u.app.name): \(fin.summary)")
                    if let why = fin.unfinished { unfinished.append("\(u.app.name): \(why)") }
                }
            }
            job.lines.append("")
            job.lines.append("══════ 전체 완료 — 업로드 \(ok)/\(targets.count) ══════")
            for l in storeLines { job.lines.append("   · \(l)") }
            let done = ok - unfinished.count
            if !fails.isEmpty {
                job.verdict = .failed("실패 \(fails.count) · 미완 \(unfinished.count) · 완료 \(done) / \(targets.count)")
            } else if !unfinished.isEmpty {
                job.verdict = .incomplete("\(unfinished.count)개 앱이 심사에 못 나갔습니다 · 완료 \(done) / \(targets.count)")
            } else {
                job.verdict = .success("\(done)/\(targets.count)개 앱")
            }
            job.lines.append("")
            job.lines.append("🏁 결과: \(job.verdict!.line)")
            for f in fails { job.lines.append("   ❌ \(f)") }
            for u in unfinished { job.lines.append("   ⚠️ \(u)") }
            job.running = false
            batchRunning = false
            await refresh(fresh: true)
            if fails.isEmpty && !unfinished.isEmpty {
                announce([.init(title: "⚠️ 전체 배포 — 심사에 못 낸 앱 \(unfinished.count)개",
                                body: unfinished.joined(separator: "\n"), important: true)])
            } else if fails.isEmpty {
                announce([.init(title: "✅ 전체 배포 완료",
                                body: "\(ok)/\(targets.count) 성공" + (storeLines.isEmpty ? "" : "\n" + storeLines.joined(separator: "\n")),
                                important: true)])
            } else {
                announce([.init(title: "⚠️ 전체 배포 — 실패 \(fails.count)건",
                                body: fails.joined(separator: "\n"), important: true)])
            }
        }
    }
}
