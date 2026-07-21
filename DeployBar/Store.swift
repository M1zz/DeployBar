import SwiftUI

@MainActor
final class Job: ObservableObject {
    let title: String
    @Published var lines: [String] = []
    @Published var running = true
    @Published var error: String?
    init(title: String) { self.title = title }
}

@MainActor
final class Store: ObservableObject {
    @Published var statuses: [AppStatus] = []
    @Published var loading = false
    @Published var job: Job?

    // 릴리즈노트 편집 상태
    @Published var notesAppName = ""
    @Published var notesCommits: [String] = []
    @Published var notesKo = ""
    @Published var notesEn = ""
    @Published var notesMsg = ""
    @Published var notesLoading = false
    private var notesApp: ManagedApp?

    // 배포 성공 후 릴리즈노트 창을 열도록 뷰에 보내는 신호
    @Published var openNotesSignal = 0

    private var didStartInitialLoad = false
    private var isRefreshing = false
    private static var cacheURL: URL { Config.supportDir.appendingPathComponent("status-cache.json") }

    init() {
        // 지난 조회 결과를 디스크에서 즉시 로드. 없으면 앱 이름만이라도 즉시 표시("조회 중").
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([AppStatus].self, from: data) {
            statuses = cached
        } else {
            statuses = AppRepo.registry().map { AppStatus(name: $0.name, path: $0.path, state: .loading) }
        }
    }

    // 최초 1회만 조회를 시작한다. 뷰(팝오버)가 닫혀도 취소되지 않도록 별도 Task 로 실행.
    func loadIfNeeded() {
        guard !didStartInitialLoad else { return }
        didStartInitialLoad = true
        Task { await refresh(fresh: false) }
    }

    // 앱을 하나씩 조회해 즉시 화면에 반영한다 (전체를 기다리지 않음 → 멈춘 것처럼 안 보임).
    func refresh(fresh: Bool) async {
        if isRefreshing { return }   // 중복 조회 방지
        isRefreshing = true
        loading = true
        if fresh { AppRepo.clearCache() }

        let apps = AppRepo.registry()
        // 기존 값은 유지하고, 처음 보는 앱은 "조회 중"으로 자리부터 잡는다.
        var working: [AppStatus] = apps.map { app in
            statuses.first(where: { $0.path == app.path })
                ?? AppStatus(name: app.name, path: app.path, state: .loading)
        }
        statuses = working

        for (i, app) in apps.enumerated() {
            let st = await Status.of(app, fresh: fresh)
            working[i] = st
            statuses = working   // 앱별 완료 즉시 반영
        }

        loading = false
        isRefreshing = false
        if let data = try? JSONEncoder().encode(working) { try? data.write(to: Self.cacheURL) }
    }

    func app(named path: String) -> ManagedApp? {
        AppRepo.registry().first { $0.path == path }
    }

    @Published var batchRunning = false

    // 앱 하나를 배포하고 로그를 job 에 스트리밍. 성공 여부 반환.
    private func runOneDeploy(_ app: ManagedApp, lane: Deployer.Lane, into job: Job) async -> Bool {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let c = cont!
        let onLog: @Sendable (String) -> Void = { c.yield($0) }
        let consumer = Task { for await line in stream { job.lines.append(line) } }
        do {
            let res = try await Deployer.deploy(app, lane: lane, onLog: onLog)
            c.finish(); await consumer.value
            job.lines.append("✅ \(app.name) — v\(res.version) (build \(res.build))")
            return true
        } catch {
            c.finish(); await consumer.value
            job.lines.append("❌ \(app.name) — \(error.localizedDescription)")
            return false
        }
    }

    // 개별 배포
    func startDeploy(_ app: ManagedApp, lane: Deployer.Lane) {
        let job = Job(title: "\(laneLabel(lane)) · \(app.name)")
        self.job = job
        Task {
            let ok = await runOneDeploy(app, lane: lane, into: job)
            job.running = false
            await refresh(fresh: true)
            if ok {   // 배포 성공 시 릴리즈노트 초안 준비 + 창 열기
                await loadNotes(app)
                openNotesSignal += 1
            }
        }
    }

    // 전체 배포 — '배포 준비완료' 상태의 앱을 순차로 배포
    func deployAll(lane: Deployer.Lane) {
        let targets = statuses.filter { $0.state == .ready }.compactMap { app(named: $0.path) }
        let job = Job(title: "전체 배포 · \(targets.count)개")
        self.job = job
        guard !targets.isEmpty else {
            job.lines.append("배포할 앱이 없습니다 — '배포 준비완료'(🟡) 상태인 앱만 대상입니다.")
            job.lines.append("개발 중(⚪️)이거나 이미 배포 완료(🟢)인 앱은 제외됩니다.")
            job.running = false
            return
        }
        batchRunning = true
        Task {
            var ok = 0
            for (i, app) in targets.enumerated() {
                job.lines.append("")
                job.lines.append("━━━━━━ [\(i + 1)/\(targets.count)] \(app.name) ━━━━━━")
                if await runOneDeploy(app, lane: lane, into: job) { ok += 1 }
            }
            job.lines.append("")
            job.lines.append("══════ 전체 완료 — 성공 \(ok)/\(targets.count) ══════")
            job.running = false
            batchRunning = false
            await refresh(fresh: true)
        }
    }

    private func laneLabel(_ lane: Deployer.Lane) -> String {
        switch lane {
        case .beta: return "TestFlight"
        case .appstore: return "App Store"
        case .check: return "게이트"
        }
    }

    func loadNotes(_ app: ManagedApp) async {
        notesApp = app
        notesAppName = app.name
        notesCommits = []; notesKo = ""; notesEn = ""; notesMsg = ""
        notesLoading = true
        let st = statuses.first(where: { $0.path == app.path })
        let d = await ReleaseNotes.draft(app, liveVersion: st?.liveVersion, localVersion: st?.localVersion)
        notesCommits = d.commits
        notesKo = d.ko
        notesEn = d.en
        notesMsg = d.note ?? ""
        notesLoading = false
    }

    func uploadNotes() async {
        guard let app = notesApp else { return }
        notesMsg = "업로드 중…"
        do {
            let r = try await ReleaseNotes.upload(app, ko: notesKo, en: notesEn)
            notesMsg = "✅ v\(r.version) 업데이트: \(r.locales.joined(separator: ", "))"
        } catch {
            notesMsg = "오류: \(error.localizedDescription)"
        }
    }
}
