import Foundation
import ImageIO

// "스토어 페이지 올리기" — 업로드가 끝난 뒤 사람이 웹에서 하던 일을 여기서 한다.
//
// 배포(Deployer)가 **바이너리**를 올린다면, 이쪽은 **스토어 페이지**를 올린다:
//   버전 만들기 → 빌드 고르기 → 이름·부제·설명·키워드·URL → 스크린샷 → (연령 등급)
// 마지막의 심사 제출·출시는 부르는 쪽이 따로 누른다 (submit / release).
//
// 원칙 셋:
//  1. **레포가 원본이다.** 문구는 APPSTORE.md, 그림은 docs/screenshots/ 에서 온다.
//     App Store Connect 는 그 사본을 받는 곳이지, 원본을 보관하는 곳이 아니다.
//  2. **안 적은 것은 안 건드린다.** 빈 칸을 올려 이미 있던 글을 지우는 사고를 막는다.
//  3. **못 한 것은 반드시 말한다.** 조용히 건너뛴 항목이 있으면 심사 직전에 발이 묶인다.
//     그래서 Report 에 manual(사람이 해야 하는 것)을 따로 들고 돌아온다.
enum StorePublish {

    struct Options {
        var createVersion = true      // 편집 가능한 버전이 없으면 만든다
        var attachBuild = true        // 올라간 빌드를 그 버전에 고른다
        var text = true               // 이름·부제·설명·키워드·URL
        var screenshots = true        // docs/screenshots/ 를 올린다
        var previews = true           // docs/screenshots/preview/ 의 미리보기 영상을 올린다
        var creatives = true          // docs/screenshots/creative/ 의 헤더·검색 결과 자산을 올린다
        /// 올린 영상의 처리를 기다렸다가 대표 프레임을 정할 최대 시간(초). 헤더·검색 결과 자산의 처리 대기도 같은 값
        var previewWait: TimeInterval = 600
        var ageRating = true          // APPSTORE.md 가 "해당 없음" 이라고 적었을 때만
        /// 스토어에 이미 글이 있어도 레포 글로 덮어쓸지. **기본은 덮어쓴다 — 레포가 원본이다.**
        ///
        /// 예전 기본은 false 였다(웹에서 고친 문구를 말없이 되돌리지 않으려고). 그런데 그 탓에
        /// 언어를 추가할 때 임시로 들어간 값(한국어 이름 등)이 영원히 남아, APPSTORE.md 에
        /// 독일어를 다 써 둬도 독일어 페이지가 한국어로 나갔다 — 그것도 로그에 아무 말 없이.
        /// 이제는 덮어쓰되 **말없이 하지 않는다**: 바꾸기 전 값을 로그와 백업 파일에 남긴다.
        var overwriteText = true
        /// 이미 올라간 그림을 지우고 다시 올릴지 (파일이 달라졌으면 어차피 다시 올린다)
        var replaceShots = false
        /// 그림을 얼마나 손댈지. 배포는 사람이 '이번에 스크린샷 교체' 를 체크했을 때만 지운다.
        var shotMode: ShotMode = .sync
        /// 우리가 못 하는 것(인앱결제·개인정보 라벨)까지 확인해서 알려 줄지.
        /// 배포 중에는 끈다 — 매 배포마다 같은 줄이 반복되면 로그가 무뎌진다.
        var manualCheck = true
        var dryRun = false
    }

    /// - sync: 레포와 다르면 그 기기 칸을 다시 올린다 (`--publish`)
    /// - fillEmpty: 비어 있는 칸만 채운다. 이미 있는 그림은 안 건드린다 (체크 안 한 배포)
    /// - replaceAll: 모든 언어가 준비됐을 때만, 기존 그림을 **기기 가리지 않고 전부** 지우고 올린다
    enum ShotMode { case sync, fillEmpty, replaceAll }

    struct Report {
        /// replaceAll 인데 준비가 덜 돼서 아무것도 안 건드렸다면 그 이유.
        /// 배포는 이걸 보고 심사 제출을 멈춘다 — 사람은 새 그림으로 내려고 체크했다.
        var shotsRefused: String?
        var version: String = ""
        var versionId: String = ""
        var changed: [String] = []    // 실제로 바꾼 것
        var kept: [String] = []       // 이미 같아서 그대로 둔 것
        var manual: [String] = []     // 사람이 웹에서 해야만 하는 것
        var warnings: [String] = []   // 하려다 못 한 것 (이유와 함께)
        var didWrite: Bool { !changed.isEmpty }
    }

    // ── 본체 ────────────────────────────────────────────────────────────
    static func run(_ app: ManagedApp, options: Options = Options(),
                    onLog: @escaping (String) -> Void = { _ in }) async throws -> Report {
        let r = AppRepo.resolve(app)
        guard r.exists else { throw err(app, "프로젝트 확인", "Xcode 프로젝트를 찾을 수 없습니다", []) }
        let info = try AppRepo.buildSettings(r)
        var report = Report()

        guard let appId = try await ASCClient.appId(bundleId: info.bundleId) else {
            throw err(app, "앱 확인", "App Store Connect 에 이 번들 ID 의 앱이 없습니다",
                      ["App Store Connect ▸ 앱 ▸ + 에서 \(info.bundleId) 로 앱을 먼저 만드세요",
                       "앱 레코드 생성은 API 에 없는 유일한 단계입니다 — 사람이 웹에서 한 번만 하면 됩니다"],
                      detail: info.bundleId)
        }
        onLog("🔗 App Store Connect 앱 \(appId) · \(info.bundleId)")

        // 1) 편집 가능한 버전 — 없으면 만든다.
        //    여태 "ASC 에서 버전을 먼저 만드세요" 라고 사람에게 떠넘기던 단계다.
        let versions = try await ASCClient.appStoreVersions(appId: appId)
        var target = versions.first { ReleaseNotes.editableStates.contains($0.state) }
        if target == nil {
            guard options.createVersion else {
                throw err(app, "버전 확인", "편집 가능한 App Store 버전이 없습니다",
                          ["--publish 를 옵션 없이 부르면 v\(info.marketingVersion) 버전을 만들어 줍니다"])
            }
            if options.dryRun {
                onLog("📝 [미리보기] v\(info.marketingVersion) 버전을 만듭니다")
                report.changed.append("버전 v\(info.marketingVersion) 생성 (미리보기)")
                return report   // 버전이 없으면 그 아래 단계는 미리 볼 것도 없다
            }
            onLog("🆕 편집 가능한 버전이 없습니다 — v\(info.marketingVersion) 을 만듭니다")
            target = try await ASCClient.createVersion(appId: appId,
                                                       versionString: info.marketingVersion,
                                                       platform: info.platform)
            report.changed.append("App Store 버전 v\(info.marketingVersion) 생성")
        }
        guard let version = target else { return report }
        report.version = version.versionString
        report.versionId = version.id
        onLog("📦 대상 버전: v\(version.versionString) · \(ASCState.label(version.state) ?? version.state)")

        // 2) 빌드 고르기 — 이게 비면 심사 제출 버튼이 아예 안 눌린다.
        if options.attachBuild {
            if version.hasBuild {
                report.kept.append("빌드는 이미 연결돼 있습니다")
            } else if let b = try await ASCClient.attachableBuild(appId: appId,
                                                                 marketingVersion: version.versionString) {
                if b.state != "VALID" {
                    report.warnings.append("빌드 \(b.build) 가 아직 처리 중(\(b.state))이라 연결하지 못했습니다 — 몇 분 뒤 다시 누르세요")
                    onLog("⏳ 빌드 \(b.build) 처리 중 — 연결은 다음에")
                } else if options.dryRun {
                    report.changed.append("빌드 \(b.build) 연결 (미리보기)")
                } else {
                    try await ASCClient.attachBuild(versionId: version.id, buildId: b.id)
                    report.changed.append("빌드 \(b.build) 를 v\(version.versionString) 에 연결")
                    onLog("🔧 빌드 \(b.build) 연결 완료")
                }
            } else {
                report.warnings.append("v\(version.versionString) 으로 올라간 빌드가 없습니다 — 먼저 [배포] 로 올리세요")
            }
        }

        // 3) 문구 — APPSTORE.md 가 원본
        let meta = StoreMeta.read(app.path, locales: r.locales)
        if options.text {
            if let meta {
                onLog("📄 문구 원본: \(meta.source) · \(meta.locales.count)개 언어")
                try await pushText(app, appId: appId, version: version, meta: meta,
                                   options: options, report: &report, onLog: onLog)
            } else {
                report.manual.append("APPSTORE.md 가 없어 설명·키워드는 건드리지 않았습니다 (`--storemeta <앱> --write` 로 뼈대를 만듭니다)")
            }
        }

        // 4) 스크린샷
        if options.screenshots {
            try await pushShots(app, version: version, platform: info.platform,
                                options: options, report: &report, onLog: onLog)
        }

        // 4-1) 미리보기 영상, 검색 결과 첫 칸. 스크린샷과 같은 규칙(레포가 원본, 같으면 안 건드린다)
        if options.previews {
            try await pushPreviews(app, version: version, platform: info.platform,
                                   poster: r.previewPoster, options: options,
                                   report: &report, onLog: onLog)
        }

        // 4-2) 헤더·검색 결과 (크리에이티브 자산), 같은 규칙. 자산 라이브러리에 올리고 언어 칸에 배치한다
        //      비워도 심사는 되는 칸이라, 여기서 막혀도 배포 전체를 세우지 않고 경고로 남긴다
        if options.creatives {
            do {
                try await pushCreatives(app, appId: appId, version: version, poster: r.previewPoster,
                                        options: options, report: &report, onLog: onLog)
            } catch {
                report.warnings.append("헤더·검색 결과를 올리지 못했습니다: \(reason(error))")
            }
        }

        // 5) 연령 등급 — 사람이 APPSTORE.md 에 적어 둔 앱만
        if options.ageRating, let appInfo = try await ASCClient.appInfo(appId: appId) {
            let done = (try? await ASCClient.ageRatingDone(appInfoId: appInfo.id)) ?? false
            if done {
                report.kept.append("연령 등급은 이미 작성돼 있습니다")
            } else if meta?.ageRatingNone == true {
                if options.dryRun {
                    report.changed.append("연령 등급 '해당 없음' 선언 (미리보기)")
                } else {
                    do {
                        try await ASCClient.declareAgeRatingNone(appInfoId: appInfo.id)
                        report.changed.append("연령 등급을 '해당 없음' 으로 선언 (APPSTORE.md 의 뜻대로)")
                    } catch {
                        report.warnings.append("연령 등급 선언이 거부됐습니다 — 웹에서 설문을 채우세요: \(reason(error))")
                    }
                }
            } else {
                report.manual.append("연령 등급 설문이 비어 있습니다 — 내용이 전부 '해당 없음' 이면 APPSTORE.md 의 `## 연령 등급` 절에 '해당 없음' 이라고 적어 두면 다음부터 자동입니다")
            }
        }

        // 6) 우리가 손댈 수 없는 것들을 **확인만** 해서 알려 준다.
        //    여기까지 와서 "제출 버튼이 안 눌린다" 를 웹에서 처음 알게 되면 안 된다.
        if options.manualCheck { await checkManual(app, appId: appId, report: &report) }
        return report
    }

