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

    func startDeploy(_ app: ManagedApp, lane: Deployer.Lane) {
        let title: String
        switch lane {
        case .beta: title = "TestFlight · \(app.name)"
        case .appstore: title = "App Store · \(app.name)"
        case .check: title = "게이트 · \(app.name)"
        }
        let job = Job(title: title)
        self.job = job

        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let c = cont!
        let onLog: @Sendable (String) -> Void = { c.yield($0) }

        Task { for await line in stream { job.lines.append(line) } }
        Task {
            do {
                let res = try await Deployer.deploy(app, lane: lane, onLog: onLog)
                job.lines.append("✅ 완료 — v\(res.version) (build \(res.build))")
                c.finish(); job.running = false
                await refresh(fresh: true)
            } catch {
                job.lines.append("❌ 실패: \(error.localizedDescription)")
                job.error = error.localizedDescription
                c.finish(); job.running = false
            }
        }
    }

    func loadNotes(_ app: ManagedApp) async {
        notesApp = app
        notesAppName = app.name
        notesCommits = []; notesKo = ""; notesEn = ""; notesMsg = ""
        notesLoading = true
        let d = await ReleaseNotes.draft(app)
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
