import Foundation

// 스토어 페이지 쪽 동작 — 빌드 연결 · 문구/그림 올리기 · 심사 제출 · 출시.
//
// 배포(Store+Deploy)가 바이너리를 올린다면 이쪽은 그 뒤를 잇는다.
// 로그는 같은 Job 창에 남는다 — 사람이 "방금 뭐가 올라갔지" 를 한 곳에서 본다.
extension Store {

    /// 체크리스트의 [스토어 올리기] · ⋯ 메뉴의 '스토어 페이지 올리기'.
    func publishStore(_ app: ManagedApp, options: StorePublish.Options = StorePublish.Options()) {
        let job = Job(title: (options.dryRun ? "스토어 미리보기 · " : "스토어 올리기 · ") + app.name)
        self.job = job
        Task {
            job.lines.append("레포의 APPSTORE.md · docs/screenshots 를 App Store Connect 에 반영합니다")
            if options.dryRun { job.lines.append("(미리보기 — 아무것도 쓰지 않습니다)") }
            do {
                let report = try await StorePublish.run(app, options: options) { line in
                    Task { @MainActor in job.lines.append(line) }
                }
                Store.write(report, into: job)
                job.running = false
                await refresh(fresh: false)
                let head = report.changed.first ?? (report.changed.isEmpty ? "바꿀 것이 없었습니다" : "")
                fixResult[app.path] = report.changed.count > 1
                    ? "스토어 반영 \(report.changed.count)건 — \(head) 외"
                    : head
            } catch let e as DeployError {
                job.failure = e
                job.error = e.title
                job.lines.append("")
                job.lines.append("❌ \(e.stage) — \(e.title)")
                for t in e.todo { job.lines.append("   → \(t)") }
                if !e.detail.isEmpty { job.lines.append("   \(e.detail)") }
                job.running = false
            } catch {
                job.error = error.localizedDescription
                job.lines.append("❌ \(error.localizedDescription)")
                job.running = false
            }
        }
    }

    /// 체크리스트의 [빌드 연결] — 올라간 빌드를 App Store 버전에 건다.
    func attachBuild(_ app: ManagedApp) async {
        guard !fixing.contains(app.path) else { return }
        fixing.insert(app.path)
        defer { fixing.remove(app.path) }
        do {
            let msg = try await StorePublish.attachBuild(app)
            await refresh(fresh: false)
            fixResult[app.path] = msg
        } catch let e as DeployError {
            await refresh(fresh: false)
            fixResult[app.path] = "\(e.title)"
        } catch {
            await refresh(fresh: false)
            fixResult[app.path] = error.localizedDescription
        }
    }

    /// 심사 제출. **여기서부터 애플이 본다** — 메뉴에서 한 번 더 확인하고 부른다.
    func submitForReview(_ app: ManagedApp) {
        let job = Job(title: "심사 제출 · \(app.name)")
        self.job = job
        Task {
            do {
                let msg = try await StorePublish.submit(app) { line in
                    Task { @MainActor in job.lines.append(line) }
                }
                job.lines.append("")
                job.lines.append("✅ \(msg)")
                job.running = false
                await refresh(fresh: false)
                announce([.init(title: "📮 \(app.name) 심사 제출됨", body: msg, important: true)])
            } catch let e as DeployError {
                job.failure = e
                job.error = e.title
                job.lines.append("❌ \(e.title)")
                for t in e.todo { job.lines.append("   → \(t)") }
                job.running = false
            } catch {
                job.error = error.localizedDescription
                job.lines.append("❌ \(error.localizedDescription)")
                job.running = false
            }
        }
    }

    /// '출시 대기' 를 실제 출시로 — 웹의 [출시] 버튼과 같은 일.
    func releaseApp(_ app: ManagedApp) {
        Task {
            do {
                let msg = try await StorePublish.release(app)
                await refresh(fresh: false)
                fixResult[app.path] = msg
                announce([.init(title: "🚀 \(app.name) 출시 요청", body: msg, important: true)])
            } catch let e as DeployError {
                fixResult[app.path] = e.title
            } catch {
                fixResult[app.path] = error.localizedDescription
            }
        }
    }

    /// 결과를 로그 창에 한 덩어리로. 바꾼 것 / 그대로 둔 것 / 사람이 해야 할 것을 나눠 적는다 —
    /// "올렸다" 만 남기면 무엇이 안 올라갔는지는 웹에 가서야 알게 된다.
    static func write(_ report: StorePublish.Report, into job: Job) {
        job.lines.append("")
        if !report.version.isEmpty { job.lines.append("── v\(report.version) ──") }
        if report.changed.isEmpty {
            job.lines.append("바꾼 것 없음 — 스토어가 이미 레포와 같습니다")
        } else {
            job.lines.append("✅ 바꾼 것 \(report.changed.count)건")
            for c in report.changed { job.lines.append("   · \(c)") }
        }
        if !report.kept.isEmpty {
            job.lines.append("")
            job.lines.append("그대로 둔 것 \(report.kept.count)건 (덮어쓰려면 '덮어쓰기' 로 다시 누르세요)")
            for k in report.kept { job.lines.append("   · \(k)") }
        }
        if !report.warnings.isEmpty {
            job.lines.append("")
            job.lines.append("⚠️  하려다 못 한 것 \(report.warnings.count)건")
            for w in report.warnings { job.lines.append("   · \(w)") }
        }
        if !report.manual.isEmpty {
            job.lines.append("")
            job.lines.append("🙋 사람이 웹에서 해야 하는 것 \(report.manual.count)건")
            for m in report.manual { job.lines.append("   · \(m)") }
        }
    }
}