    // ── 문구 올리기 ─────────────────────────────────────────────────────
    private static func pushText(_ app: ManagedApp, appId: String, version: ASCClient.Version,
                                 meta: StoreMeta.Found, options: Options,
                                 report: inout Report, onLog: (String) -> Void) async throws {
        // 길이 제한은 올리기 전에 잡는다 — API 의 409 는 어느 칸인지 말해 주지 않는다
        var problems: [String] = []
        for (loc, e) in meta.entries { problems += StoreMeta.problems(loc, e) }
        if !problems.isEmpty {
            throw err(app, "문구 검사", "APPSTORE.md 의 글자 수가 App Store 제한을 넘습니다",
                      problems + ["줄인 뒤 다시 누르세요 — 넘친 채로 올리면 애플이 통째로 거부합니다"])
        }

        // App Store 페이지에 없는 언어 — 만들 수 있으면 먼저 만든다.
        // (여태 "웹에서 언어를 추가하세요" 로 남겨 두던 자리다)
        var texts = try await ASCClient.storeTexts(versionId: version.id)
        let missing = meta.entries.keys.sorted().filter { loc in !texts.contains { covers($0.locale, loc) } }
        if !missing.isEmpty {
            if options.dryRun {
                for loc in missing { report.changed.append("\(Locales.displayName(loc)) 페이지 추가 (미리보기)") }
            } else {
                let res = await addLanguages(appId: appId, versionId: version.id, want: missing, meta: meta)
                for loc in res.added { report.changed.append("\(Locales.displayName(loc)) 스토어 페이지 추가") }
                report.warnings += res.failed
                if !res.added.isEmpty { texts = try await ASCClient.storeTexts(versionId: version.id) }
            }
        }

        // 덮어쓴 칸의 옛 값 — 끝에서 파일로 남긴다. 웹에서 고친 글을 되살릴 길을 남겨 둔다.
        var backup: [[String: String]] = []
        defer { saveBackup(app, backup, dryRun: options.dryRun, onLog: onLog) }

        // (a) 버전 문구 (설명·키워드·프로모션·URL·릴리즈노트는 여기 말고 ReleaseNotes 가 쓴다)
        // 스토어 언어마다 맞는 레포 글을 고른다 — 레포 글마다 스토어 언어를 고르면(예전 방식)
        // `es` 가 스페인·멕시코 중 하나에만 들어가고, `pt-BR`·`pt-PT` 가 엇갈려 들어갈 수 있다.
        for t in texts.sorted(by: { $0.locale < $1.locale }) {
            guard let (_, entry) = StoreMeta.entry(for: t.locale, in: meta.entries) else { continue }
            let loc = t.locale
            var fields: [String: String] = [:]
            func put(_ key: String, _ new: String?, _ old: String) {
                guard let new, !new.isEmpty, new != old else { return }
                guard old.isEmpty || options.overwriteText else {
                    report.kept.append("\(Locales.displayName(loc)) \(fieldLabel(key)): 스토어 쪽 글을 그대로 뒀습니다")
                    return
                }
                if !old.isEmpty { backup.append(["locale": t.locale, "field": key, "old": old, "new": new]) }
                fields[key] = new
            }
            put("description", entry.description, t.description)
            put("keywords", entry.keywords, t.keywords)
            put("promotionalText", entry.promotionalText, t.promotionalText)
            put("supportUrl", entry.supportUrl, t.supportUrl)
            put("marketingUrl", entry.marketingUrl, t.marketingUrl)
            guard !fields.isEmpty else { continue }
            let names = fields.keys.sorted().map(fieldLabel).joined(separator: "·")
            if options.dryRun {
                report.changed.append("\(Locales.displayName(loc)) \(names) (미리보기)")
            } else {
                try await ASCClient.patchVersionLocalization(id: t.id, fields: fields)
                report.changed.append("\(Locales.displayName(loc)) \(names)")
                onLog("✏️  \(Locales.displayName(loc)) — \(names)")
            }
        }

        // (b) 앱 정보 (이름·부제·개인정보처리방침 URL) — 버전이 아니라 앱에 붙는 값
        guard let appInfo = try await ASCClient.appInfo(appId: appId) else { return }
        var infos = try await ASCClient.infoTexts(appInfoId: appInfo.id)
        // 먼저 앱 정보가 아예 없는 언어를 만든다 (이름이 필수 칸이라 이름을 적은 언어만)
        for (loc, entry) in meta.entries.sorted(by: { $0.key < $1.key }) {
            guard entry.name != nil || entry.subtitle != nil || entry.privacyPolicyUrl != nil else { continue }
            if infos.contains(where: { Locales.sameLanguage($0.locale, loc) }) { continue }
            guard let name = entry.name else {
                report.warnings.append("\(Locales.displayName(loc)) 앱 정보가 없어 부제·URL 을 넣을 곳이 없습니다 — APPSTORE.md 에 `### 이름` 을 적으면 만들어 줍니다")
                continue
            }
            if options.dryRun {
                report.changed.append("\(Locales.displayName(loc)) 앱 이름 '\(name)' (미리보기)")
                continue
            }
            do {
                let made = try await ASCClient.createInfoText(appInfoId: appInfo.id, locale: Locales.ascCode(loc), name: name)
                report.changed.append("\(Locales.displayName(loc)) 앱 정보 추가 · 이름 '\(name)'")
                infos.append(made)
            } catch {
                report.warnings.append("\(Locales.displayName(loc)) 앱 정보 추가 실패 — \(reason(error))")
            }
        }
        // 그다음 스토어의 앱 정보마다 맞는 레포 글로 맞춘다 (버전 문구와 같은 규칙)
        for t in infos.sorted(by: { $0.locale < $1.locale }) {
            guard let (_, entry) = StoreMeta.entry(for: t.locale, in: meta.entries) else { continue }
            let loc = t.locale
            var fields: [String: String] = [:]
            func put(_ key: String, _ new: String?, _ old: String) {
                guard let new, !new.isEmpty, new != old else { return }
                guard old.isEmpty || options.overwriteText else {
                    report.kept.append("\(Locales.displayName(loc)) \(fieldLabel(key)): 스토어 쪽 값을 그대로 뒀습니다")
                    return
                }
                if !old.isEmpty { backup.append(["locale": t.locale, "field": key, "old": old, "new": new]) }
                fields[key] = new
            }
            put("name", entry.name, t.name)
            put("subtitle", entry.subtitle, t.subtitle)
            put("privacyPolicyUrl", entry.privacyPolicyUrl, t.privacyPolicyUrl)
            guard !fields.isEmpty else { continue }
            let names = fields.keys.sorted().map(fieldLabel).joined(separator: "·")
            if options.dryRun {
                report.changed.append("\(Locales.displayName(loc)) \(names) (미리보기)")
            } else {
                try await ASCClient.patchInfoText(id: t.id, fields: fields)
                report.changed.append("\(Locales.displayName(loc)) \(names)")
                onLog("✏️  \(Locales.displayName(loc)) — \(names)")
            }
        }
    }

