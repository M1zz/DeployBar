import Foundation

// 배포 준비 — "버튼 한 번으로 심사까지 가려면 레포에 무엇이 다 있어야 하나" 의 기준과 검사.
//
// 해결 프롬프트(Readiness.promptText)는 **지금 막힌 것**만 다룬다. 그래서 막히지는 않지만
// 품질이 떨어지는 것 — 독일어 페이지에 한국어 이름, 영어 그림을 쓰는 일본어 페이지, 빈 프로모션 텍스트 —
// 은 아무도 말하지 않은 채 스토어에 나갔다. 서비스로 내는 앱이라 그건 막힘과 같은 무게다.
//
// 여기서는 기준을 한 곳에 적고(`standard`), 앱마다 그 기준에서 빠진 것을 찾고(`audit`),
// 둘을 Claude Code 에 붙여넣을 지시문으로 묶는다(`prompt`). 사용자 CLAUDE.md 의
// "배포 준비" 규칙이 `DeployBar --prepare <앱>` 를 부르므로, 기준을 바꿀 곳은 여기 하나다.
enum DeployPrep {

    struct Gap: Codable, Hashable {
        var area: String     // 설정 · 다국어 · 스토어 문구 · 릴리즈노트 · 스크린샷 · 헤더·검색 결과 · 심사 · 저장소
        var text: String
        /// 사람만 할 수 있는 일(애플에 하는 신고·웹에서만 되는 설정) — Claude 는 하지 말고 알려야 한다
        var human = false
        /// 이 빈 곳이 걸린 언어. 카드의 국기가 언어마다 무엇이 남았는지 말하고,
        /// 새 언어 하나만 채우는 지시문(`--prepare 앱 --lang fr`)이 이 값으로 고른다. nil = 언어와 무관.
        var locales: [String]? = nil
    }

    struct Audit {
        var version: String = ""
        var locales: [String] = []
        var gaps: [Gap] = []
        /// 빈 곳은 아니지만 알아 둘 것 (예: 다음 버전에 들어갈 변경이 아직 없음)
        var notes: [String] = []
        var hasWatch = false
        var hasPad = false
        var ready: Bool { gaps.isEmpty }
    }

    static let cli = "/Applications/DeployBar.app/Contents/MacOS/DeployBar"

    /// 새로고침이 이미 아는 것. 이걸 주면 audit 가 스토어를 다시 묻지 않고, URL 을 열어 보지도 않는다.
    /// 앱 서른 개를 돌 때마다 요청이 수십 개씩 늘면 새로고침이 느려지기 때문이다.
    /// (URL 이 열리는지는 `--prepare` 와 [배포 준비 지시문 복사] 가 본다.)
    struct Known {
        var version: String
        var released: Bool
    }

