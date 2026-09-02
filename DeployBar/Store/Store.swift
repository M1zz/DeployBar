import SwiftUI

@MainActor
final class Job: ObservableObject {
    let title: String
    @Published var lines: [String] = []
    @Published var running = true
    @Published var error: String?
    /// 마지막 실패를 구조로 들고 있는다 — 로그 창이 '지금 할 일' 을 그릴 수 있도록.
    /// 문자열만 남기면 사람이 수백 줄 로그를 거슬러 올라가 원인을 찾아야 한다.
    @Published var failure: DeployError?
    init(title: String) { self.title = title }
}

@MainActor
final class Store: ObservableObject {
    @Published var statuses: [AppStatus] = []
    @Published var loading = false
    @Published var job: Job?
    /// 루트에 있는데 자동 발견에서 빠진 폴더 (이유 포함)
    @Published var skipped: [AppRepo.Skipped] = []
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
    var notesApp: ManagedApp?                 // Store+ReleaseNotes 가 읽는다

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
    var translationCont: CheckedContinuation<String?, Never>?   // Store+ReleaseNotes
    // 요청 일련번호. 언어가 여러 개면 번역을 연달아 하는데, 지난 요청의 30초 타임아웃이
    // 지금 진행 중인 요청을 nil 로 끝내 버리는 사고를 막는다.
    var translationSeq = 0                    // Store+ReleaseNotes

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

    func persistOrder() {
        AppRepo.reorder(visible: statuses.map { $0.path })
        if let data = try? JSONEncoder().encode(statuses) { try? data.write(to: Self.cacheURL) }
    }

    // 앱을 관리에서 잠시 뺀다 — 목록·배포 대상에서 제외하되 폴더는 그대로 둔다
    func hideApp(_ path: String) {
        guard let st = statuses.first(where: { $0.path == path }) else { return }
        AppRepo.hide(ManagedApp(name: st.name, path: st.path))
        statuses.removeAll { $0.path == path }
        reloadRegistryCache()
        hidden = AppRepo.hiddenApps()
        skipped = AppRepo.skipped()
        if let data = try? JSONEncoder().encode(statuses) { try? data.write(to: Self.cacheURL) }
    }

    // 다시 관리 대상으로 되돌리고 상태를 조회한다
    func unhideApp(_ path: String) {
        AppRepo.unhide(path)
        reloadRegistryCache()
        hidden = AppRepo.hiddenApps()
        skipped = AppRepo.skipped()
        Task { await refresh(fresh: false) }
    }

    // 최초 1회만 조회를 시작한다. 뷰(팝오버)가 닫혀도 취소되지 않도록 별도 Task 로 실행.
    func loadIfNeeded() {
        guard !didStartInitialLoad else { return }
        didStartInitialLoad = true
        Task { await refresh(fresh: false) }
        startWatching()
    }

