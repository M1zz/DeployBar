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
    func refresh(fresh: Bool) async {
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
        for (i, app) in apps.enumerated() {
            let st = await Status.of(app, fresh: fresh)
            working[i] = st
            statuses = working   // 앱별 완료 즉시 반영
        }
        announce(StatusChange.events(from: before, to: working))

        loading = false
        isRefreshing = false
        if let data = try? JSONEncoder().encode(working) { try? data.write(to: Self.cacheURL) }
    }

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
    }

    /// 지난 조회 이후 달라진 것을 콘솔 상단 배너에 올린다.
    /// 시스템 알림은 앱이 뒤에 있을 때를 위한 보조일 뿐, 권한이 없어도 배너는 뜬다.
    func announce(_ events: [StatusChange.Event]) {
        for e in events {
            notices.insert(e, at: 0)
            Notifier.notify(title: e.title, body: e.body)
        }
        if notices.count > 12 { notices.removeLast(notices.count - 12) }
    }

    /// 콘솔 상단에 쌓이는 변화 알림. 사람이 닫을 때까지 남는다 — 지나가면 못 본다.
    @Published var notices: [StatusChange.Event] = []

    func dismiss(_ id: UUID) { notices.removeAll { $0.id == id } }
    func dismissAll() { notices.removeAll() }

    @Published var batchRunning = false

    enum DeployOutcome { case success(version: String, build: Int); case failure(String) }
}