    private static func fieldLabel(_ key: String) -> String {
        switch key {
        case "description": return "설명"
        case "keywords": return "키워드"
        case "promotionalText": return "프로모션 텍스트"
        case "supportUrl": return "지원 URL"
        case "marketingUrl": return "마케팅 URL"
        case "name": return "이름"
        case "subtitle": return "부제"
        case "privacyPolicyUrl": return "개인정보처리방침 URL"
        default: return key
        }
    }

    // ── 스크린샷 올리기 ─────────────────────────────────────────────────
    /// 어디서 찾나:
    ///   docs/screenshots/<로케일>/*.png  → 그 언어에만
    ///   docs/screenshots/*.png           → 하위 폴더가 없으면 **모든 언어에** 같은 벌을 올린다
    ///
    /// 뒤쪽 규칙이 거칠어 보이지만, 스크린샷은 언어마다 있어야 제출이 되므로
    /// "한국어에만 올리고 나머지는 빈칸" 이 훨씬 나쁜 결과를 만든다. 대신 로그에 분명히 적는다.
    private static func pushShots(_ app: ManagedApp, version: ASCClient.Version,
                                  platform: Platform, options: Options,
                                  report: inout Report, onLog: (String) -> Void) async throws {
        guard let dir = shotDir(app.path) else {
            // 이 워크플로를 안 쓰는 앱엔 말하지 않는다 — 다만 교체를 체크했다면 못 한 이유를 남긴다
            if options.shotMode == .replaceAll {
                report.shotsRefused = "\(canonicalShotDir)/ 가 없어 스크린샷을 교체하지 않았습니다"
                report.warnings.append(report.shotsRefused!)
            }
            return
        }
        let texts = try await ASCClient.storeTexts(versionId: version.id)
        guard !texts.isEmpty else {
            report.warnings.append("스토어 페이지 언어가 하나도 없어 스크린샷을 올릴 자리가 없습니다")
            return
        }

        let resolved = resolveShots(dir, locales: texts.map(\.locale))
        let shared = resolved[""] ?? []
        if resolved.isEmpty {
            if options.shotMode == .replaceAll {
                report.shotsRefused = "\(rel(dir, app.path)) 에 그림이 없어 스크린샷을 교체하지 않았습니다"
            }
            report.manual.append("\(rel(dir, app.path)) 에 그림이 없습니다 — `--shots \(app.name)` 지시문으로 찍으세요")
            return
        }
        if !shared.isEmpty && texts.count > 1 {
            onLog("🖼  언어별 폴더가 없어 같은 \(shared.count)장을 \(texts.count)개 언어에 올립니다")
        }

        // 전부 지우기 전에 **모든 언어가 준비됐는지부터** 본다.
        // 반쯤 지우고 멈추면 스토어에 그림 없는 언어가 생기고, 그 상태로는 심사 제출이 안 된다.
        if options.shotMode == .replaceAll {
            var problems: [String] = []
            for t in texts {
                let lang = Locales.displayName(t.locale)
                let files = resolved.first { !$0.key.isEmpty && Locales.sameLanguage($0.key, t.locale) }?.value ?? shared
                if files.isEmpty { problems.append("\(lang) 그림 없음"); continue }
                let g = group(files, platform: platform)
                if !g.skipped.isEmpty { problems.append("\(lang) — \(g.skipped.first!)") }
                if !g.byType.keys.contains(where: { deviceFamily($0) == "iPhone" || deviceFamily($0) == "Mac" }) {
                    problems.append("\(lang) \(platform == .macOS ? "Mac" : "아이폰") 그림 없음")
                }
            }
            if !problems.isEmpty {
                let why = "스크린샷 준비가 덜 돼 교체하지 않았습니다 — " + problems.prefix(4).joined(separator: " · ")
                    + (problems.count > 4 ? " 외 \(problems.count - 4)건" : "")
                report.shotsRefused = why
                report.warnings.append(why)
                onLog("⛔️ \(why)")
                return
            }
            onLog("🖼  \(texts.count)개 언어 모두 준비됨 — 기존 스크린샷을 지우고 새로 올립니다")
        }

        for t in texts {
            let files = resolved.first { !$0.key.isEmpty && Locales.sameLanguage($0.key, t.locale) }?.value ?? shared
            guard !files.isEmpty else {
                report.warnings.append("\(Locales.displayName(t.locale)) 에 올릴 그림이 없습니다")
                continue
            }
            // 크기로 기기 종류를 가른다 — 파일 이름은 믿지 않는다
            let grouped = group(files, platform: platform)
            let byType = grouped.byType
            report.warnings += grouped.skipped
            var sets = try await ASCClient.shotSets(localizationId: t.id)
            // 교체: 이번에 안 올리는 기기 칸(예전 6.7" 벌 같은 것)까지 비운다 — "다 지우고 내가 준비한 걸로"
            if options.shotMode == .replaceAll {
                let old = sets.reduce(0) { $0 + $1.shots.count }
                if options.dryRun {
                    if old > 0 { report.changed.append("\(Locales.displayName(t.locale)) 기존 \(old)장 지우기 (미리보기)") }
                } else if old > 0 {
                    for set in sets { for s in set.shots { try? await ASCClient.deleteShot(id: s.id) } }
                    report.changed.append("\(Locales.displayName(t.locale)) 기존 \(old)장 삭제")
                    sets = sets.map { var x = $0; x.shots = []; return x }
                }
            }
            for (type, list) in byType.sorted(by: { $0.key < $1.key }) {
                let sorted = list.sorted { $0.lastPathComponent < $1.lastPathComponent }
                let existing = sets.first { $0.displayType == type }
                // 같은 파일이 같은 수만큼 이미 올라가 있으면 다시 올리지 않는다.
                // (스크린샷 업로드는 느리다 — 한 장에 수 MB 다)
                let same = existing.map { set in
                    set.shots.count == sorted.count &&
                    zip(set.shots, sorted).allSatisfy { $0.fileName == $1.lastPathComponent
                        && $0.fileSize == fileSize($1) }
                } ?? false
                if same && !options.replaceShots && options.shotMode == .sync {
                    report.kept.append("\(Locales.displayName(t.locale)) \(typeLabel(type)) \(sorted.count)장은 이미 같습니다")
                    continue
                }
                // 체크 안 한 배포: 이미 그림이 있는 칸은 그대로 둔다 (스크린샷은 매번 바꾸는 게 아니다)
                if options.shotMode == .fillEmpty, let e = existing, !e.shots.isEmpty {
                    report.kept.append("\(Locales.displayName(t.locale)) \(typeLabel(type)) 기존 \(e.shots.count)장 유지")
                    continue
                }
                if options.dryRun {
                    report.changed.append("\(Locales.displayName(t.locale)) \(typeLabel(type)) \(sorted.count)장 올리기 (미리보기)")
                    continue
                }
                let setId: String
                if let e = existing {
                    for s in e.shots { try? await ASCClient.deleteShot(id: s.id) }
                    setId = e.id
                } else if type.hasPrefix("APP_WATCH") {
                    // 빌드에 워치 앱이 없으면 애플이 워치 칸을 거부한다 — 아이폰 그림까지 멈추게 하지 않는다
                    do { setId = try await ASCClient.createShotSet(localizationId: t.id, displayType: type) }
                    catch {
                        report.warnings.append("\(Locales.displayName(t.locale)) \(typeLabel(type)) 칸을 만들지 못했습니다 — \(reason(error))")
                        continue
                    }
                } else {
                    setId = try await ASCClient.createShotSet(localizationId: t.id, displayType: type)
                }
                onLog("🖼  \(Locales.displayName(t.locale)) · \(typeLabel(type)) — \(sorted.count)장 올리는 중…")
                var ids: [String] = []
                for f in sorted {
                    do { ids.append(try await ASCClient.uploadShot(setId: setId, file: f)) }
                    catch {
                        report.warnings.append("\(f.lastPathComponent) 업로드 실패 — \(reason(error))")
                    }
                }
                try? await ASCClient.orderShots(setId: setId, ids: ids)
                report.changed.append("\(Locales.displayName(t.locale)) \(typeLabel(type)) \(ids.count)장 업로드")
            }
        }
    }

    /// 덮어쓴 스토어 값을 `~/Library/Application Support/DeployBar/store-backup/` 에 남긴다.
    private static func saveBackup(_ app: ManagedApp, _ items: [[String: String]], dryRun: Bool,
                                   onLog: (String) -> Void) {
        guard !items.isEmpty else { return }
        if dryRun {
            onLog("ℹ️  스토어에 있던 글 \(items.count)칸을 레포 글로 바꿉니다 (미리보기)")
            return
        }
        let dir = Config.supportDir.appendingPathComponent("store-backup")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("\(app.name)-\(f.string(from: Date())).json")
        if let data = try? JSONSerialization.data(withJSONObject: items, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        }
        onLog("🗂  스토어에 있던 글 \(items.count)칸을 레포 글로 바꿨습니다 — 바꾸기 전 값: \(url.path)")
        for i in items.prefix(12) {
            let old = (i["old"] ?? "").replacingOccurrences(of: "\n", with: " ")
            onLog("   · \(Locales.displayName(i["locale"] ?? "")) \(fieldLabel(i["field"] ?? "")): '\(old.prefix(40))\(old.count > 40 ? "…" : "")' → 레포 글")
        }
    }