    // ── 검사 ────────────────────────────────────────────────────────────
    static func audit(_ app: ManagedApp, known: Known? = nil) async -> Audit {
        var a = Audit()
        let r = AppRepo.resolve(app)
        func gap(_ area: String, _ text: String, human: Bool = false, _ locales: [String]? = nil) {
            a.gaps.append(Gap(area: area, text: text, human: human, locales: locales))
        }
        guard r.exists else { gap("설정", "Xcode 프로젝트를 찾지 못했습니다"); return a }
        let info = try? AppRepo.buildSettings(r)
        let pbx = projectText(app.path)
        a.hasWatch = pbx.contains("SDKROOT = watchos")
        // 본체 타깃을 **iOS SDK 로** 본다. 그냥 읽으면 Catalyst 앱은 Mac 쪽 조건부 값("2,6")이 나와
        // 아이폰 전용 앱도 아이패드 지원으로 잡힌다 (두번알림이 그랬다).
        a.hasPad = info?.platform != .macOS && iosFamily(r, bundleId: info?.bundleId).contains("2")

        // 1) 설정
        let envPath = (app.path as NSString).appendingPathComponent("deploy.env")
        let env = Config.loadEnv(URL(fileURLWithPath: envPath))
        if !FileManager.default.fileExists(atPath: envPath) {
            gap("설정", "deploy.env 가 없습니다 — `\(cli) --template \(app.name) --write` 로 만들고 LOCALES 를 채우세요")
        } else {
            for k in ["SCHEME", "LOCALES", "PREDEPLOY_SCRIPT"] where (env[k] ?? "").isEmpty {
                gap("설정", "deploy.env 에 \(k) 가 비어 있습니다")
            }
        }
        let scan = Localization.scan(app.path, expected: r.locales)
        let appLangs = scan.locales
        a.locales = Locales.sorted(r.locales.isEmpty ? appLangs : r.locales)
        let undeclared = appLangs.filter { l in !r.locales.contains { Locales.sameLanguage($0, l) } }
        if !r.locales.isEmpty, !undeclared.isEmpty {
            gap("설정", "앱은 \(undeclared.joined(separator: ", ")) 로도 번역돼 있는데 deploy.env 의 LOCALES 에 없습니다 — 스토어 페이지도 그 언어로 내야 합니다", undeclared)
        }

        // 2) 앱 안의 번역
        if !scan.issues.isEmpty {
            gap("다국어", "앱 문자열 번역 구멍 \(scan.issues.count)개 (예: \(scan.issues.first!.line)) — `\(cli) --doctor \(app.name)` 로 전체를 보세요",
                Array(Set(scan.issues.map(\.locale))).sorted())
        }

        // 3) 스토어 문구 — 언어마다 모든 칸, 그 언어로, 한도 안에서
        let meta = StoreMeta.read(app.path, locales: a.locales)
        if meta == nil { gap("스토어 문구", "APPSTORE.md 가 없습니다 — `\(cli) --storemeta \(app.name) --write` 로 뼈대를 만드세요", a.locales) }
        for loc in a.locales {
            let e = meta?.entries.first { Locales.sameLanguage($0.key, loc) }?.value
            let name = Locales.displayName(loc)
            let fields: [(String, String?)] = [("이름", e?.name), ("부제", e?.subtitle), ("키워드", e?.keywords),
                                                ("프로모션 텍스트", e?.promotionalText), ("설명", e?.description),
                                                ("지원 URL", e?.supportUrl), ("개인정보처리방침 URL", e?.privacyPolicyUrl)]
            let missing = fields.filter { ($0.1 ?? "").isEmpty }.map(\.0)
            if !missing.isEmpty { gap("스토어 문구", "\(name) — \(missing.joined(separator: "·")) 없음", [loc]) }
            if let e {
                for p in StoreMeta.problems(loc, e) { gap("스토어 문구", p, [loc]) }
                if !Locales.isKorean(loc) {
                    let text = [e.name, e.subtitle, e.keywords, e.promotionalText, e.description].compactMap { $0 }.joined()
                    if text.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
                        gap("스토어 문구", "\(name) 문구에 한글이 섞여 있습니다 — 그 언어로 다시 써야 합니다", [loc])
                    }
                }
                if let k = e.keywords, let n = e.name {
                    let nameWords = Set(n.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
                    let dup = k.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { nameWords.contains($0) }
                    if !dup.isEmpty { gap("스토어 문구", "\(name) 키워드가 이름의 단어를 반복합니다(\(dup.joined(separator: ", "))) — 애플은 이름을 이미 검색에 넣으니 자리 낭비입니다", [loc]) }
                }
            }
        }

        // 4) 릴리즈노트 — 배포가 쓸 번호의 절에, 모든 언어
        let store: (version: String, released: Bool)
        if let known { store = (known.version, known.released) }
        else { store = await storeState(bundleId: info?.bundleId, local: info?.marketingVersion ?? "?") }
        a.version = store.version
        let notes = RepoNotes.read(app.path, version: a.version, locales: a.locales)?.texts ?? [:]
        let noNotes = a.locales.filter { l in !notes.keys.contains { Locales.sameLanguage($0, l) } }
        // 직전 배포 이후 커밋이 하나도 없으면 다음 버전에 쓸 내용이 없다 — 지금 쓰면 지어낸 글이다.
        let lastDeploy = GitInfo.isRepo(app.path) ? GitInfo.lastDeployTag(app.path) : nil
        let nothingNew = lastDeploy != nil && GitInfo.commitsSince(app.path, tag: lastDeploy).isEmpty
        if !noNotes.isEmpty && nothingNew {
            a.notes.append("v\(a.version) 릴리즈노트는 아직 쓸 내용이 없습니다 — 직전 배포(\(lastDeploy!)) 이후 커밋이 없습니다. 변경을 만든 뒤 쓰세요")
        } else if !noNotes.isEmpty {
            gap("릴리즈노트", "RELEASE_NOTES.md 의 `## \(a.version)` 에 \(noNotes.map { Locales.displayName($0) }.joined(separator: ", ")) 이(가) 없습니다", noNotes)
        }

        // 5) 스크린샷 — 언어마다, 기기마다, 규격대로
        if let rep = StorePublish.shotReport(app.path, platform: info?.platform ?? .iOS, locales: a.locales) {
            if !rep.hasPrimary { gap("스크린샷", "\(info?.platform == .macOS ? "Mac" : "아이폰") 제출 규격 그림이 없습니다") }
            if !rep.missingLocales.isEmpty {
                gap("스크린샷", "그림 없는 언어: \(rep.missingLocales.map { Locales.displayName($0) }.joined(separator: ", "))", rep.missingLocales)
            }
            for s in rep.skipped.prefix(3) { gap("스크린샷", s) }
            let plan = StorePublish.shotPlan(app.path, platform: info?.platform ?? .iOS, locales: a.locales)
            func covered(_ family: String) -> [String] {
                a.locales.filter { loc in
                    !plan.rows.contains { ($0.locale == "모든 언어" || Locales.sameLanguage($0.locale, loc))
                        && StorePublish.deviceFamily($0.type) == family }
                }
            }
            if a.hasWatch, !covered("Watch").isEmpty {
                gap("스크린샷", "워치 앱이 있는데 워치 그림이 없는 언어: \(covered("Watch").map { Locales.displayName($0) }.joined(separator: ", ")) (416×496)", covered("Watch"))
            }
            if a.hasPad, !covered("iPad").isEmpty {
                gap("스크린샷", "아이패드를 지원하는데 아이패드 그림이 없는 언어: \(covered("iPad").map { Locales.displayName($0) }.joined(separator: ", ")) (2064×2752)", covered("iPad"))
            }
            if a.locales.count > 1, plan.rows.allSatisfy({ $0.locale == "모든 언어" }) {
                gap("스크린샷", "모든 언어에 같은 그림 한 벌을 씁니다 — 언어마다 그 언어 화면으로 찍어야 합니다 (marketing/<언어>/)")
            }
        } else {
            gap("스크린샷", "docs/screenshots/ 가 없습니다", a.locales)
        }

        // 5-1) 헤더 · 검색 결과 — iOS·iPadOS 27 의 크리에이티브 자산. 스크린샷과 같은 무게로 언어마다 있어야 한다.
        //      업로드와 같은 함수(creativePlan · creativesFor)로 판단한다. 규격은 내장 사본이라 네트워크를 쓰지 않는다
        if info?.platform != .macOS {
            let rows = await StorePublish.creativePlan(app.path, locales: a.locales)
            if rows.isEmpty {
                gap("헤더·검색 결과", "\(StorePublish.canonicalCreativeDir)/ 가 없습니다 — 헤더(3840×1646)·검색 결과(3840×2560)를 언어마다 만드세요", a.locales)
            } else {
                var byLocale: [String: [StorePublish.CreativeFile]] = [:]
                for row in rows { byLocale[row.locale, default: []].append(row.file) }
                for type in ASCClient.creativeTypes {
                    let missing = a.locales.filter { StorePublish.creativesFor($0, resolved: byLocale).byType[type] == nil }
                    if !missing.isEmpty {
                        gap("헤더·검색 결과", "\(StorePublish.creativeLabel(type)) 없는 언어: \(missing.map { Locales.displayName($0) }.joined(separator: ", "))", missing)
                    }
                }
                for row in rows.filter({ $0.file.problem != nil }).prefix(3) {
                    gap("헤더·검색 결과", "\(row.locale.isEmpty ? "" : row.locale + "/")\(row.file.file.lastPathComponent) 는 올라가지 않습니다: \(row.file.problem!)",
                        row.locale.isEmpty ? nil : [row.locale])
                }
            }
        }

        // 6) 심사 — 사람의 신고가 필요한 것
        if r.encryptionExempt == nil {
            gap("심사", "수출 규정(암호화) 답이 없습니다 — 운영체제 암호화만 쓰는지 사람이 확인해야 합니다", human: true)
        }
        // 연령 등급은 한 번 답하면 다음 버전에 따라간다 — 아직 출시 전인 앱만 묻는다
        if !store.released, meta?.ageRatingNone != true {
            gap("심사", "연령 등급 — 내용 문항이 전부 '해당 없음' 인지 사람이 확인해 APPSTORE.md `## 연령 등급` 에 적거나 웹에서 답해야 합니다", human: true)
        }

        // 7) URL 이 실제로 열리나 — 심사자가 누른다
        var urls = Set<String>()
        for e in (meta?.entries.values).map(Array.init) ?? [] {
            if let u = e.supportUrl { urls.insert(u) }
            if let u = e.privacyPolicyUrl { urls.insert(u) }
        }
        for u in urls.sorted() where known == nil {
            guard !(await reachable(u)) else { continue }
            gap("스토어 문구", "열리지 않는 URL: \(u)")
        }

        // 8) 저장소
        if GitInfo.isRepo(app.path), GitInfo.isDirty(app.path) {
            gap("저장소", "커밋 안 된 변경 \(GitInfo.dirtyFiles(app.path).count)개 — 배포가 '개발 중' 으로 잠깁니다")
        }
        return a
    }

