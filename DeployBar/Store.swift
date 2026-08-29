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
    // 관리에서 잠시 빼둔 앱들
    @Published var hidden: [ManagedApp] = []

    // 릴리즈노트 편집 상태 — 언어 수가 앱마다 다르므로 로케일별 딕셔너리로 다룬다
    @Published var notesAppName = ""
    @Published var notesCommits: [String] = []
    @Published var notesLocales: [String] = []          // 편집 순서 (한국어·영어 먼저)
    @Published var notesTexts: [String: String] = [:]   // ASC 로케일 → 문구
    @Published var notesBase = ""                       // 번역의 출발점이 되는 한국어 원문
    @Published var notesMsg = ""
    @Published var notesLoading = false
    @Published var notesTranslating = false
    private var notesApp: ManagedApp?

    // 한국어 원문 — 편집 화면에서 ko 칸을 고치면 그게 곧 번역 원문이 된다
    var notesKorean: String {
        if let ko = notesLocales.first(where: { Locales.isKorean($0) }), let t = notesTexts[ko], !t.isEmpty { return t }
        return notesBase
    }

    // 배포 성공 후 릴리즈노트 창을 열도록 뷰에 보내는 신호
    @Published var openNotesSignal = 0

    // ── 온디바이스 번역 브리지 (배포 자동 릴리즈노트용; LogView 가 실행) ──
    struct TranslationRequest: Equatable { let text: String; let source: String; let target: String }
    @Published var pendingTranslation: TranslationRequest?
    private var translationCont: CheckedContinuation<String?, Never>?
    // 요청 일련번호. 언어가 여러 개면 번역을 연달아 하는데, 지난 요청의 30초 타임아웃이
    // 지금 진행 중인 요청을 nil 로 끝내 버리는 사고를 막는다.
    private var translationSeq = 0

    func translate(_ text: String, from source: String = "ko", toLanguage lang: String) async -> String? {
        // 온디바이스 번역이 지원하지 않는 언어는 애초에 요청하지 않는다 (30초 대기 낭비 방지)
        guard Locales.supportsOnDeviceTranslation(lang) else { return nil }
        if Locales.sameLanguage(source, lang) { return text }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            translationSeq += 1
            let id = translationSeq
            translationCont = cont
            pendingTranslation = TranslationRequest(text: text,
                                                    source: Locales.language(source),
                                                    target: Locales.language(lang))
            // 안전장치: 번역 뷰가 없거나 지연되면 30초 후 nil 로 진행
            Task { try? await Task.sleep(nanoseconds: 30_000_000_000); fulfillTranslation(nil, id: id) }
        }
    }

    /// id 를 주면 그 요청이 아직 진행 중일 때만 끝낸다 (뷰에서 부를 땐 생략).
    func fulfillTranslation(_ result: String?, id: Int? = nil) {
        if let id, id != translationSeq { return }   // 지난 요청의 타임아웃 — 무시
        guard let c = translationCont else { return }
        translationCont = nil
        pendingTranslation = nil
        c.resume(returning: result)
    }

    /// 비어 있는 로케일을 온디바이스 번역으로 메운다. 같은 언어(en-US/en-GB)는 한 번만 번역해 재사용.
    /// 반환: 채운 texts, 끝내 못 채운 로케일.
    private func fillMissing(_ texts: [String: String], base: String,
                             log: ((String) -> Void)? = nil) async -> (texts: [String: String], failed: [String]) {
        var out = texts
        var failed: [String] = []
        var cache: [String: String] = [:]   // 언어코드 → 번역 결과
        guard !base.isEmpty else { return (out, out.filter { $0.value.isEmpty }.keys.sorted()) }
        for loc in Locales.sorted(out.keys.filter { out[$0]?.isEmpty ?? true }) {
            let lang = Locales.language(loc)
            if let hit = cache[lang] { out[loc] = hit; continue }
            // 이미 채워진 같은 언어의 문구가 있으면 그대로 쓴다 (en-US → en-GB)
            if let sibling = out.first(where: { Locales.sameLanguage($0.key, loc) && !$0.value.isEmpty })?.value {
                out[loc] = sibling; cache[lang] = sibling; continue
            }
            guard Locales.supportsOnDeviceTranslation(loc) else {
                failed.append(loc)
                log?("   – \(loc) (\(Locales.displayName(loc))): 온디바이스 번역 미지원 — 비워 둠")
                continue
            }
            log?("   … \(loc) (\(Locales.displayName(loc))) 번역 중")
            if let t = await translate(base, toLanguage: loc), !t.isEmpty {
                out[loc] = t; cache[lang] = t
            } else {
                failed.append(loc)
                log?("   – \(loc): 번역 실패 — 비워 둠 (설정 › 일반 › 언어에서 번역 다운로드 필요할 수 있음)")
            }
        }
        return (out, failed)
    }

    // 배포 직후 앱의 App Store 언어를 전부 조회해 언어별 릴리즈노트를 자동 반영
    private func applyReleaseNotes(_ app: ManagedApp, into job: Job) async {
        let st = statuses.first { $0.path == app.path }
        do {
            guard let target = try await ReleaseNotes.editableVersionAndLocales(app) else {
                job.lines.append("📝 릴리즈노트 보류 — 편집 가능한 App Store 버전이 없습니다. ASC 에서 새 버전을 만든 뒤 [릴리즈노트]로 적용하세요.")
                return
            }
            let codes = target.localeCodes
            job.lines.append("📝 릴리즈노트 자동 반영 (v\(target.versionString)) — 이 앱 언어 \(codes.count)개: \(codes.joined(separator: ", "))")

            // App Store 가 실제로 요구하는 언어 그대로 초안을 만든다 (AI 키가 있으면 호출 1회로 전부)
            let draft = await ReleaseNotes.draft(app,
                                                 liveVersion: st?.liveVersion,
                                                 localVersion: st?.localVersion,
                                                 locales: codes)
            if draft.base.isEmpty && draft.filled.isEmpty {
                job.lines.append("   반영할 사용자 변경사항 없음 — 건너뜀")
                return
            }
            let (texts, failed) = await fillMissing(draft.texts, base: draft.base) { job.lines.append($0) }
            let result = try await ReleaseNotes.upload(app, texts: texts)
            job.lines.append("   ✓ 반영 완료 \(result.locales.count)/\(codes.count): \(result.locales.joined(separator: ", "))")
            if !result.skipped.isEmpty {
                job.lines.append("   ⚠️ 못 채운 언어 \(result.skipped.count)개: \(result.skipped.joined(separator: ", ")) — [릴리즈노트] 창에서 직접 입력하세요")
            }
            if !failed.isEmpty && result.skipped.isEmpty {
                job.lines.append("   ↳ 번역 실패했지만 같은 언어 문구로 채워진 언어: \(failed.joined(separator: ", "))")
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
        hidden = AppRepo.hiddenApps()
    }

    // ── 배포 순서 ───────────────────────────────────────────────────────
    // statuses 배열의 순서가 곧 화면 순서이자 '전체 배포' 순서다.
    // 화면을 먼저 바꾸고 apps.json 에 반영한다 (조회를 다시 돌리지 않아 즉시 반응).

    func moveApps(from source: IndexSet, to destination: Int) {
        statuses.move(fromOffsets: source, toOffset: destination)
        persistOrder()
    }

    /// 한 칸 위/아래로 (offset: -1 = 위, +1 = 아래)
    func moveApp(_ path: String, by offset: Int) {
        guard let i = statuses.firstIndex(where: { $0.path == path }) else { return }
        let j = i + offset
        guard statuses.indices.contains(j) else { return }
        statuses.swapAt(i, j)
        persistOrder()
    }

    /// 폴더 이름순으로 되돌린다
    func resetOrder() {
        statuses.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        persistOrder()
    }

    private func persistOrder() {
        AppRepo.reorder(visible: statuses.map { $0.path })
        if let data = try? JSONEncoder().encode(statuses) { try? data.write(to: Self.cacheURL) }
    }

    // 앱을 관리에서 잠시 뺀다 — 목록·배포 대상에서 제외하되 폴더는 그대로 둔다
    func hideApp(_ path: String) {
        guard let st = statuses.first(where: { $0.path == path }) else { return }
        AppRepo.hide(ManagedApp(name: st.name, path: st.path))
        statuses.removeAll { $0.path == path }
        hidden = AppRepo.hiddenApps()
        if let data = try? JSONEncoder().encode(statuses) { try? data.write(to: Self.cacheURL) }
    }

    // 다시 관리 대상으로 되돌리고 상태를 조회한다
    func unhideApp(_ path: String) {
        AppRepo.unhide(path)
        hidden = AppRepo.hiddenApps()
        Task { await refresh(fresh: false) }
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

        fixResult.removeAll()   // 지난 '자동 설정' 결과 메시지는 새로 조회할 때 지운다
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
    private func runOneDeploy(_ app: ManagedApp, lane: Deployer.Lane, versionBump: Deployer.VersionBump?, into job: Job) async -> DeployOutcome {
        var cont: AsyncStream<String>.Continuation!
        let stream = AsyncStream<String> { cont = $0 }
        let c = cont!
        let onLog: @Sendable (String) -> Void = { c.yield($0) }
        let consumer = Task { for await line in stream { job.lines.append(line) } }
        do {
            let res = try await Deployer.deploy(app, lane: lane, versionBump: versionBump, onLog: onLog)
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
                Notifier.notify(title: "✅ \(app.name) 배포 완료", body: "v\(v) (build \(b))")
            case .failure(let m):
                Notifier.notify(title: "❌ \(app.name) 배포 실패", body: m)
            }
        }
    }

    // 전체 배포 — '배포 준비완료' 상태의 앱을 순차로 배포
    func deployAll(lane: Deployer.Lane) {
        // statuses 순서 = 사용자가 정한 배포 순서. 막힌 앱(체크리스트 ❌)은 어차피 실패하므로 뺀다.
        let targets = statuses
            .filter { $0.state == .ready && $0.readiness.canDeploy }
            .compactMap { app(named: $0.path) }
        let job = Job(title: "전체 배포 · \(targets.count)개")
        self.job = job
        guard !targets.isEmpty else {
            job.lines.append("배포할 앱이 없습니다 — 막힌 곳 없는 '배포 준비완료' 앱만 대상입니다.")
            job.lines.append("개발 중이거나 이미 배포 완료인 앱, 체크리스트에 ❌ 가 있는 앱은 제외됩니다.")
            job.running = false
            return
        }
        batchRunning = true
        Task {
            job.lines.append("배포 순서: \(targets.map { $0.name }.joined(separator: " → "))")
            job.lines.append("(순서는 대시보드 헤더의 ↑↓ 버튼에서 바꿉니다)")
            var ok = 0
            var fails: [String] = []
            for (i, app) in targets.enumerated() {
                job.lines.append("")
                job.lines.append("━━━━━━ [\(i + 1)/\(targets.count)] \(app.name) ━━━━━━")
                switch await runOneDeploy(app, lane: lane, versionBump: nil, into: job) {
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

    // ── 자동 설정 ("구조 잡기") ─────────────────────────────────────────
    // 카드에 잠깐 띄우는 결과 한 줄 (path → 메시지)
    @Published var fixResult: [String: String] = [:]
    @Published var fixing: Set<String> = []

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
        notesCommits = []; notesLocales = []; notesTexts = [:]; notesBase = ""; notesMsg = ""
        notesLoading = true
        defer { notesLoading = false }
        let st = statuses.first(where: { $0.path == app.path })

        // 편집 대상 언어는 App Store 가 결정한다. 조회에 실패하면 deploy.env/xcstrings 로 대체.
        var codes: [String] = []
        var header = ""
        do {
            if let target = try await ReleaseNotes.editableVersionAndLocales(app) {
                codes = target.localeCodes
                header = "App Store v\(target.versionString) · \(codes.count)개 언어"
            } else {
                header = "⚠️ 편집 가능한 App Store 버전이 없습니다 — 초안만 작성해 두고, 새 버전을 만든 뒤 업로드하세요."
            }
        } catch {
            header = "⚠️ App Store 언어 조회 실패(\(error.localizedDescription)) — 프로젝트 설정 기준으로 표시합니다"
        }
        if codes.isEmpty { codes = fallbackLocales(app) }

        let d = await ReleaseNotes.draft(app, liveVersion: st?.liveVersion, localVersion: st?.localVersion, locales: codes)
        notesCommits = d.commits
        notesLocales = Locales.sorted(codes)
        notesTexts = d.texts
        notesBase = d.base
        notesMsg = [header, d.note].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    // App Store 조회가 안 될 때 쓰는 언어 목록: deploy.env 의 LOCALES → .xcstrings 언어 → ko/en
    private func fallbackLocales(_ app: ManagedApp) -> [String] {
        let r = AppRepo.resolve(app)
        if !r.locales.isEmpty { return r.locales }
        let scan = Localization.scan(app.path)
        if !scan.locales.isEmpty { return scan.locales }
        return ["ko", "en-US"]
    }

    // 비어 있는 언어를 온디바이스 번역으로 한 번에 채운다 (릴리즈노트 창의 [빈 언어 채우기])
    func fillNotesGaps() async {
        guard !notesTranslating else { return }
        notesTranslating = true
        defer { notesTranslating = false }
        let base = notesKorean
        guard !base.isEmpty else { notesMsg = "한국어 문구를 먼저 채워 주세요 — 번역의 출발점입니다."; return }
        var seed = notesTexts
        for loc in notesLocales where seed[loc] == nil { seed[loc] = "" }
        let (filled, failed) = await fillMissing(seed, base: base)
        notesTexts = filled
        notesMsg = failed.isEmpty
            ? "✅ 빈 언어를 모두 채웠습니다 — 내용을 확인하고 업로드하세요."
            : "⚠️ 못 채운 언어: \(failed.joined(separator: ", ")) — 직접 입력이 필요합니다."
    }

    func uploadNotes() async {
        guard let app = notesApp else { return }
        let empty = notesLocales.filter { (notesTexts[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        notesMsg = "업로드 중…"
        do {
            let r = try await ReleaseNotes.upload(app, texts: notesTexts)
            var msg = "✅ v\(r.version) 업데이트 \(r.locales.count)개: \(r.locales.joined(separator: ", "))"
            if !r.skipped.isEmpty { msg += " · 건너뜀: \(r.skipped.joined(separator: ", "))" }
            else if !empty.isEmpty { msg += " · 빈 언어 \(empty.count)개는 기존 문구 유지" }
            notesMsg = msg
        } catch {
            notesMsg = "오류: \(error.localizedDescription)"
        }
    }
}