    // ── 우리가 못 하는 것 확인 ──────────────────────────────────────────
    private static func checkManual(_ app: ManagedApp, appId: String,
                                    report: inout Report) async {
        // 인앱결제: 코드가 부르는 상품이 ASC 에 없으면 심사에서 반드시 막힌다.
        // (상품 만들기도 API 로 되지만 값이 돈이라 도구가 지어낼 수 없다 — 있는지만 본다)
        if let wanted = iapProductIds(app.path), !wanted.isEmpty {
            let have = Set((try? await ASCClient.inAppPurchaseIds(appId: appId)) ?? [])
            let missing = wanted.filter { !have.contains($0) }
            if !missing.isEmpty {
                report.manual.append("인앱결제 \(missing.count)개가 App Store Connect 에 없습니다: \(missing.joined(separator: ", ")) — 만들지 않으면 페이월이 빈 화면으로 뜨고 심사도 막힙니다")
            }
        }
        report.manual.append("앱 개인정보(데이터 수집) 라벨은 공개 API 에 없습니다 — 웹에서 한 번만 답하면 다음 버전부터 유지됩니다")
    }

    /// 코드가 부르는 인앱결제 상품 ID. StoreKit 설정 파일과 소스에서 찾는다.
    private static func iapProductIds(_ root: String) -> [String]? {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return nil }
        var out: Set<String> = []
        for case let p as String in e {
            guard p.hasSuffix(".storekit") else { continue }
            if p.contains(".git/") { continue }
            guard let data = fm.contents(atPath: (root as NSString).appendingPathComponent(p)),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            collectProductIds(j, into: &out)
        }
        return out.isEmpty ? nil : Array(out).sorted()
    }

    private static func collectProductIds(_ any: Any, into out: inout Set<String>) {
        if let d = any as? [String: Any] {
            if let id = d["productID"] as? String { out.insert(id) }
            for v in d.values { collectProductIds(v, into: &out) }
        } else if let a = any as? [Any] {
            for v in a { collectProductIds(v, into: &out) }
        }
    }

    // ── 언어 추가 ───────────────────────────────────────────────────────
    /// App Store 페이지에 없는 언어를 만든다. 배포 앞(릴리즈노트)과 문구 올리기가 같이 쓴다.
    ///
    /// 순서가 중요하다: **앱 정보(이름) → 버전 문구.** ASC 는 앱 정보에 없는 언어로
    /// 버전 문구를 만들면 409 "The language specified is not listed for localization" 으로 거부한다.
    /// 코드도 ASC 가 받는 것("en" 이 아니라 "en-US")으로 바꿔서 보낸다.
    struct LanguageResult {
        var added: [String] = []     // 만든 로케일 (요청한 그대로의 표기)
        var failed: [String] = []    // 못 만든 이유 — 사람이 읽을 한 줄씩
    }
    /// 스토어에 있는 페이지 `have` 가 레포의 언어 `want` 자리를 채우는가.
    /// `en` 처럼 언어만 적었으면 그 언어 페이지 아무것이나, `en-GB` 처럼 지역까지 적었으면 **그 로케일**이어야 한다.
    /// 같은 언어로만 보면 en-US 가 있다는 이유로 en-GB 페이지가 영영 안 생긴다
    /// (영국 · 한국 · 유럽 대부분이 영어(영국) 칸을 색인한다. 미국 칸은 거기서 안 읽힌다).
    static func covers(_ have: String, _ want: String) -> Bool {
        Locales.language(want) == want
            ? Locales.sameLanguage(have, want)
            : have.caseInsensitiveCompare(Locales.ascCode(want)) == .orderedSame
    }

    static func addLanguages(appId: String, versionId: String, want: [String],
                             meta: StoreMeta.Found?) async -> LanguageResult {
        var out = LanguageResult()
        guard !want.isEmpty else { return out }
        do {
            let texts = try await ASCClient.storeTexts(versionId: versionId)
            guard let appInfo = try await ASCClient.appInfo(appId: appId) else {
                out.failed = want.map { "\(Locales.displayName($0)) 추가 실패 — 앱 정보를 찾지 못했습니다" }
                return out
            }
            var infos = try await ASCClient.infoTexts(appInfoId: appInfo.id)
            // 이름을 안 적은 언어는 기본 언어(한국어가 있으면 한국어)의 앱 이름을 빌린다 — 이름은 필수 칸이다
            let fallbackName = (infos.first { Locales.isKorean($0.locale) } ?? infos.first)?.name
            for loc in want where !texts.contains(where: { covers($0.locale, loc) }) {
                let code = Locales.ascCode(loc)
                let label = Locales.displayName(loc)
                do {
                    if !infos.contains(where: { covers($0.locale, loc) }) {
                        let written = meta.flatMap { StoreMeta.entry(for: code, in: $0.entries) }?.entry.name
                        guard let name = written ?? fallbackName, !name.isEmpty else {
                            out.failed.append("\(label) 추가 실패 — 앱 이름이 없습니다 · APPSTORE.md 의 이 언어 절에 `### 이름` 을 적으세요")
                            continue
                        }
                        infos.append(try await ASCClient.createInfoText(appInfoId: appInfo.id, locale: code, name: name))
                    }
                    _ = try await ASCClient.createVersionLocalization(versionId: versionId, locale: code)
                    out.added.append(loc)
                } catch let e as ASCClient.APIError where e.status == 409 && e.body.contains("already exists") {
                    // 409 "Entity with locale: zh-Hant already exists" — 우리가 본 목록이 낡았을 뿐 언어는 있다.
                    // 실패로 치면 부르는 쪽이 목록을 다시 읽지 않아, 있는 언어의 릴리즈노트를 버리고
                    // 게이트에서 '비어 있음' 으로 배포가 멈춘다 (욕망의 무지개 1.1.9, 2026-10-02).
                    out.added.append(loc)
                } catch {
                    out.failed.append("\(label)(\(code)) 추가 실패 — \(reason(error))")
                }
            }
        } catch {
            out.failed = want.map { "\(Locales.displayName($0)) 추가 실패 — \(reason(error))" }
        }
        return out
    }

    // ── 수출 규정 준수(암호화) ──────────────────────────────────────────
    /// 답이 비었을 때 사람이 할 일. 배포 앞의 미리 확인과 제출 단계가 같은 말을 한다.
    static let encryptionTodo = [
        "HTTPS·iCloud 처럼 운영체제 암호화만 쓰면 면제 대상입니다 — 그렇다면 둘 중 하나를 하세요",
        "deploy.env 에 ENCRYPTION_EXEMPT=yes 를 적으면 이번 빌드부터 DeployBar 가 '면제' 로 답합니다 → [심사 제출] 만 다시 누르면 됩니다",
        "또는 Info.plist 에 ITSAppUsesNonExemptEncryption = NO 를 넣으면 다음 빌드부터 애플이 묻지 않습니다",
        "자체 암호화를 쓴다면 App Store Connect ▸ TestFlight ▸ 빌드에서 '수출 규정 준수 정보' 에 직접 답하세요",
    ]

    /// 이 앱이 암호화 질문에 미리 답해 두었나 — 업로드 **전에** 알 수 있는 것.
    /// Info.plist 나 빌드 설정에 키가 있거나, deploy.env 에 선언이 있으면 답이 준비된 것이다.
    /// 예전엔 이걸 심사 제출 직전에야 봐서, 빌드·업로드·처리 대기 7분을 다 쓰고 막혔다.
    static func encryptionAnswered(_ r: ResolvedApp) -> Bool {
        if r.encryptionExempt != nil { return true }
        let fm = FileManager.default
        let key = "ITSAppUsesNonExemptEncryption"
        guard let e = fm.enumerator(atPath: r.path) else { return false }
        while let f = e.nextObject() as? String {
            // build/·DerivedData·Pods 는 볼 필요가 없다 (산출물·남의 코드)
            let name = (f as NSString).lastPathComponent
            if ["build", "DerivedData", "Pods", ".git", "node_modules", "fastlane"].contains(name) {
                e.skipDescendants(); continue
            }
            guard f.hasSuffix(".plist") || f.hasSuffix("project.pbxproj") || f.hasSuffix(".xcconfig") else { continue }
            if let s = try? String(contentsOfFile: (r.path as NSString).appendingPathComponent(f), encoding: .utf8),
               s.contains(key) { return true }
        }
        return false
    }

    // ── 심사 제출 / 출시 ────────────────────────────────────────────────
    /// 심사 제출. **여기서부터 애플이 본다** — 부르는 쪽이 사람의 뜻을 확인하고 불러야 한다.
    static func submit(_ app: ManagedApp, onLog: @escaping (String) -> Void = { _ in }) async throws -> String {
        let r = AppRepo.resolve(app)
        let info = try AppRepo.buildSettings(r)
        guard let appId = try await ASCClient.appId(bundleId: info.bundleId) else {
            throw err(app, "심사 제출", "App Store Connect 에서 앱을 찾지 못했습니다", [])
        }
        let versions = try await ASCClient.appStoreVersions(appId: appId)
        guard let v = versions.first(where: { ReleaseNotes.editableStates.contains($0.state) }) else {
            throw err(app, "심사 제출", "제출할 수 있는 버전이 없습니다",
                      ["이미 심사 중이거나 판매 중입니다 — 새 버전을 먼저 만드세요"])
        }
        guard v.hasBuild else {
            throw err(app, "심사 제출", "v\(v.versionString) 에 빌드가 연결돼 있지 않습니다",
                      ["[빌드 연결] 을 먼저 누르세요 — 빌드 없는 버전은 제출되지 않습니다"])
        }
        // 수출 규정 준수 답이 비어 있으면 버전을 묶음에 넣는 단계에서 409 로 막힌다.
        // 답은 법적 진술이라 **사람이 선언한 것만** 적는다 (deploy.env 의 ENCRYPTION_EXEMPT).
        // 선언이 없으면 대신 적지 않고, 어디서 적는지 알려 준다.
        let enc = try await ASCClient.buildEncryptionAnswer(versionId: v.id)
        if enc.answer == nil {
            if r.encryptionExempt == true, let buildId = enc.buildId {
                try await ASCClient.setBuildEncryption(buildId: buildId, usesNonExempt: false)
                onLog("🔐 수출 규정 준수: '면제 대상' 으로 답했습니다 (ENCRYPTION_EXEMPT=yes)")
            } else {
                throw err(app, "심사 제출", "빌드의 수출 규정 준수(암호화) 답이 비어 있습니다",
                          StorePublish.encryptionTodo)
            }
        }
        let submissionId: String
        if let open = try await ASCClient.openSubmission(appId: appId) {
            if open.submitted {
                throw err(app, "심사 제출", "이미 제출돼 있습니다 (\(open.state))",
                          ["결과를 기다리세요 — 다시 내려면 심사를 먼저 취소해야 합니다"])
            }
            submissionId = open.id
            onLog("📮 만들다 만 제출 묶음을 이어서 씁니다")
        } else {
            submissionId = try await ASCClient.createSubmission(appId: appId, platform: info.platform)
            onLog("📮 제출 묶음 생성")
        }
        do {
            try await ASCClient.addVersionToSubmission(submissionId: submissionId, versionId: v.id)
        } catch let e as ASCClient.APIError where e.status == 409 {
            onLog("📮 v\(v.versionString) 는 이미 묶음에 들어 있습니다")
        }
        // 준비된 인앱 구매를 같이 싣는다. 버전만 내면 심사자가 페이월에서 상품을 못 봐
        // 거절될 수 있으므로, 싣지 못하면 **제출하지 않고** 멈춘다 (버전은 묶음에 남아 있다).
        for purchase in (try? await ASCClient.purchasesReadyToSubmit(appId: appId)) ?? [] {
            do {
                try await ASCClient.submitPurchase(id: purchase.id)
                onLog("🛒 인앱 구매 \(purchase.productId) 를 함께 싣습니다")
            } catch let e as ASCClient.APIError where e.status == 409 && e.body.contains("no pending version") {
                throw err(app, "심사 제출", "첫 인앱 구매(\(purchase.productId))는 웹에서 버전과 함께 골라야 합니다", [
                    "App Store Connect ▸ 앱 ▸ v\(v.versionString) ▸ '인앱 구입 및 구독' 에서 \(purchase.productId) 를 고르세요",
                    "그 페이지의 [심사에 추가] → [심사 제출] 을 누르면 됩니다 — 버전과 빌드는 이미 묶음에 들어 있습니다",
                    "Apple API 는 앱의 첫 인앱 구매를 버전에 붙이지 못합니다. 두 번째부터는 DeployBar 가 같이 냅니다",
                ])
            }
        }
        try await ASCClient.submit(submissionId: submissionId)
        onLog("✅ v\(v.versionString) 심사 제출 완료")
        return "v\(v.versionString) 를 심사에 제출했습니다"
    }

    /// '출시 대기' 를 실제 출시로 — 웹의 [출시] 버튼과 같다.
    static func release(_ app: ManagedApp) async throws -> String {
        let r = AppRepo.resolve(app)
        let info = try AppRepo.buildSettings(r)
        guard let appId = try await ASCClient.appId(bundleId: info.bundleId) else {
            throw err(app, "출시", "App Store Connect 에서 앱을 찾지 못했습니다", [])
        }
        let versions = try await ASCClient.appStoreVersions(appId: appId)
        guard let v = versions.first(where: { $0.state == "PENDING_DEVELOPER_RELEASE" }) else {
            throw err(app, "출시", "출시를 기다리는 버전이 없습니다",
                      ["심사를 통과해 '출시 대기' 가 된 버전만 출시할 수 있습니다"])
        }
        try await ASCClient.releaseVersion(versionId: v.id)
        return "v\(v.versionString) 출시를 요청했습니다 — 몇 분 뒤 스토어에 반영됩니다"
    }

    /// 빌드 연결 하나만 (체크리스트의 [빌드 연결] 버튼).
    static func attachBuild(_ app: ManagedApp) async throws -> String {
        var o = Options()
        o.text = false; o.screenshots = false; o.previews = false; o.creatives = false; o.ageRating = false; o.createVersion = false
        let rep = try await run(app, options: o)
        if let w = rep.warnings.first, rep.changed.isEmpty { return w }
        return rep.changed.first ?? "이미 연결돼 있습니다"
    }

    // ── 누가 무엇을 해야 하나 ───────────────────────────────────────────
    /// 스토어 쪽을 **한 번** 훑어, 남은 일을 도구 몫과 사람 몫으로 가른다.
    ///
    /// 이 구분이 중요한 이유: 이제 대부분을 도구가 하므로, 남은 몇 가지가 정말 사람 몫인지
    /// 아니면 버튼을 안 누른 것뿐인지가 헷갈린다. 헷갈리면 사람은 둘 다 안 한다.
    ///
    /// 조회를 한 함수에 모은 이유도 같다 — 체크리스트·`--todo`·배포 끝 안내가 각자 물어보면
    /// 같은 질문을 세 번 하게 되고, 답이 서로 어긋나면 그게 더 나쁘다.
    struct StoreState {
        var isFirstRelease = false
        /// 스토어 페이지에서 비어 있는 칸 (체크리스트가 한 줄로 요약한다)
        var gaps: [String] = []
        /// DeployBar 가 버튼 하나로 할 수 있는 것
        var mine: [String] = []
        /// 사람이 App Store Connect 웹에서만 할 수 있는 것
        var human: [String] = []
        /// human 중에서 **확실히 제출을 막는 것**. 자동 제출은 이게 비었을 때만 낸다.
        /// (개인정보 라벨은 API 로 확인할 수 없어 여기 넣지 않는다 — 내 보고 애플이 거절하면 그때 말한다)
        var blocking: [String] = []
    }

    static func inspect(_ app: ManagedApp) async -> StoreState {
        let r = AppRepo.resolve(app)
        guard let info = try? AppRepo.buildSettings(r) else { return StoreState() }
        guard let appId = try? await ASCClient.appId(bundleId: info.bundleId) else {
            var st = StoreState()
            st.human.append("App Store Connect 에 \(info.bundleId) 로 앱 만들기 — API 에 없는 단 하나의 단계입니다")
            return st
        }
        let vers = (try? await ASCClient.appStoreVersions(appId: appId)) ?? []
        return await inspect(app, appId: appId, versions: vers)
    }

    static func inspect(_ app: ManagedApp, appId: String,
                        versions: [ASCClient.Version]) async -> StoreState {
        var st = StoreState()
        st.isFirstRelease = !versions.contains { $0.state == "READY_FOR_SALE" }
        guard let v = versions.first(where: { ReleaseNotes.editableStates.contains($0.state) }) else {
            st.mine.append("편집 가능한 버전 만들기 — [스토어 올리기] 가 만듭니다")
            return st
        }
        if !v.hasBuild { st.mine.append("v\(v.versionString) 에 빌드 연결 — 배포가 애플 처리를 기다렸다가 붙입니다") }

        let texts = (try? await ASCClient.storeTexts(versionId: v.id)) ?? []
        guard !texts.isEmpty else {
            st.gaps.append("스토어 페이지 언어가 하나도 없음")
            return st
        }
        let repoMeta = StoreMeta.read(app.path, locales: texts.map(\.locale))
        func names(_ list: [ASCClient.StoreText]) -> String {
            list.prefix(3).map { Locales.displayName($0.locale) }.joined(separator: ", ")
                + (list.count > 3 ? " 외" : "")
        }
        let noDesc = texts.filter { !$0.hasDescription }
        let noKey = texts.filter { !$0.hasKeywords }
        if !noDesc.isEmpty { st.gaps.append("설명 없음(\(names(noDesc)))") }
        if !noKey.isEmpty { st.gaps.append("키워드 없음(\(names(noKey)))") }
        if !noDesc.isEmpty || !noKey.isEmpty {
            st.mine.append(repoMeta == nil
                ? "설명·키워드 — APPSTORE.md 에 쓰면 [스토어 올리기] 가 올립니다"
                : "설명·키워드 — [스토어 올리기] 로 반영하세요")
        }
        if let first = texts.first {
            let sets = (try? await ASCClient.shotSets(localizationId: first.id)) ?? []
            if sets.reduce(0, { $0 + $1.shots.count }) == 0 {
                st.gaps.append("스크린샷 없음")
                st.mine.append(hasShots(app.path)
                    ? "스크린샷 — 레포에 있습니다. [스토어 올리기] 가 올립니다"
                    : "스크린샷 — 먼저 찍어야 합니다 (`--shots \(app.name)` 지시문)")
            }
        }
        if let appInfo = try? await ASCClient.appInfo(appId: appId),
           (try? await ASCClient.ageRatingDone(appInfoId: appInfo.id)) == false {
            st.gaps.append("연령 등급 미작성")
            if repoMeta?.ageRatingNone == true {
                st.mine.append("연령 등급 '해당 없음' 신고 — [스토어 올리기] 가 합니다")
            } else {
                let line = "연령 등급 설문 — 애플에 하는 내용 신고라 사람이 판단합니다 (전부 '해당 없음' 이면 APPSTORE.md 의 `## 연령 등급` 절에 적어 두면 다음부터 자동)"
                st.human.append(line); st.blocking.append(line)
            }
        }
        if let wanted = iapProductIds(app.path), !wanted.isEmpty {
            let have = Set((try? await ASCClient.inAppPurchaseIds(appId: appId)) ?? [])
            let missing = wanted.filter { !have.contains($0) }
            if !missing.isEmpty {
                let line = "인앱결제 만들기 — \(missing.joined(separator: ", ")) · 값이 돈이라 도구가 정하지 않습니다. 없으면 페이월이 빈 화면으로 뜨고 심사도 막힙니다"
                st.human.append(line); st.blocking.append(line)
            }
        }
        // 가격·판매 지역·개인정보 라벨은 한 번 정하면 다음 버전부터 따라오므로 첫 출시에만 묻는다
        if st.isFirstRelease {
            if await !ASCClient.priceSet(appId: appId) {
                st.human.append("가격 정하기 — 무료인지 얼마인지는 사람이 정합니다")
                st.blocking.append("가격 정하기")
            }
            if await !ASCClient.availabilitySet(appId: appId) {
                st.human.append("판매 지역 고르기")
                st.blocking.append("판매 지역 고르기")
            }
            st.human.append("앱 개인정보(데이터 수집) 라벨 — 공개 API 에 없습니다. 한 번 답하면 다음 버전부터 따라옵니다")
        }
        if AppRepo.resolve(app).autoSubmit {
            st.mine.append(st.blocking.isEmpty
                ? "심사 제출 — 배포가 끝나면 DeployBar 가 냅니다"
                : "심사 제출 — 아래 사람 몫이 끝나면 다음 배포에서 DeployBar 가 냅니다")
        } else {
            st.human.append("심사 제출 버튼 누르기 — deploy.env 에 AUTO_SUBMIT=off 라 사람이 냅니다 (`--submit \(app.name)` 으로 도구가 눌러 줄 수는 있습니다)")
        }
        return st
    }

    // ── 그림 찾기 ───────────────────────────────────────────────────────
    private static let shotDirs = ["docs/screenshots", "screenshots", "fastlane/screenshots", "docs/스크린샷"]
    private static let imageExts: Set<String> = ["png", "jpg", "jpeg"]

    /// 이 앱에 올릴 그림이 있나 — 배포가 스크린샷 칸을 돌릴지 정하는 기준.
    static func hasShots(_ root: String) -> Bool {
        guard let dir = shotDir(root) else { return false }
        return !resolveShots(dir, locales: []).isEmpty
    }

    /// 그림을 두는 곳. 여러 곳을 읽어 주되 **새로 만들 때는 늘 첫 번째**다 —
    /// 앱마다 다른 곳에 쌓이면 "찍어 줘" 라고 할 때마다 어디에 뒀는지를 사람이 기억해야 한다.
    static let canonicalShotDir = "docs/screenshots"

    static func shotDir(_ root: String) -> URL? {
        let fm = FileManager.default
        return shotDirs.map { (root as NSString).appendingPathComponent($0) }
            .first { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func images(in dir: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return names.filter { imageExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { dir.appendingPathComponent($0) }
    }

    /// 그림이 어디에 있나 — **관리 중인 레포들이 실제로 쓰는 모양을 그대로** 받아들인다.
    ///
    ///   docs/screenshots/01-….png            원본 캡처만 있는 앱 (두번알림·세끼)
    ///   docs/screenshots/ko/01-….png          언어별 (징검돌·StickyPresenter)
    ///   docs/screenshots/marketing/ko/…       제출본이 따로 (돈꼬마트)
    ///   docs/screenshots/marketing-ko/…       제출본 + 언어가 이름에 (불타는내인생)
    ///   docs/screenshots/appstore-65/…        제출본 한 벌 (두번알림)
    ///
    /// **제출본이 있으면 제출본이 이긴다.** 이게 이 함수의 핵심이다 —
    /// 원본 캡처(1320×2868 시뮬레이터 출력)와 헤드라인을 붙인 제출본이 한 폴더 안에
    /// 같이 있는 앱이 대부분인데, 스토어에 올라가야 하는 것은 언제나 제출본이다.
    /// 규격만 보고 고르면 둘 다 규격이라 원본이 올라가는 사고가 난다.
    ///
    /// 반환: 로케일 → 파일들. 키가 `""` 면 "모든 언어에 같은 벌".
    ///
    /// **워치 폴더(`watch/`)는 따로 읽어 합친다.** 아이폰 쪽에 제출본 폴더가 있으면 그것만 보는
    /// 규칙 때문에, 같이 두면 워치 그림이 통째로 빠진다. 안쪽 모양(`watch/ko/`, `watch/marketing/`)은
    /// 아이폰과 같은 규칙으로 읽고, 어느 기기 자리에 갈지는 나중에 픽셀이 가른다.
    static func resolveShots(_ dir: URL, locales: [String]) -> [String: [URL]] {
        let watchDirs = subdirectories(dir).filter { isWatchName($0.lastPathComponent) }
        var out = resolveDeviceShots(dir, locales: locales, excluding: watchDirs)
        for w in watchDirs {
            out = mergeShots(out, resolveDeviceShots(w, locales: locales, excluding: []))
        }
        return out
    }

    /// 두 벌을 언어별로 합친다. 한쪽에만 언어 폴더가 있으면 다른 쪽의 "모든 언어" 벌을 그 언어에 붙인다 —
    /// 그러지 않으면 `watch/ko/` 가 생기는 순간 한국어 칸이 아이폰 공용 벌을 잃는다.
    static func mergeShots(_ a: [String: [URL]], _ b: [String: [URL]]) -> [String: [URL]] {
        func pick(_ m: [String: [URL]], _ loc: String) -> [URL] {
            m.first { !$0.key.isEmpty && Locales.sameLanguage($0.key, loc) }?.value ?? m[""] ?? []
        }
        var keys: [String] = []
        for k in a.keys.sorted() + b.keys.sorted() where !k.isEmpty
            && !keys.contains(where: { Locales.sameLanguage($0, k) }) { keys.append(k) }
        var out: [String: [URL]] = [:]
        let shared = (a[""] ?? []) + (b[""] ?? [])
        if !shared.isEmpty { out[""] = shared }
        for k in keys {
            let files = pick(a, k) + pick(b, k)
            if !files.isEmpty { out[k] = files }
        }
        return out
    }

    private static func isWatchName(_ name: String) -> Bool {
        let n = Locales.normalizeName(name)
        return n.contains("watch") || n.contains("워치")
    }

    private static func resolveDeviceShots(_ dir: URL, locales: [String], excluding: [URL]) -> [String: [URL]] {
        let subs = subdirectories(dir).filter { !excluding.contains($0) }

        // 1) 제출본 폴더가 있으면 그것만 본다
        let submission = subs.filter { isSubmissionName($0.lastPathComponent) }
        if !submission.isEmpty {
            var out: [String: [URL]] = [:]
            for d in submission {
                // 안쪽에 언어 폴더가 있으면 그쪽이 더 구체적이다 (marketing/ko/)
                var nested = false
                for inner in subdirectories(d) {
                    guard let loc = localeName(inner.lastPathComponent, locales: locales) else { continue }
                    let files = images(in: inner)
                    if !files.isEmpty { out[loc] = files; nested = true }
                }
                if nested { continue }
                let files = images(in: d)
                if files.isEmpty { continue }
                // 이름에 언어가 붙어 있으면 그 언어 (marketing-ko), 아니면 모든 언어 (appstore-65)
                out[localeSuffix(d.lastPathComponent, locales: locales) ?? ""] = files
            }
            if !out.isEmpty { return out }
        }

        // 2) 언어 폴더
        var byLocale: [String: [URL]] = [:]
        for d in subs {
            guard let loc = localeName(d.lastPathComponent, locales: locales) else { continue }
            let files = images(in: d)
            if !files.isEmpty { byLocale[loc] = files }
        }
        if !byLocale.isEmpty { return byLocale }

        // 3) 폴더 바로 아래
        let flat = images(in: dir)
        return flat.isEmpty ? [:] : ["": flat]
    }

    /// 스토어에 낼 그림이 든 폴더의 이름인가. `raw`·`seed` 같은 원본 폴더는 여기 안 걸린다.
    private static func isSubmissionName(_ name: String) -> Bool {
        let n = Locales.normalizeName(name)
        return ["marketing", "appstore", "submit", "store", "제출", "final"].contains { n.contains($0) }
    }

    private static func localeName(_ name: String, locales: [String]) -> String? {
        if Locales.looksLikeCode(name) { return name }
        return Locales.match(heading: name, among: locales)
    }

    /// `marketing-ko` → `ko`, `appstore-65` → nil
    private static func localeSuffix(_ name: String, locales: [String]) -> String? {
        for part in name.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." }).dropFirst() {
            if let loc = localeName(String(part), locales: locales) { return loc }
        }
        return nil
    }

    private static func subdirectories(_ dir: URL) -> [URL] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted().compactMap { name in
            var isDir: ObjCBool = false
            let p = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue,
                  !name.hasPrefix(".") else { return nil }
            return p
        }
    }

    /// 그림 묶음을 **크기로** 기기별로 가른다. 파일 이름은 믿지 않는다 —
    /// 시뮬레이터가 뱉는 이름은 제각각이고, 규격에 맞지 않는 그림은 애플이 통째로 거부한다.
    /// 업로드와 점검(`--shotplan`)이 같은 함수를 쓴다 — 갈라지면 "점검은 통과했는데 올라가진 않는다" 가 된다.
    static func group(_ files: [URL], platform: Platform)
        -> (byType: [String: [URL]], skipped: [String]) {
        var byType: [String: [URL]] = [:]
        var skipped: [String] = []
        for f in files {
            guard let size = pixelSize(f) else {
                skipped.append("\(f.lastPathComponent) 는 크기를 읽지 못해 건너뜁니다")
                continue
            }
            guard let type = displayType(w: size.w, h: size.h, platform: platform) else {
                skipped.append("\(f.lastPathComponent) \(size.w)×\(size.h) 은 App Store 규격이 아닙니다 — 건너뜁니다")
                continue
            }
            byType[type, default: []].append(f)
        }
        return (byType, skipped)
    }

    /// 네트워크 없이 "무엇이 어느 자리에 올라갈까" 만 보여 준다 (`--shotplan`).
    /// 올리기 전에 규격을 틀렸는지 알 수 있어야, 배포 중에 처음 알게 되지 않는다.
    struct PlanRow { let locale: String; let type: String; let files: [URL] }
    static func shotPlan(_ root: String, platform: Platform, locales: [String])
        -> (rows: [PlanRow], skipped: [String], dir: URL?) {
        guard let dir = shotDir(root) else { return ([], [], nil) }
        var rows: [PlanRow] = []
        var skipped: [String] = []
        for (loc, files) in resolveShots(dir, locales: locales).sorted(by: { $0.key < $1.key }) {
            let g = group(files, platform: platform)
            skipped += g.skipped
            for (type, fs) in g.byType.sorted(by: { $0.key < $1.key }) {
                rows.append(PlanRow(locale: loc.isEmpty ? "모든 언어" : loc, type: type,
                                    files: fs.sorted { $0.lastPathComponent < $1.lastPathComponent }))
            }
        }
        return (rows, skipped, dir)
    }

    /// 카드 뱃지용 요약. `shotPlan` 을 그대로 줄인 것이라 업로드와 판단이 갈라지지 않는다.
    static func shotReport(_ root: String, platform: Platform, locales: [String]) -> ShotReport? {
        let plan = shotPlan(root, platform: platform, locales: locales)
        guard plan.dir != nil else { return nil }
        var rep = ShotReport()
        rep.skipped = plan.skipped
        for row in plan.rows {
            let family = deviceFamily(row.type)
            rep.devices[family] = max(rep.devices[family] ?? 0, row.files.count)
            if family == "iPhone" || family == "Mac" { rep.hasPrimary = true }
        }
        let shared = plan.rows.contains { $0.locale == "모든 언어" }
        if !shared {
            rep.missingLocales = locales.filter { want in
                !plan.rows.contains { Locales.sameLanguage($0.locale, want) }
            }
        }
        return rep
    }

    /// `APP_IPHONE_65` → `iPhone`. 뱃지는 기기 묶음으로만 말한다 — 인치까지 적으면 카드가 넘친다.
    static func deviceFamily(_ type: String) -> String {
        if type.hasPrefix("APP_WATCH") { return "Watch" }
        if type.hasPrefix("APP_IPAD") { return "iPad" }
        if type == "APP_DESKTOP" { return "Mac" }
        return "iPhone"
    }

    private static func pixelSize(_ url: URL) -> (w: Int, h: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private static func fileSize(_ url: URL) -> Int {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// 픽셀 크기 → App Store 가 부르는 기기 이름.
    /// 파일 이름을 믿지 않는 이유: 시뮬레이터에서 찍으면 이름이 제각각이고,
    /// 규격에 안 맞는 그림은 애플이 통째로 거부하므로 크기가 유일한 진실이다.
    static func displayType(w: Int, h: Int, platform: Platform) -> String? {
        let (a, b) = (min(w, h), max(w, h))    // 가로/세로 둘 다 같은 규격이다
        if platform == .macOS {
            let ok = [(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)]
            return ok.contains { $0.0 == b && $0.1 == a } ? "APP_DESKTOP" : nil
        }
        switch (a, b) {
        case (1320, 2868), (1290, 2796), (1284, 2778):  return "APP_IPHONE_67"   // 6.9"·6.7"
        case (1242, 2688), (1242, 2689):                return "APP_IPHONE_65"
        case (1206, 2622), (1179, 2556), (1170, 2532):  return "APP_IPHONE_61"
        case (1125, 2436), (1080, 2340):                return "APP_IPHONE_58"
        case (1242, 2208):                              return "APP_IPHONE_55"
        case (750, 1334):                               return "APP_IPHONE_47"
        case (2064, 2752), (2048, 2732):                return "APP_IPAD_PRO_3GEN_129"
        case (1668, 2420), (1668, 2388):                return "APP_IPAD_PRO_3GEN_11"
        case (1640, 2360), (1620, 2160):                return "APP_IPAD_109"
        // Apple Watch — 같은 iOS 버전 페이지의 워치 칸에 들어간다
        case (410, 502):                                return "APP_WATCH_ULTRA"
        case (416, 496), (374, 446):                    return "APP_WATCH_SERIES_10"
        case (396, 484), (352, 430):                    return "APP_WATCH_SERIES_7"
        case (368, 448), (324, 394):                    return "APP_WATCH_SERIES_4"
        case (312, 390), (272, 340):                    return "APP_WATCH_SERIES_3"
        default: return nil
        }
    }

    static func typeLabel(_ t: String) -> String {
        switch t {
        case "APP_IPHONE_67": return "iPhone 6.9\""
        case "APP_IPHONE_65": return "iPhone 6.5\""
        case "APP_IPHONE_61": return "iPhone 6.1\""
        case "APP_IPHONE_58": return "iPhone 5.8\""
        case "APP_IPHONE_55": return "iPhone 5.5\""
        case "APP_IPHONE_47": return "iPhone 4.7\""
        case "APP_IPAD_PRO_3GEN_129": return "iPad 13\""
        case "APP_IPAD_PRO_3GEN_11": return "iPad 11\""
        case "APP_IPAD_109": return "iPad 10.9\""
        case "APP_WATCH_ULTRA": return "Apple Watch Ultra"
        case "APP_WATCH_SERIES_10": return "Apple Watch 46mm"
        case "APP_WATCH_SERIES_7": return "Apple Watch 45mm"
        case "APP_WATCH_SERIES_4": return "Apple Watch 44mm"
        case "APP_WATCH_SERIES_3": return "Apple Watch 42mm"
        case "APP_DESKTOP": return "Mac"
        default: return t
        }
    }

    static func rel(_ url: URL, _ root: String) -> String {
        url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count + 1)) : url.path
    }

    static func reason(_ error: Error) -> String {
        if let e = error as? ASCClient.APIError {
            // 애플의 오류 본문에서 사람이 읽을 한 줄만 꺼낸다
            if let d = e.body.data(using: .utf8),
               let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let errs = j["errors"] as? [[String: Any]], let first = errs.first {
                let title = first["title"] as? String ?? ""
                let detail = first["detail"] as? String ?? ""
                return "HTTP \(e.status) · \(detail.isEmpty ? title : detail)"
            }
            return "HTTP \(e.status)"
        }
        return error.localizedDescription
    }

    private static func err(_ app: ManagedApp, _ stage: String, _ title: String,
                            _ todo: [String], detail: String = "") -> DeployError {
        DeployError(app: app.name, path: app.path, stage: stage, title: title,
                    todo: todo, detail: detail)
    }
}