    /// 창을 안 열어 놔도 심사 결과·출시를 알 수 있게 주기적으로 다시 조회한다.
    /// 사람이 새로고침을 눌러야만 안다면, 기다리는 소식일수록 늦게 안다.
    /// 빌드 설정은 잘 안 바뀌므로 fresh:false — xcodebuild 를 다시 돌리지 않고 ASC 만 다시 본다.
    private func startWatching() {
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 60 * 1_000_000_000)
                guard let self else { return }
                if self.job?.running == true { continue }   // 배포 중에는 건드리지 않는다
                await self.refresh(fresh: false)
            }
        }
    }

    // 앱을 하나씩 조회해 즉시 화면에 반영한다 (전체를 기다리지 않음 → 멈춘 것처럼 안 보임).
    //
    // pull: 원격의 새 커밋을 실제로 받아올지. 사람이 [새로고침] 을 눌렀을 때만 true 다 —
    // 15분마다 도는 자동 조회까지 파일을 바꾸면, Xcode 로 보고 있던 코드가 말없이 달라진다.
    // (pull 여부와 무관하게 fetch 는 늘 한다: 읽기라서 안전하고, 안 하면 원격 상태가 옛것이다)
    func refresh(fresh: Bool, pull: Bool = false) async {
        if isRefreshing { return }   // 중복 조회 방지
        isRefreshing = true
        loading = true
        if fresh { AppRepo.clearCache() }

        fixResult.removeAll()   // 지난 '자동 설정' 결과 메시지는 새로 조회할 때 지운다
        let apps = AppRepo.registry()
        // 새로 생긴 앱도 카드에서 버튼이 뜨도록 경로→앱 캐시를 여기서 갱신한다
        appsByPath = Dictionary(apps.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        skipped = AppRepo.skipped()
        // 기존 값은 유지하고, 처음 보는 앱은 "조회 중"으로 자리부터 잡는다.
        var working: [AppStatus] = apps.map { app in
            statuses.first(where: { $0.path == app.path })
                ?? AppStatus(name: app.name, path: app.path, state: .loading)
        }
        statuses = working

        // 지난 조회와 견주기 위한 스냅샷 (앱별 완료 즉시 갱신되므로 미리 떠 둔다)
        let before = statuses

        // 원격을 먼저 다녀온다. 이게 앞에 와야 ahead/behind 가 옛 값이 아니고,
        // 받아온 커밋이 곧바로 이번 조회의 버전·커밋 수에 반영된다.
        let sync = await GitSync.run(apps, pull: pull)

        for (i, app) in apps.enumerated() {
            let st = await Status.of(app, fresh: fresh, sync: sync[app.path])
            working[i] = st
            statuses = working   // 앱별 완료 즉시 반영
        }
        announce(pullEvents(working) + StatusChange.events(from: before, to: working))

        loading = false
        isRefreshing = false
        if let data = try? JSONEncoder().encode(working) { try? data.write(to: Self.cacheURL) }
    }

    // 앱 하나만 다시 조회한다.
    //
    // 전체 새로고침은 앱 수만큼 xcodebuild 와 ASC 왕복을 도느라 수십 초가 걸린다.
    // 방금 한 앱을 고쳐 놓고 "이제 풀렸나" 를 보려고 나머지 서른 개를 기다릴 이유는 없다.
    // 전체와 같은 순서로 돈다: 원격 → 상태 → 변화 알림. 다른 카드는 건드리지 않는다.
    func refreshApp(_ path: String, fresh: Bool = true, pull: Bool = true) async {
        // 전체 조회가 도는 중이면 그쪽이 곧 이 앱도 덮어쓴다 — 두 번 돌 이유가 없다
        if isRefreshing || refreshingApps.contains(path) { return }
        guard let app = appsByPath[path] else { return }
        refreshingApps.insert(path)
        fixResult[path] = nil          // 지난 '자동 설정' 결과 한 줄은 새로 조회할 때 지운다
        if fresh { AppRepo.clearCache(path) }

        let before = statuses.first(where: { $0.path == path })
        let sync = await GitSync.run([app], pull: pull)
        let st = await Status.of(app, fresh: fresh, sync: sync[path])

        refreshingApps.remove(path)
        if let i = statuses.firstIndex(where: { $0.path == path }) { statuses[i] = st }

        var events = pullEvents([st])
        if let before, let e = StatusChange.event(from: before, to: st) { events.append(e) }
        announce(events)

        if let data = try? JSONEncoder().encode(statuses) { try? data.write(to: Self.cacheURL) }
    }

    /// 지금 혼자 조회 중인 앱들. 카드가 자기 자리에서만 도는 표시를 낼 수 있게.
    /// (전체 조회의 loading 과 달리, 다른 카드의 버튼을 잠그지 않는다)
    @Published var refreshingApps: Set<String> = []

    /// 경로 → 앱. 조회할 때 한 번 만들어 두고 여기서만 읽는다.
    /// (예전엔 부를 때마다 AppRepo.registry() 를 다시 만들어 폴더를 훑고 apps.json 까지 썼다)
    var appsByPath: [String: ManagedApp] = [:]
    func app(named path: String) -> ManagedApp? { appsByPath[path] }

    func reloadRegistryCache() {
        appsByPath = Dictionary(AppRepo.registry().map { ($0.path, $0) },
                                uniquingKeysWith: { a, _ in a })
    }

    // ── 저장 프로퍼티 ──────────────────────────────────────────────────
    // Swift 확장에는 저장 프로퍼티를 둘 수 없어 여기 모은다.
    // 기능별 코드는 Store+Deploy / Store+ReleaseNotes / Store+Scaffold / Store+Fix 에 있다.
    // 카드에 잠깐 띄우는 '자동 설정' 결과 한 줄 (path → 메시지)
    @Published var fixResult: [String: String] = [:]
    @Published var fixing: Set<String> = []

    var didStartInitialLoad = false
    var isRefreshing = false
    static var cacheURL: URL { Config.supportDir.appendingPathComponent("status-cache.json") }

    init() {
        // 지난 조회 결과를 디스크에서 즉시 로드. 없으면 앱 이름만이라도 즉시 표시("조회 중").
        if let data = try? Data(contentsOf: Self.cacheURL),
           let cached = try? JSONDecoder().decode([AppStatus].self, from: data) {
            statuses = cached
        } else {
            statuses = AppRepo.registry().map { AppStatus(name: $0.name, path: $0.path, state: .loading) }
        }
        reloadRegistryCache()
        hidden = AppRepo.hiddenApps()
        skipped = AppRepo.skipped()
        loadNotices()
    }

    /// 원격에서 코드를 받아왔으면 그 사실을 먼저 말한다.
    /// 이 한 줄이 없으면 "어제는 막혀 있던 앱이 왜 갑자기 배포 가능이지" 를 설명할 길이 없다.
    private func pullEvents(_ list: [AppStatus]) -> [StatusChange.Event] {
        list.filter { $0.pulledCommits > 0 }.map {
            StatusChange.Event(title: "\($0.name) 최신 코드 받음",
                               body: "원격 커밋 \($0.pulledCommits)개를 가져왔습니다 (\($0.branch ?? "-"))",
                               kind: .info)
        }
    }

    /// 지난 조회 이후 달라진 것을 콘솔 상단 배너에 올린다.
    /// 시스템 알림은 앱이 뒤에 있을 때를 위한 보조일 뿐, 권한이 없어도 배너는 뜬다.
    func announce(_ events: [StatusChange.Event]) {
        for e in events {
            notices.insert(e, at: 0)
            Notifier.notify(title: e.title, body: e.body)
        }
        if notices.count > 30 { notices.removeLast(notices.count - 30) }
        saveNotices()
    }

    /// 변화 히스토리. 사람이 ✕ 로 지울 때까지 남고, **앱을 껐다 켜도 남는다** —
    /// 메모리에만 두면 재시작 한 번에 "그때 뭐가 풀렸더라" 를 잃는다.
    @Published var notices: [StatusChange.Event] = []

    static var noticesURL: URL { Config.supportDir.appendingPathComponent("changes.json") }

    func loadNotices() {
        guard let d = try? Data(contentsOf: Self.noticesURL),
              let list = try? JSONDecoder().decode([StatusChange.Event].self, from: d) else { return }
        notices = list
    }
    func saveNotices() {
        if let d = try? JSONEncoder().encode(notices) { try? d.write(to: Self.noticesURL) }
    }

    func dismiss(_ id: UUID) { notices.removeAll { $0.id == id }; saveNotices() }
    func dismissAll() { notices.removeAll(); saveNotices() }

    @Published var batchRunning = false

    enum DeployOutcome { case success(version: String, build: Int); case failure(String) }
}