    /// xcodebuild 한 번이 몇 초라 새로고침마다 부르면 안 된다. 프로젝트 파일이 그대로면 답도 그대로다.
    private static let familyCache = FamilyCache()
    private final class FamilyCache: @unchecked Sendable {
        private var map: [String: (Date, [String])] = [:]
        private let lock = NSLock()
        func get(_ k: String, _ d: Date) -> [String]? { lock.lock(); defer { lock.unlock() }; return map[k].flatMap { $0.0 == d ? $0.1 : nil } }
        func set(_ k: String, _ d: Date, _ v: [String]) { lock.lock(); defer { lock.unlock() }; map[k] = (d, v) }
    }

    /// iOS SDK 기준 본체의 TARGETED_DEVICE_FAMILY 숫자들 ("1,2" → ["1","2"]).
    private static func iosFamily(_ r: ResolvedApp, bundleId: String?) -> [String] {
        let stamp = projectStamp(r.path)
        if let stamp, let hit = familyCache.get(r.path, stamp) { return hit }
        let family = readFamily(r, bundleId: bundleId)
        if let stamp, !family.isEmpty { familyCache.set(r.path, stamp, family) }
        return family
    }

    private static func projectStamp(_ root: String) -> Date? {
        guard let proj = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .first(where: { $0.hasSuffix(".xcodeproj") }) else { return nil }
        let p = (root as NSString).appendingPathComponent("\(proj)/project.pbxproj")
        return (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
    }

    private static func readFamily(_ r: ResolvedApp, bundleId: String?) -> [String] {
        guard let out = try? Shell.capture("/usr/bin/xcodebuild", [
            "-showBuildSettings", "-json", r.projFlag, r.projContainer,
            "-scheme", r.scheme, "-configuration", "Release", "-sdk", "iphoneos",
        ], cwd: URL(fileURLWithPath: r.path), timeout: 90),
              let arr = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] else { return [] }
        let settings = arr.compactMap { $0["buildSettings"] as? [String: Any] }
        let main = settings.first { $0["PRODUCT_BUNDLE_IDENTIFIER"] as? String == bundleId } ?? settings.first
        return ((main?["TARGETED_DEVICE_FAMILY"] as? String) ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func projectText(_ root: String) -> String {
        guard let proj = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .first(where: { $0.hasSuffix(".xcodeproj") }) else { return "" }
        let p = (root as NSString).appendingPathComponent("\(proj)/project.pbxproj")
        return (try? String(contentsOfFile: p, encoding: .utf8)) ?? ""
    }

    /// 배포가 쓸 번호(배포와 같은 규칙)와 이미 출시된 적이 있는지. 못 물어보면 로컬 번호 · 출시됨으로 둔다
    /// (출시 여부를 모를 때 연령 등급을 묻지 않는다 — 없는 일을 만들지 않는다).
    private static func storeState(bundleId: String?, local: String) async -> (version: String, released: Bool) {
        guard let bundleId, let appId = try? await ASCClient.appId(bundleId: bundleId),
              let vers = try? await ASCClient.appStoreVersions(appId: appId) else { return (local, true) }
        let k = known(versions: vers, local: local)
        return (k.version, k.released)
    }

    /// 버전 목록을 이미 받아 둔 쪽(새로고침)이 같은 규칙으로 번호를 정하게 한다.
    static func known(versions vers: [ASCClient.Version], local: String) -> Known {
        let editable = vers.first { ReleaseNotes.editableStates.contains($0.state) }?.versionString
        let closed = vers.filter { !ReleaseNotes.editableStates.contains($0.state) }
            .map(\.versionString).max { Status.cmpVer($0, $1) < 0 }
        let released = vers.contains { $0.state == "READY_FOR_SALE" || $0.state == "REPLACED_WITH_NEW_VERSION" }
        return Known(version: Deployer.planVersion(local: local, bump: nil, editable: editable, closed: closed).version, released: released)
    }

    private static func reachable(_ url: String) async -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        req.timeoutInterval = 8
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0) < 400
    }