// ── 업로드 뒤 끝까지: 빌드 연결 → 심사 제출 ──────────────────────────────
//
// 예전엔 배포가 업로드에서 끝났다. 그 뒤 "애플 처리가 끝날 때까지 몇 분 기다렸다가
// [빌드 연결] 을 누르고, [심사 제출] 을 누르는" 두 번의 클릭이 사람 몫으로 남았는데,
// 둘 다 판단이 필요 없는 일이다 — 기다리는 것과 누르는 것뿐이다.
// 판단이 필요한 것(인앱결제 값, 연령 등급 신고, 가격)이 남아 있으면 내지 않고 그걸 말한다.
extension StorePublish {
    struct Finish {
        var attached = false
        var submitted = false
        /// 사람이 해야 해서 제출을 멈춘 이유 (비면 막힌 게 없었다)
        var blockers: [String] = []
        /// 알림에 쓸 한 줄
        var summary = ""
        /// 심사에 내지 **못한** 이유. nil 이면 제출했거나, AUTO_SUBMIT=off 로 일부러 안 낸 것.
        /// 배포의 최종 판정(성공/미완)이 이 값 하나로 갈린다 — '업로드 성공' 과 '배포 성공' 은 다르다.
        var unfinished: String?
    }

    /// 방금 올린 빌드를 심사 제출까지 민다. 칸은 onStage 로 보고한다.
    /// 던지지 않는다 — 업로드는 이미 됐으니, 멈춘 칸과 이유를 남기면 그걸로 충분하다.
    static func finish(_ app: ManagedApp, version: String, build: Int,
                       onLog: @escaping @Sendable (String) -> Void,
                       onStage: @escaping Deployer.StageReport) async -> Finish {
        var out = Finish()
        let r = AppRepo.resolve(app)
        func stop(_ note: String) -> Finish {
            onStage(.attach, .failed, note)
            onStage(.submit, .skipped, "빌드를 붙이지 못해 건너뜀")
            onLog("⚠️  빌드 연결 실패 — \(note)")
            out.summary = "업로드는 됐지만 빌드 연결에서 멈춤 — \(note)"
            out.unfinished = "빌드 연결 실패 — \(note)"
            return out
        }
        onStage(.attach, .running, nil)
        guard let info = try? AppRepo.buildSettings(r),
              let appId = try? await ASCClient.appId(bundleId: info.bundleId) else {
            return stop("App Store Connect 에서 앱을 찾지 못했습니다")
        }

        // 1) 애플 처리 기다리기 — 이 빌드 번호 **그 자체**가 VALID 가 될 때까지.
        //    처리 중에 '고를 수 있는 아무 빌드' 를 붙이면 지난 바이너리가 심사에 나간다.
        onLog("⏳ 애플이 build \(build) 를 처리하길 기다립니다 (보통 5~20분, 최대 1시간)")
        let started = Date()
        var ref: ASCClient.BuildRef?
        while true {
            ref = try? await ASCClient.build(appId: appId, marketingVersion: version, number: build)
            if ref?.state == "VALID" { break }
            if let st = ref?.state, ["INVALID", "FAILED"].contains(st) {
                return stop("애플이 build \(build) 를 받지 않았습니다 (\(st)) — 사유는 개발자 계정 메일로 옵니다")
            }
            let waited = Date().timeIntervalSince(started)
            if waited > 60 * 60 {
                return stop("1시간이 지나도 처리가 끝나지 않았습니다 — 나중에 ⋯ ▸ 스토어 페이지 ▸ [빌드 연결]")
            }
            if Task.isCancelled { return stop("중단됨") }
            let mins = Int(waited / 60)
            onStage(.attach, .running, ref == nil
                ? "build \(build) 가 목록에 뜨길 기다리는 중 · \(mins)분째"
                : "애플이 build \(build) 를 처리하는 중 · \(mins)분째")
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
        guard let ref else { return stop("빌드를 찾지 못했습니다") }
        onLog("✅ build \(build) 처리 완료 (\(Int(Date().timeIntervalSince(started) / 60))분)")

        // 2) 버전 — 배포 앞에서 맞춰 뒀지만, 그때 못 만들었거나 번호를 못 바꿨으면 여기서 다시
        let versionId: String
        do {
            let versions = try await ASCClient.appStoreVersions(appId: appId)
            if let v = versions.first(where: { ReleaseNotes.editableStates.contains($0.state) }) {
                if v.versionString != version {
                    try await ASCClient.updateVersionString(versionId: v.id, to: version)
                    onLog("🔗 스토어 버전 번호 v\(v.versionString) → v\(version)")
                }
                versionId = v.id
            } else {
                versionId = try await ASCClient.createVersion(appId: appId, versionString: version,
                                                              platform: info.platform).id
                onLog("🆕 스토어에 v\(version) 버전을 만들었습니다")
            }
            // 이미 다른(지난) 빌드가 붙어 있어도 이번 빌드로 바꾼다 — 방금 올린 게 이번 버전이다
            try await ASCClient.attachBuild(versionId: versionId, buildId: ref.id)
            onLog("🔧 build \(build) 를 v\(version) 에 붙였습니다")
            out.attached = true
        } catch {
            return stop(reason(error))
        }

        // 문구·연령 등급 — APPSTORE.md 에 적은 것만, 스토어에 이미 있는 글은 덮지 않는다
        var o = Options()
        o.attachBuild = false; o.screenshots = false; o.previews = false; o.creatives = false; o.createVersion = false; o.manualCheck = false
        if let rep = try? await run(app, options: o, onLog: onLog) {
            for w in rep.warnings { onLog("   ⚠️  \(w)") }
        }
        onStage(.attach, .done, "build \(build) → v\(version)")

        // 3) 심사 제출
        onStage(.submit, .running, nil)
        guard r.autoSubmit else {
            onStage(.submit, .skipped, "AUTO_SUBMIT=off — 제출은 사람이 합니다")
            out.summary = "v\(version) build \(build) 연결 완료 — 제출은 사람이 (AUTO_SUBMIT=off)"
            return out
        }
        let versions = (try? await ASCClient.appStoreVersions(appId: appId)) ?? []
        let state = await inspect(app, appId: appId, versions: versions)
        var blockers = state.blocking
        if let n = try? await ReleaseNotes.notesState(versions: versions), !n.firstRelease, !n.missing.isEmpty {
            let names = n.missing.prefix(3).map { Locales.displayName($0) }.joined(separator: ", ")
            blockers.append("릴리즈노트가 빈 언어 — \(names)\(n.missing.count > 3 ? " 외" : "") · [릴리즈노트] 창에서 채우세요")
        }
        if !blockers.isEmpty {
            out.blockers = blockers
            let head = blockers[0].components(separatedBy: " — ").first ?? blockers[0]
            onStage(.submit, .skipped, "사람 몫 \(blockers.count)가지가 남아 내지 않았습니다 — \(head)\(blockers.count > 1 ? " 외" : "")")
            onLog("🙋 심사에 내지 않았습니다 — 사람이 먼저 해야 하는 일:")
            for (i, b) in blockers.enumerated() { onLog("   \(i + 1)) \(b)") }
            onLog("   · 끝내고 다시 배포하거나 `DeployBar --submit \(app.name)` 으로 내면 됩니다")
            out.summary = "v\(version) 연결까지 — 사람 몫 \(blockers.count)가지가 남아 제출하지 않았습니다"
            out.unfinished = "사람이 할 일 \(blockers.count)가지가 남아 심사에 내지 않음 — \(head)"
            return out
        }
        // 심사를 통과한 뒤 '출시 대기' 에서 또 사람을 기다리지 않게
        do {
            try await ASCClient.setReleaseType(versionId: versionId, afterApproval: r.autoRelease)
            onLog(r.autoRelease ? "🚦 심사를 통과하면 바로 출시되게 했습니다"
                                : "🚦 심사를 통과해도 [출시] 는 사람이 누릅니다 (AUTO_RELEASE=off)")
        } catch {
            onLog("⚠️  출시 방식을 정하지 못했습니다 — \(reason(error)) · 스토어에 설정된 대로 갑니다")
        }
        do {
            let msg = try await submit(app, onLog: onLog)
            out.submitted = true
            let tail = r.autoRelease ? "통과하면 바로 출시" : "통과 뒤 [출시] 는 사람이"
            onStage(.submit, .done, "\(msg) · \(tail)")
            out.summary = "v\(version) (build \(build)) 심사 제출 완료 — \(tail)"
        } catch {
            let why = (error as? DeployError)?.title ?? reason(error)
            onStage(.submit, .failed, why)
            onLog("❌ 심사 제출 실패 — \(why)")
            for t in (error as? DeployError)?.todo ?? [] { onLog("   → \(t)") }
            out.summary = "v\(version) 연결까지 — 심사 제출 실패: \(why)"
            out.unfinished = "심사 제출 실패 — \(why)"
        }
        return out
    }
}
