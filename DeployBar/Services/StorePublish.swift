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
        var ageRating = true          // APPSTORE.md 가 "해당 없음" 이라고 적었을 때만
        /// 스토어에 이미 글이 있어도 레포 글로 덮어쓸지.
        /// 기본이 false 인 이유는 릴리즈노트와 같다 — 웹에서 급히 고친 문구를
        /// 도구가 말없이 되돌리면 그게 더 큰 사고다.
        var overwriteText = false
        /// 이미 올라간 그림을 지우고 다시 올릴지 (파일이 달라졌으면 어차피 다시 올린다)
        var replaceShots = false
        /// 우리가 못 하는 것(인앱결제·개인정보 라벨)까지 확인해서 알려 줄지.
        /// 배포 중에는 끈다 — 매 배포마다 같은 줄이 반복되면 로그가 무뎌진다.
        var manualCheck = true
        var dryRun = false
    }

    struct Report {
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

        // (a) 버전 문구 (설명·키워드·프로모션·URL·릴리즈노트는 여기 말고 ReleaseNotes 가 쓴다)
        var texts = try await ASCClient.storeTexts(versionId: version.id)
        for (loc, entry) in meta.entries.sorted(by: { $0.key < $1.key }) {
            let existing = texts.first { Locales.sameLanguage($0.locale, loc) }
            var target = existing
            if target == nil {
                // App Store 페이지에 없는 언어 — 만들 수 있으면 만든다.
                // (여태 "웹에서 언어를 추가하세요" 로 남겨 두던 자리다)
                if options.dryRun {
                    report.changed.append("\(Locales.displayName(loc)) 페이지 추가 (미리보기)")
                    continue
                }
                do {
                    let made = try await ASCClient.createVersionLocalization(versionId: version.id, locale: loc)
                    report.changed.append("\(Locales.displayName(loc)) 스토어 페이지 추가")
                    target = ASCClient.StoreText(id: made.id, locale: made.locale)
                    texts.append(target!)
                } catch {
                    report.warnings.append("\(Locales.displayName(loc)) 추가 실패 — \(reason(error))")
                    continue
                }
            }
            guard let t = target else { continue }
            var fields: [String: String] = [:]
            func put(_ key: String, _ new: String?, _ old: String) {
                guard let new, !new.isEmpty, new != old else { return }
                guard old.isEmpty || options.overwriteText else {
                    report.kept.append("\(Locales.displayName(loc)) \(fieldLabel(key)): 스토어 쪽 글을 그대로 뒀습니다")
                    return
                }
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
        for (loc, entry) in meta.entries.sorted(by: { $0.key < $1.key }) {
            guard entry.name != nil || entry.subtitle != nil || entry.privacyPolicyUrl != nil else { continue }
            var target = infos.first { Locales.sameLanguage($0.locale, loc) }
            if target == nil {
                guard let name = entry.name else {
                    report.warnings.append("\(Locales.displayName(loc)) 앱 정보가 없어 부제·URL 을 넣을 곳이 없습니다 — APPSTORE.md 에 `### 이름` 을 적으면 만들어 줍니다")
                    continue
                }
                if options.dryRun {
                    report.changed.append("\(Locales.displayName(loc)) 앱 이름 '\(name)' (미리보기)")
                    continue
                }
                do {
                    let made = try await ASCClient.createInfoText(appInfoId: appInfo.id, locale: loc, name: name)
                    report.changed.append("\(Locales.displayName(loc)) 앱 정보 추가 · 이름 '\(name)'")
                    target = made
                    infos.append(made)
                } catch {
                    report.warnings.append("\(Locales.displayName(loc)) 앱 정보 추가 실패 — \(reason(error))")
                    continue
                }
            }
            guard let t = target else { continue }
            var fields: [String: String] = [:]
            func put(_ key: String, _ new: String?, _ old: String) {
                guard let new, !new.isEmpty, new != old else { return }
                guard old.isEmpty || options.overwriteText else {
                    report.kept.append("\(Locales.displayName(loc)) \(fieldLabel(key)): 스토어 쪽 값을 그대로 뒀습니다")
                    return
                }
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
        guard let dir = shotDir(app.path) else { return }   // 이 워크플로를 안 쓰는 앱엔 말하지 않는다
        let texts = try await ASCClient.storeTexts(versionId: version.id)
        guard !texts.isEmpty else {
            report.warnings.append("스토어 페이지 언어가 하나도 없어 스크린샷을 올릴 자리가 없습니다")
            return
        }

        let resolved = resolveShots(dir, locales: texts.map(\.locale))
        let shared = resolved[""] ?? []
        if resolved.isEmpty {
            report.manual.append("\(rel(dir, app.path)) 에 그림이 없습니다 — `--shots \(app.name)` 지시문으로 찍으세요")
            return
        }
        if !shared.isEmpty && texts.count > 1 {
            onLog("🖼  언어별 폴더가 없어 같은 \(shared.count)장을 \(texts.count)개 언어에 올립니다")
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
            let sets = try await ASCClient.shotSets(localizationId: t.id)
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
                if same && !options.replaceShots {
                    report.kept.append("\(Locales.displayName(t.locale)) \(typeLabel(type)) \(sorted.count)장은 이미 같습니다")
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
        o.text = false; o.screenshots = false; o.ageRating = false; o.createVersion = false
        let rep = try await run(app, options: o)
        if let w = rep.warnings.first, rep.changed.isEmpty { return w }
        return rep.changed.first ?? "이미 연결돼 있습니다"
    }

    // ── 누가 무엇을 해야 하나 ───────────────────────────────────────────
    /// 제출까지 남은 일을 **도구가 할 것 / 사람만 할 수 있는 것** 으로 갈라 준다.
    ///
    /// 이 구분이 중요한 이유: 이제 대부분을 도구가 하므로, 남은 몇 가지가 정말 사람 몫인지
    /// 아니면 버튼을 안 누른 것뿐인지가 헷갈린다. 헷갈리면 사람은 둘 다 안 한다.
    struct Todo { var mine: [String] = []; var yours: [String] = [] }

    static func todo(_ app: ManagedApp) async -> Todo {
        var out = Todo()
        let r = AppRepo.resolve(app)
        guard let info = try? AppRepo.buildSettings(r) else { return out }
        guard let appId = try? await ASCClient.appId(bundleId: info.bundleId) else {
            out.yours.append("App Store Connect 에 \(info.bundleId) 로 앱 만들기 — API 에 없는 단 하나의 단계입니다")
            return out
        }
        let vers = (try? await ASCClient.appStoreVersions(appId: appId)) ?? []
        let editable = vers.first { ReleaseNotes.editableStates.contains($0.state) }
        guard let v = editable else {
            out.mine.append("편집 가능한 버전 만들기 — [스토어 올리기] 가 만듭니다")
            return out
        }
        if !v.hasBuild {
            out.mine.append("v\(v.versionString) 에 빌드 연결 — [빌드 연결]")
        }
        let texts = (try? await ASCClient.storeTexts(versionId: v.id)) ?? []
        let repoMeta = StoreMeta.read(app.path, locales: texts.map(\.locale))
        let emptyText = texts.filter { !$0.hasDescription || !$0.hasKeywords }
        if !emptyText.isEmpty {
            let names = emptyText.map { Locales.displayName($0.locale) }.joined(separator: ", ")
            out.mine.append(repoMeta == nil
                ? "설명·키워드 (\(names)) — APPSTORE.md 에 쓰면 [스토어 올리기] 가 올립니다"
                : "설명·키워드 (\(names)) — [스토어 올리기] 로 반영하세요")
        }
        if let first = texts.first {
            let sets = (try? await ASCClient.shotSets(localizationId: first.id)) ?? []
            if sets.reduce(0, { $0 + $1.shots.count }) == 0 {
                out.mine.append(hasShots(app.path)
                    ? "스크린샷 — 레포에 있습니다. [스토어 올리기] 가 올립니다"
                    : "스크린샷 — 먼저 찍어야 합니다 (`--shots \(app.name)` 지시문)")
            }
        }
        if let appInfo = try? await ASCClient.appInfo(appId: appId),
           (try? await ASCClient.ageRatingDone(appInfoId: appInfo.id)) == false {
            if repoMeta?.ageRatingNone == true {
                out.mine.append("연령 등급 '해당 없음' 신고 — [스토어 올리기] 가 합니다")
            } else {
                out.yours.append("연령 등급 설문 — 내용 신고라 사람이 판단합니다 (전부 '해당 없음' 이면 APPSTORE.md 에 적어 두면 다음부터 자동)")
            }
        }
        if let wanted = iapProductIds(app.path), !wanted.isEmpty {
            let have = Set((try? await ASCClient.inAppPurchaseIds(appId: appId)) ?? [])
            let missing = wanted.filter { !have.contains($0) }
            if !missing.isEmpty {
                out.yours.append("인앱결제 만들기 — \(missing.joined(separator: ", ")) · 가격이 걸린 값이라 도구가 정하지 않습니다")
            }
        }
        if await !ASCClient.priceSet(appId: appId) {
            out.yours.append("가격 정하기 — 무료인지 얼마인지는 사람이 정합니다")
        }
        if await !ASCClient.availabilitySet(appId: appId) {
            out.yours.append("판매 지역 고르기")
        }
        out.yours.append("앱 개인정보(데이터 수집) 라벨 — 공개 API 에 없습니다. 한 번 답하면 다음 버전부터 따라옵니다")
        out.yours.append("심사 제출 버튼 누르기 — 준비가 끝났다고 판단하는 건 사람입니다 (`--submit \(app.name)` 으로 도구가 눌러 줄 수는 있습니다)")
        return out
    }

    // ── 첫 출시에 남은 칸 ───────────────────────────────────────────────
    /// 아직 한 번도 판매된 적 없는 앱만 본다.
    ///
    /// 업데이트는 지난 버전의 설명·키워드·그림이 그대로 따라오므로 물어볼 필요가 없다.
    /// 반대로 **첫 출시는 이 칸들이 비어 있는 게 진짜로 제출을 막는 것**인데,
    /// 여태 체크리스트는 그걸 한 줄도 말하지 않았다 — 빌드는 올라갔고 릴리즈노트도 됐는데
    /// 웹에 가 보면 제출 버튼이 회색인 이유를 앱 안에서는 알 길이 없었다.
    static func firstReleaseGaps(appId: String, versions: [ASCClient.Version]) async -> [String]? {
        guard !versions.contains(where: { $0.state == "READY_FOR_SALE" }) else { return nil }
        guard let editable = versions.first(where: { ReleaseNotes.editableStates.contains($0.state) })
        else { return nil }
        var gaps: [String] = []
        let texts = (try? await ASCClient.storeTexts(versionId: editable.id)) ?? []
        if texts.isEmpty { return ["스토어 페이지 언어가 하나도 없음"] }
        func names(_ list: [ASCClient.StoreText]) -> String {
            list.prefix(3).map { Locales.displayName($0.locale) }.joined(separator: ", ")
                + (list.count > 3 ? " 외" : "")
        }
        let noDesc = texts.filter { !$0.hasDescription }
        if !noDesc.isEmpty { gaps.append("설명 없음(\(names(noDesc)))") }
        let noKey = texts.filter { !$0.hasKeywords }
        if !noKey.isEmpty { gaps.append("키워드 없음(\(names(noKey)))") }
        if let first = texts.first {
            let sets = (try? await ASCClient.shotSets(localizationId: first.id)) ?? []
            let shots = sets.reduce(0) { $0 + $1.shots.count }
            if shots == 0 { gaps.append("스크린샷 없음") }
        }
        if let info = try? await ASCClient.appInfo(appId: appId),
           (try? await ASCClient.ageRatingDone(appInfoId: info.id)) == false {
            gaps.append("연령 등급 미작성")
        }
        return gaps
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
    static func resolveShots(_ dir: URL, locales: [String]) -> [String: [URL]] {
        let subs = subdirectories(dir)

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
        case "APP_DESKTOP": return "Mac"
        default: return t
        }
    }

    private static func rel(_ url: URL, _ root: String) -> String {
        url.path.hasPrefix(root) ? String(url.path.dropFirst(root.count + 1)) : url.path
    }

    private static func reason(_ error: Error) -> String {
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