    // ── 기준 ────────────────────────────────────────────────────────────
    /// 자동 배포 완비 기준. 해결 프롬프트도 이 글을 붙인다 — 기준이 두 곳에 갈라지지 않게.
    static func standard(_ app: String, locales: [String], hasWatch: Bool, hasPad: Bool) -> String {
        let langs = locales.isEmpty ? "deploy.env 의 LOCALES 전부" : locales.joined(separator: ", ")
        var s = """
        ## 자동 배포 완비 기준 — 하나라도 빠지면 준비가 끝난 게 아니다
        대상 언어: \(langs). **모든 항목을 모든 언어에** 갖춘다. 한국어만, 영어만 채우고 끝내지 않는다.

        1. 설정 — `deploy.env` 에 SCHEME · LOCALES · PREDEPLOY_SCRIPT · VERSION_XCCONFIG.
           LOCALES 는 앱이 번역된 언어와 똑같아야 한다(.xcstrings 에 있는 언어는 전부 넣는다).
        2. 앱 번역 — .xcstrings 에 번역 구멍이 없어야 한다. `\(cli) --doctor \(app)` 가 깨끗해야 한다.
        3. 스토어 문구 — `APPSTORE.md` 에 언어마다 `## <로케일>` 절을 두고, 그 안에 아래 칸을 **전부** 쓴다.
           이름(30자) · 부제(30자) · 키워드(100자) · 프로모션 텍스트(170자) · 설명(4000자) · 지원 URL · 개인정보처리방침 URL
           - 그 언어 원어민이 쓴 글이어야 한다. 한국어를 직역하지 말고 그 나라 앱스토어 문체로 다시 쓴다.
             다른 언어 글자(특히 한글)가 섞이면 안 된다.
           - 이름은 언어마다 같은 브랜드를 유지하고, 필요하면 `브랜드: 짧은 설명` 으로 검색어를 붙인다.
           - 부제는 이름과 같은 말을 반복하지 않는다.
           - 키워드는 쉼표로만 나누고 공백을 넣지 않는다. 이름·부제에 이미 있는 단어, 다른 회사 상표는 넣지 않는다.
             그 언어 사용자가 **검색창에 실제로 칠 말**로 고른다(직역 금지). 100자를 거의 다 쓴다.
           - 설명은 첫 두 줄에 핵심을 둔다. 마크다운·이모지를 쓰지 않는다. 앱에 없는 기능을 지어내지 않는다.
           - URL 은 실제로 열려야 한다(심사자가 누른다). 그 언어 페이지가 있으면 그 주소를 쓴다.
           - 확인: `\(cli) --storemeta \(app)` 에 모든 언어가 나오고, 모든 칸이 한도 안이어야 한다.
        4. 릴리즈노트 — `RELEASE_NOTES.md` 의 `## <배포할 버전>` 절에 언어마다 `### 앱스토어 (<언어 이름>)` 절.
           배포할 버전은 `\(cli) --todo \(app)` 의 '다음 배포' 번호다(로컬 번호가 아닐 수 있다).
           사용자 CLAUDE.md 의 '릴리즈 노트 작성 규칙'을 지킨다 — 특수기호 없음, 3~5줄, 줄당 40자, 사용자 관점, 언어마다 같은 항목 수·순서.
           확인: `\(cli) --reponotes \(app) <버전>` 에 모든 언어가 나와야 한다.
        5. 스크린샷 — `docs/screenshots/marketing/<로케일>/01-….png` 처럼 **언어마다** 그 언어 화면으로.
           - 아이폰: 1242×2688 (또는 1320×2868 · 1290×2796), 3~10장, 번호 접두사 순서가 스토어 순서다.
           - 화면 속 글자와 헤드라인이 그 언어여야 한다. 한국어 화면을 다른 언어 칸에 올리지 않는다.
           - 원본 캡처는 `raw/` 에 두고 섞지 않는다. 빈 화면·권한 팝업·디버그 표시가 보이면 안 된다.

        """
        if hasWatch {
            s += "   - 이 앱에는 **워치 앱**이 있다: `docs/screenshots/watch/<로케일>/` 에 416×496 으로 언어마다.\n"
        }
        if hasPad {
            s += "   - 이 앱은 **아이패드**를 지원한다: 2064×2752 아이패드 그림도 언어마다 둔다.\n"
        }
        s += """
           - 확인: `\(cli) --shotplan \(app)` 끝의 `뱃지: ✅ 준비됨` 이어야 하고, '올라가지 않는 파일' 이 없어야 한다.
        5-1. 헤더 · 검색 결과 (iOS) — 스크린샷처럼 **언어마다** 둔다. 제품 페이지 맨 위와 검색 결과에 뜨는 그림이다.
           - `docs/screenshots/creative/<로케일>/header.png` 3840×1646 · `search.png` 3840×2560, PNG, 투명(알파) 없음.
           - 글은 Apple 템플릿의 안전 영역 안에만, 그 언어로 따로 쓴다. 헤더는 한 가지 약속, 검색 결과는 스크린샷 1장과 같은 이야기.
           - 만드는 법: `\(cli) --shots \(app) --creative` 의 지시를 따른다.
           - 확인: `\(cli) --shotplan \(app)` 끝의 '헤더·검색 결과' 줄이 모두 ✅ 이고 빠진 언어가 없어야 한다.
        6. 심사 — 수출 규정(암호화)과 연령 등급은 **애플에 하는 신고**다. 사람의 선언 없이 대신 적지 않는다.
        7. 저장소 — 모든 변경을 커밋한다. 커밋 안 된 변경이 남으면 배포가 잠긴다.

        """
        return s
    }

