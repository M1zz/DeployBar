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
        // 지난 조회 결과를 디스크에서 즉시 로드 (백그라운드 갱신 전까지 표시)
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([AppStatus].self, from: data) {
            statuses = cached
        }
    }

    // 최초 1회만 조회를 시작한다. 뷰(팝오버)가 닫혀도 취소되지 않도록 별도 Task 로 실행.
    func loadIfNeeded() {
        guard !didStartInitialLoad else { return }
        didStartInitialLoad = true
        Task { await refresh(fresh: false) }
    }

    func refresh(fresh: Bool) async {
        if isRefreshing { return }   // 중복 조회 방지
        isRefreshing = true
        loading = true
        let result = await Status.all(fresh: fresh)
        statuses = result
        loading = false
        isRefreshing = false
        if let data = try? JSONEncoder().encode(result) { try? data.write(to: Self.cacheURL) }
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
