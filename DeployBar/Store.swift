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

    // ── 온디바이스 번역 브리지 (배포 자동 릴리즈노트용; LogView 가 실행) ──
    struct TranslationRequest: Equatable { let text: String; let source: String; let target: String }
    @Published var pendingTranslation: TranslationRequest?
    private var translationCont: CheckedContinuation<String?, Never>?

    func translate(_ text: String, toLanguage lang: String) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            translationCont = cont
            pendingTranslation = TranslationRequest(text: text, source: "ko", target: lang)
            // 안전장치: 번역 뷰가 없거나 지연되면 30초 후 nil 로 진행
            Task { try? await Task.sleep(nanoseconds: 30_000_000_000); fulfillTranslation(nil) }
        }
    }
    func fulfillTranslation(_ result: String?) {
        guard let c = translationCont else { return }
        translationCont = nil
        pendingTranslation = nil
        c.resume(returning: result)
    }

    // 배포 직후 앱의 App Store 언어를 조회해 필요한 언어만 릴리즈노트를 자동 반영
    private func applyReleaseNotes(_ app: ManagedApp, into job: Job) async {
        let st = statuses.first { $0.path == app.path }
        let draft = await ReleaseNotes.draft(app, liveVersion: st?.liveVersion, localVersion: st?.localVersion)
        if draft.ko.isEmpty {
            job.lines.append("📝 릴리즈노트: 반영할 사용자 변경사항 없음 — 건너뜀")
            return
        }
        do {
            guard let target = try await ReleaseNotes.editableVersionAndLocales(app) else {
                job.lines.append("📝 릴리즈노트 보류 — 편집 가능한 App Store 버전이 없습니다. ASC 에서 새 버전을 만든 뒤 [릴리즈노트]로 적용하세요.")
                return
            }
            let names = target.locales.map { $0.locale }.joined(separator: ", ")
            job.lines.append("📝 릴리즈노트 자동 반영 (v\(target.versionString)) — 이 앱 언어: \(names)")
            var en = draft.en   // AI 키가 있으면 이미 채워져 있음
            for loc in target.locales {
                var text = ""
                if loc.locale == "ko" {
                    text = draft.ko
                } else if loc.locale.hasPrefix("en") {
                    if en.isEmpty {
                        job.lines.append("   … 영어 번역 중 (온디바이스)")
                        en = await translate(draft.ko, toLanguage: "en") ?? ""
                    }
                    text = en
                } else {
                    job.lines.append("   – \(loc.locale): 한/영 외 언어, 건너뜀")
                    continue
                }
                guard !text.isEmpty else { job.lines.append("   – \(loc.locale): 내용 없음, 건너뜀"); continue }
                do {
                    try await ASCClient.patchWhatsNew(localizationId: loc.id, whatsNew: text)
                    job.lines.append("   ✓ \(loc.locale) 반영 완료")
                } catch {
                    job.lines.append("   ✗ \(loc.locale) 실패: \(error.localizedDescription)")
                }
            }
        } catch {
            job.lines.append("📝 릴리즈노트 실패: \(error.localizedDescription)")
        }
    }

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

    enum DeployOutcome { case success(version: String, build: Int); case failure(String) }

    // 앱 하나를 배포하고 로그를 job 에 스트리밍. 결과 반환.
    private func runOneDeploy(_ app: ManagedApp, lane: Deployer.Lane, into job: Job) async -> DeployOutcome {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let c = cont!
        let onLog: @Sendable (String) -> Void = { c.yield($0) }
        let consumer = Task { for await line in stream { job.lines.append(line) } }
        do {
            let res = try await Deployer.deploy(app, lane: lane, onLog: onLog)
            c.finish(); await consumer.value
            job.lines.append("✅ \(app.name) — v\(res.version) (build \(res.build))")
            await applyReleaseNotes(app, into: job)   // 언어별 릴리즈노트 자동 반영
            return .success(version: res.version, build: res.build)
        } catch {
            c.finish(); await consumer.value
            let msg = error.localizedDescription
            job.lines.append("❌ \(app.name) — \(msg)")
            return .failure(msg)
        }
    }

    // 개별 배포 (원 버튼: 빌드→업로드→언어별 릴리즈노트까지 자동)
    func startDeploy(_ app: ManagedApp, lane: Deployer.Lane) {
        let job = Job(title: "\(laneLabel(lane)) · \(app.name)")
        self.job = job
        Task {
            let outcome = await runOneDeploy(app, lane: lane, into: job)
            job.running = false
            await refresh(fresh: true)
            switch outcome {
            case .success(let v, let b):
                Notifier.notify(title: "✅ \(app.name) 배포 완료", body: "v\(v) (build \(b))")
            case .failure(let m):
                Notifier.notify(title: "❌ \(app.name) 배포 실패", body: m)
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
            var fails: [String] = []
            for (i, app) in targets.enumerated() {
                job.lines.append("")
                job.lines.append("━━━━━━ [\(i + 1)/\(targets.count)] \(app.name) ━━━━━━")
                switch await runOneDeploy(app, lane: lane, into: job) {
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
                Notifier.notify(title: "✅ 전체 배포 완료", body: "\(ok)/\(targets.count) 성공")
            } else {
                Notifier.notify(title: "⚠️ 전체 배포 — 실패 \(fails.count)건", body: fails.joined(separator: "\n"))
            }
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