    // ── 지시문 ──────────────────────────────────────────────────────────
    /// `lang` 을 주면 **그 언어 하나**를 다른 언어와 같은 수준으로 올리는 지시문이 된다 — 새 언어를 늘릴 때.
    /// 앱 전체 지시문에 열 언어 치 빈 곳이 섞여 있으면 새 언어 하나 하려다 다른 언어까지 건드린다.
    static func prompt(_ app: ManagedApp, _ a: Audit, lang: String? = nil) -> String {
        if let lang { return langPrompt(app, a, lang) }
        var s = "\(app.path) 를 App Store 자동 배포에 **완비된 상태**로 만들어줘. 서비스로 내는 앱이다 — 품질을 낮추는 타협은 하지 마.\n\n"
        s += "## 앱\n- \(app.name) · 배포할 버전 v\(a.version)\n- 대상 언어 \(a.locales.count)개: \(a.locales.joined(separator: ", "))\n"
        if a.hasWatch { s += "- 워치 앱 있음\n" }
        if a.hasPad { s += "- 아이패드 지원\n" }
        s += "\n"
        s += standard(app.name, locales: a.locales, hasWatch: a.hasWatch, hasPad: a.hasPad)

        let mine = a.gaps.filter { !$0.human }
        let human = a.gaps.filter(\.human)
        if !a.notes.isEmpty {
            s += "## 참고\n" + a.notes.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        if mine.isEmpty && human.isEmpty {
            s += "## 지금 빠진 것\nDeployBar 가 찾은 빈 곳은 없다. 그래도 위 기준을 하나씩 열어 **글의 품질**(원어민 문체·키워드 선정·그림 속 언어)을 직접 확인해라.\n\n"
        } else {
            s += "## 지금 빠진 것 — DeployBar 가 찾은 것 (이게 전부라고 믿지 말고 기준 전체를 다시 확인해라)\n"
            var area = ""
            for g in mine {
                if g.area != area { s += "\n### \(g.area)\n"; area = g.area }
                s += "- \(g.text)\n"
            }
            if !human.isEmpty {
                s += "\n### 사람이 할 일 — 너는 하지 말고 끝에 목록으로 알려줘\n"
                for g in human { s += "- \(g.text)\n" }
            }
            s += "\n"
        }

        s += """
        ## 하는 순서
        1. 빈 스토어 문구·릴리즈노트는 먼저 `\(cli) --autowrite \(app.name) --no-commit` 로 초안을 채운다.
           그다음 **언어마다 직접 읽고 고친다** — 초안을 그대로 두지 마라. 이미 있는 글도 기준에 못 미치면 고친다.
        2. 스크린샷이 빠졌으면 `\(cli) --shots \(app.name)` 의 지시를 따라 언어마다 찍는다(appstore-assets 스킬이 있으면 먼저 읽는다).
           헤더·검색 결과가 빠졌으면 `\(cli) --shots \(app.name) --creative` 의 지시를 따라 언어마다 만든다.
        3. 아래 검증 명령을 **전부** 돌리고, 하나라도 기준에 못 미치면 고친 뒤 다시 돌린다.
           - `\(cli) --doctor \(app.name)`
           - `\(cli) --storemeta \(app.name)`
           - `\(cli) --reponotes \(app.name) \(a.version)`
           - `\(cli) --shotplan \(app.name)`
           - `\(cli) --prepare \(app.name)` — 끝의 `✅ 자동 배포 완비` 가 나와야 끝이다 (사람 몫만 남는 건 괜찮다)
        4. 커밋한다. 메시지에 무엇을 어느 언어로 채웠는지 적는다.

        ## 지켜야 할 것
        - 빌드·아카이브·업로드·심사 제출은 하지 마. 배포는 DeployBar 가 한다.
        - App Store Connect 를 직접 고치지 마. 레포의 APPSTORE.md · RELEASE_NOTES.md · docs/screenshots 가 원본이고, 배포가 그대로 올린다.
        - 앱에 없는 기능을 문구에 쓰지 마. 모르면 소스를 읽고 확인해라.
        - 기계번역 같은 문장, 다른 언어가 섞인 문장, 한도를 넘는 문장은 실패로 친다.
        - 못 끝낸 게 있으면 "됐다" 고 하지 말고 무엇이 왜 남았는지 알려줘.
        """
        return s
    }

    /// 새 언어 하나만. 기준(standard)은 같고, 빈 곳과 할 일을 그 언어로 좁힌다.
    private static func langPrompt(_ app: ManagedApp, _ a: Audit, _ lang: String) -> String {
        let name = Locales.displayName(lang)
        let declared = a.locales.contains { Locales.sameLanguage($0, lang) }
        let base = a.locales.first(where: Locales.isKorean) ?? a.locales.first ?? "ko"
        func mine(_ g: Gap) -> Bool { g.locales?.contains { Locales.sameLanguage($0, lang) } ?? false }
        let gaps = a.gaps.filter { !$0.human && mine($0) }

        var s = "\(app.path) 에 **\(name)(\(lang))** 을(를) 새로 지원하려 한다. 이 언어를 이미 있는 언어들과 같은 수준으로 맞춰줘. "
        s += "서비스로 내는 앱이다 — 품질을 낮추는 타협은 하지 마. **다른 언어의 글·그림은 건드리지 마.**\n\n"
        s += "## 앱\n- \(app.name) · 배포할 버전 v\(a.version)\n- 이미 있는 언어: \(a.locales.filter { !Locales.sameLanguage($0, lang) }.joined(separator: ", "))\n"
        if a.hasWatch { s += "- 워치 앱 있음\n" }
        if a.hasPad { s += "- 아이패드 지원\n" }
        s += "\n## \(name) 에 할 일 — 순서대로\n"
        var n = 0
        func step(_ t: String) { n += 1; s += "\(n). \(t)\n" }
        if !declared {
            step("`deploy.env` 의 LOCALES 에 `\(lang)` 을 넣는다(주석과 키 순서는 그대로). 넣어야 DeployBar 가 이 언어를 검사하고, 배포할 때 App Store 페이지에 이 언어를 **스스로 만든다** — 웹에서 언어를 추가할 필요 없다.")
        }
        step("앱 번역 — .xcstrings 의 `\(lang)` 값을 전부 채운다(복수형·기기별 variations 안까지). 한국어 원문 기준, 직역 금지. `\(cli) --doctor \(app.name)` 에 이 언어 구멍이 없어야 한다. InfoPlist.xcstrings(권한 문구·앱 이름)도 잊지 마.")
        step("스토어 문구 — `APPSTORE.md` 에 `## \(lang)` 절을 만들고 이름·부제·키워드·프로모션 텍스트·설명·지원 URL·개인정보처리방침 URL 을 **전부** 쓴다. `\(base)` 절을 출발점으로 삼되 그 나라 앱스토어 문체로 새로 쓰고, 키워드는 그 나라 사람이 검색창에 칠 말로 다시 고른다.")
        step("릴리즈노트 — `RELEASE_NOTES.md` 의 `## \(a.version)` 에 `### 앱스토어 (\(lang))` 절(제목의 로케일 코드로 언어를 알아본다). 다른 언어와 항목 수·순서를 맞춘다.")
        step("스크린샷 — `docs/screenshots/marketing/\(lang)/` 에 이 언어 화면으로 찍는다(시뮬레이터 언어를 `\(lang)` 로). `\(cli) --shots \(app.name)` 의 지시와 appstore-assets 스킬을 따르되 **이 언어만** 찍는다." + (a.hasPad ? " 아이패드 2064×2752 도." : "") + (a.hasWatch ? " 워치 416×496 도." : ""))
        step("헤더·검색 결과 — `\(StorePublish.canonicalCreativeDir)/\(lang)/header.png`(3840×1646) · `search.png`(3840×2560). 생성 스크립트가 있으면 이 언어의 문구만 더해 다시 돌린다(`\(cli) --shots \(app.name) --creative`).")
        step("확인 — `\(cli) --prepare \(app.name) --lang \(lang)` 의 끝이 `✅ \(name) 완비` 여야 한다. 그다음 커밋한다(메시지에 \(name) 추가라고 적는다).")

        s += "\n"
        s += standard(app.name, locales: a.locales, hasWatch: a.hasWatch, hasPad: a.hasPad)
        s += !declared
            ? "## \(name) 에서 지금 빠진 것\nLOCALES 에 없어 아직 검사 대상이 아니다 — 위 할 일 전부가 남았다. 1번을 한 뒤 이 명령을 다시 돌리면 빈 곳이 나온다.\n\n"
            : gaps.isEmpty
            ? "## \(name) 에서 지금 빠진 것\nDeployBar 가 찾은 빈 곳은 없다. 그래도 글과 그림의 품질(원어민 문체·키워드·그림 속 언어)을 직접 확인해라.\n\n"
            : "## \(name) 에서 지금 빠진 것 — DeployBar 가 찾은 것\n" + gaps.map { "- [\($0.area)] \($0.text)" }.joined(separator: "\n") + "\n\n"
        s += """
        ## 지켜야 할 것
        - 빌드·아카이브·업로드·심사 제출은 하지 마. App Store Connect 도 직접 고치지 마 — 이 언어 페이지는 배포가 만든다.
        - 앱에 없는 기능을 문구에 쓰지 마. 기계번역 같은 문장, 한글이 섞인 문장, 한도를 넘는 문장은 실패로 친다.
        - 못 끝낸 게 있으면 "됐다" 고 하지 말고 무엇이 왜 남았는지 알려줘.
        """
        return s
    }
}
