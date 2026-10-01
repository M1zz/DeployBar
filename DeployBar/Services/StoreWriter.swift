import Foundation

// 스토어 문구 자동 작성 — 이름·부제·키워드·프로모션 텍스트·설명 + 이번 버전 릴리즈노트를
// 지원하는 모든 언어로 AI 가 써서 **레포의 APPSTORE.md · RELEASE_NOTES.md 에** 채운다.
//
// 스토어에 바로 쓰지 않고 레포에 쓰는 이유는 StoreMeta·RepoNotes 와 같다: 사람이 읽고 고칠 수
// 있어야 하고, 커밋 이력이 남아야 한다. 올리는 건 늘 하던 대로 배포·[스토어 올리기] 가 한다.
//
// 원칙 셋:
//   1. **빈 칸만 채운다.** 레포에 적힌 글도, App Store Connect 에 이미 있는 글도 건드리지 않는다.
//      사람이 다듬어 둔 키워드를 AI 초안이 밀어내면 그게 더 큰 손해다.
//   2. **한국어가 출발점이다.** 한국어가 비어 있으면 그것부터 쓰고, 나머지 언어는 한국어를
//      그 언어권에 맞게 다시 쓴다(직역 금지 — 키워드는 특히 그 나라 사람이 치는 말이어야 한다).
//   3. **한도를 우리가 지킨다.** 넘으면 ASC 가 409 로 거부하는데 어느 칸인지 말해 주지 않는다.
enum StoreWriter {

    typealias Field = StoreMeta.Field
    static let fields: [Field] = [.name, .subtitle, .keywords, .promotionalText, .description]

    static func label(_ f: Field) -> String {
        switch f {
        case .name: return "이름"
        case .subtitle: return "부제"
        case .keywords: return "키워드"
        case .promotionalText: return "프로모션 텍스트"
        case .description: return "설명"
        default: return "\(f)"
        }
    }
    static func limit(_ f: Field) -> Int {
        switch f {
        case .name, .subtitle: return 30
        case .keywords: return 100
        case .promotionalText: return 170
        default: return 4000
        }
    }
    private static func key(_ f: Field) -> String {
        switch f {
        case .name: return "name"
        case .subtitle: return "subtitle"
        case .keywords: return "keywords"
        case .promotionalText: return "promotionalText"
        default: return "description"
        }
    }

    struct Result {
        var version = ""
        /// 로케일 → 채운 칸
        var store: [String: [Field: String]] = [:]
        /// 로케일 → 채운 릴리즈노트
        var notes: [String: String] = [:]
        /// 이미 있어서 그대로 둔 칸 수 (레포 + ASC)
        var kept = 0
        var warnings: [String] = []
        var files: [String] = []
        var committed = false
        var didWrite: Bool { !files.isEmpty }
    }

    // ── 본체 ────────────────────────────────────────────────────────────
    static func run(_ app: ManagedApp, dryRun: Bool = false, commit: Bool = true,
                    onLog: @escaping @Sendable (String) -> Void) async throws -> Result {
        let r = AppRepo.resolve(app)
        guard r.exists else { throw AIWriter.Failure(message: "Xcode 프로젝트를 찾지 못했습니다") }
        let info = try AppRepo.buildSettings(r)
        guard AIWriter.available else {
            throw AIWriter.Failure(message: "AI 를 부를 수 없습니다 — Claude Code 를 설치하거나 config.env 에 ANTHROPIC_API_KEY 를 넣으세요")
        }
        // 1) 무엇을 지금 가지고 있나 — 레포 글과 ASC 글을 합친다
        let asc = await currentStore(bundleId: info.bundleId)
        // 릴리즈노트는 **배포가 쓸 번호**의 절에 써야 읽힌다. 로컬이 2.2.9 여도 스토어에 2.3.0 이
        // 준비돼 있으면 배포는 2.3.0 으로 올린다 — 같은 규칙(planVersion)으로 정한다.
        let version = Deployer.planVersion(local: info.marketingVersion, bump: nil,
                                           editable: asc.editableVersion, closed: asc.closedVersion).version
        var result = Result(version: version)
        var locales = r.locales.isEmpty ? asc.locales : r.locales
        if locales.isEmpty { locales = ["ko", "en-US"] }
        if !locales.contains(where: Locales.isKorean) { locales.insert("ko", at: 0) }
        locales = Locales.sorted(locales)
        let repo = StoreMeta.read(app.path, locales: locales)?.entries ?? [:]

        func value(_ loc: String, _ f: Field) -> String? {
            let e = repo.first { Locales.sameLanguage($0.key, loc) }?.value
            let fromRepo: String? = {
                switch f {
                case .name: return e?.name
                case .subtitle: return e?.subtitle
                case .keywords: return e?.keywords
                case .promotionalText: return e?.promotionalText
                default: return e?.description
                }
            }()
            if let v = fromRepo, !v.isEmpty { return v }
            if let v = asc.values.first(where: { Locales.sameLanguage($0.key, loc) })?.value[f], !v.isEmpty,
               !misplaced(v, locale: loc, field: f) { return v }
            return nil
        }
        /// 스토어에 있지만 **그 언어 글이 아닌** 값 — 언어를 추가할 때 임시로 들어간 한국어 이름,
        /// 다른 언어 칸에서 복사된 설명 같은 것. 채워진 칸으로 치면 독일어 페이지가 한국어로 남는다.
        func misplaced(_ v: String, locale: String, field: Field) -> Bool {
            if !Locales.isKorean(locale), v.unicodeScalars.contains(where: { (0xAC00...0xD7A3).contains($0.value) }) {
                return true
            }
            // 다른 언어 칸과 글자 하나 다르지 않으면 복사본이다 (브랜드 이름은 같을 수 있으니 이름은 뺀다)
            guard field != .name else { return false }
            return asc.values.contains { other in
                !Locales.sameLanguage(other.key, locale) && other.value[field] == v
            }
        }

        // 이번 버전 릴리즈노트 — 레포에 이미 쓴 언어는 둔다
        let haveNotes = RepoNotes.read(app.path, version: version, locales: locales)?.texts ?? [:]
        func note(_ loc: String) -> String? {
            haveNotes.first { Locales.sameLanguage($0.key, loc) }?.value
        }

        var missing: [String: [Field]] = [:]
        for loc in locales {
            let need = fields.filter { value(loc, $0) == nil }
            result.kept += fields.count - need.count
            if !need.isEmpty { missing[loc] = need }
        }
        let notesMissing = locales.filter { note($0) == nil }
        if missing.isEmpty && notesMissing.isEmpty {
            onLog("✅ \(locales.count)개 언어 모두 채워져 있습니다 — 쓸 것이 없습니다")
            return result
        }
        onLog("✍️  \(AIWriter.engineLabel) 로 씁니다 — 빈 칸 \(missing.values.reduce(0) { $0 + $1.count })개 · 릴리즈노트 \(notesMissing.count)개 언어")

        // 2) 한국어부터 — 다른 언어의 출발점
        let ko = locales.first(where: Locales.isKorean)!
        var koText: [Field: String] = [:]
        for f in fields { if let v = value(ko, f) { koText[f] = v } }
        var koNote = note(ko)
        let commits = releaseCommits(app.path, liveVersion: asc.liveVersion, localVersion: version)
        let context = appContext(app.path)

        let koNeed = missing[ko] ?? []
        let koNoteNeeded = koNote == nil && !commits.isEmpty
        if koNote == nil && commits.isEmpty && !notesMissing.isEmpty {
            result.warnings.append("직전 릴리즈 이후 커밋이 없어 릴리즈노트는 쓰지 않았습니다")
        }
        if !koNeed.isEmpty || koNoteNeeded {
            onLog("   … 한국어 (출발점)")
            let prompt = koreanPrompt(appName: app.name, context: context, have: koText,
                                      need: koNeed, commits: koNoteNeeded ? commits : [])
            let out = try await generate(prompt, need: koNeed, wantsNote: koNoteNeeded, locale: ko,
                                         result: &result, onLog: onLog)
            for (f, v) in out.fields { koText[f] = v; result.store[ko, default: [:]][f] = v }
            if let n = out.note { koNote = n; result.notes[ko] = n }
        }

        // 3) 나머지 언어 — 한국어를 그 언어권에 맞게 다시 쓴다. 언어끼리는 동시에 (넷씩).
        let others = locales.filter { !Locales.isKorean($0) && (missing[$0] != nil || note($0) == nil) }
        let sampleNames = locales.compactMap { loc in value(loc, .name).map { "\(loc): \($0)" } }
        let jobs: [(loc: String, need: [Field], note: Bool)] = others.map { loc in
            (loc, missing[loc] ?? [], note(loc) == nil && koNote != nil)
        }.filter { !$0.need.isEmpty || $0.note }

        for chunk in stride(from: 0, to: jobs.count, by: 4).map({ Array(jobs[$0..<min($0 + 4, jobs.count)]) }) {
            let outs = await withTaskGroup(of: (String, LocaleOut?, String?).self) { group in
                for j in chunk {
                    group.addTask {
                        onLog("   … \(Locales.displayName(j.loc))")
                        let prompt = localizePrompt(appName: app.name, locale: j.loc, korean: koText,
                                                    koreanNote: j.note ? koNote : nil, need: j.need,
                                                    names: sampleNames)
                        do {
                            var scratch = Result()
                            let out = try await generate(prompt, need: j.need, wantsNote: j.note, locale: j.loc,
                                                         result: &scratch, onLog: onLog)
                            return (j.loc, LocaleOut(fields: out.fields, note: out.note, warnings: scratch.warnings), nil)
                        } catch {
                            return (j.loc, nil, error.localizedDescription)
                        }
                    }
                }
                var all: [(String, LocaleOut?, String?)] = []
                for await x in group { all.append(x) }
                return all
            }
            for (loc, out, err) in outs {
                if let err { result.warnings.append("\(Locales.displayName(loc)) 작성 실패 — \(err)"); continue }
                guard let out else { continue }
                result.warnings += out.warnings
                if !out.fields.isEmpty { result.store[loc, default: [:]].merge(out.fields) { $1 } }
                if let n = out.note { result.notes[loc] = n }
            }
        }

        // 4) 레포에 쓴다
        if dryRun { return result }
        var written: [String] = []
        let stores = result.store.filter { !$0.value.isEmpty }
        if !stores.isEmpty {
            let path = StoreMeta.path(in: app.path) ?? (app.path as NSString).appendingPathComponent("APPSTORE.md")
            var body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? storeHeader
            for loc in Locales.sorted(Array(stores.keys)) {
                let pairs = fields.compactMap { f in stores[loc]?[f].map { (f, $0) } }
                body = insertStore(body, locale: loc, fields: pairs, locales: locales)
            }
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            written.append(path)
        }
        if !result.notes.isEmpty {
            let path = notesPath(app.path)
            var body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? notesHeader
            let pairs = Locales.sorted(Array(result.notes.keys)).map { ($0, result.notes[$0]!) }
            body = insertNotes(body, version: version, notes: pairs)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            written.append(path)
        }
        result.files = written

        // 5) 커밋 — 안 하면 레포가 더러워져 배포가 '개발 중' 으로 잠긴다.
        //    우리가 쓴 두 파일만 커밋한다. 사람이 하던 다른 변경은 섞지 않는다.
        if commit, !written.isEmpty, GitInfo.isRepo(app.path) {
            let dir = URL(fileURLWithPath: app.path)
            let rel = written.map { $0.hasPrefix(app.path + "/") ? String($0.dropFirst(app.path.count + 1)) : $0 }
            let langs = Set(Array(result.store.keys) + Array(result.notes.keys)).count
            do {
                _ = try Shell.capture("/usr/bin/git", ["add", "--"] + rel, cwd: dir)
                _ = try Shell.capture("/usr/bin/git", ["commit", "-m",
                    "docs: 스토어 문구·릴리즈노트를 \(langs)개 언어로 채운다 (DeployBar 자동 작성)", "--"] + rel, cwd: dir)
                result.committed = true
            } catch {
                result.warnings.append("커밋하지 못했습니다 — \(error.localizedDescription)")
            }
        }
        return result
    }

    private struct LocaleOut { var fields: [Field: String]; var note: String?; var warnings: [String] }

    // ── AI 호출 + 검사 ──────────────────────────────────────────────────
    /// 한 번 쓰고, 한도를 넘거나 비면 그 칸만 한 번 더 쓰게 한다. 그래도 안 되면 버리고 말한다.
    private static func generate(_ prompt: String, need: [Field], wantsNote: Bool, locale: String,
                                 result: inout Result,
                                 onLog: @Sendable (String) -> Void) async throws
        -> (fields: [Field: String], note: String?) {
        let raw = try await AIWriter.complete(prompt)
        guard let j = AIWriter.json(raw) else {
            throw AIWriter.Failure(message: "AI 응답에서 JSON 을 찾지 못했습니다")
        }
        var out: [Field: String] = [:]
        var bad: [String] = []
        for f in need {
            guard let v = (j[key(f)] as? String).map(clean(f)), !v.isEmpty else { bad.append("\(key(f)): 비어 있음"); continue }
            if v.count > limit(f) { bad.append("\(key(f)): \(v.count)자 — \(limit(f))자 이하로"); continue }
            out[f] = v
        }
        var note = wantsNote ? (j["whatsNew"] as? String).map(ReleaseNotes.sanitize) : nil
        if wantsNote && (note ?? "").isEmpty { bad.append("whatsNew: 비어 있음"); note = nil }

        if !bad.isEmpty {
            let fix = prompt + "\n\n지난 답에서 아래 항목이 규칙을 어겼다. 이 항목만 고쳐서 같은 JSON 형식으로 다시 답하라:\n"
                + bad.map { "- \($0)" }.joined(separator: "\n")
                + "\n지난 답:\n" + raw
            if let j2 = AIWriter.json((try? await AIWriter.complete(fix)) ?? "") {
                for f in need where out[f] == nil {
                    if let v = (j2[key(f)] as? String).map(clean(f)), !v.isEmpty, v.count <= limit(f) { out[f] = v }
                }
                if wantsNote && note == nil, let n = (j2["whatsNew"] as? String).map(ReleaseNotes.sanitize), !n.isEmpty {
                    note = n
                }
            }
            for f in need where out[f] == nil {
                result.warnings.append("\(Locales.displayName(locale)) \(label(f)) — 한도에 맞게 쓰지 못해 비워 둡니다")
            }
            if wantsNote && note == nil {
                result.warnings.append("\(Locales.displayName(locale)) 릴리즈노트 — 쓰지 못해 비워 둡니다")
            }
        }
        return (out, note)
    }

    /// 칸마다 다듬기. 키워드는 공백을 걷고 같은 말을 빼고, 100자에 맞춰 쉼표 경계에서 자른다.
    private static func clean(_ f: Field) -> (String) -> String {
        { raw in
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            switch f {
            case .keywords:
                var seen = Set<String>(), out: [String] = []
                for w in t.split(whereSeparator: { $0 == "," || $0 == "、" || $0 == "，" || $0 == "\n" }) {
                    let k = w.trimmingCharacters(in: .whitespaces)
                    guard !k.isEmpty, seen.insert(k.lowercased()).inserted else { continue }
                    if (out + [k]).joined(separator: ",").count > 100 { break }
                    out.append(k)
                }
                return out.joined(separator: ",")
            case .name, .subtitle, .promotionalText:
                return t.replacingOccurrences(of: "\n", with: " ")
            default:
                return t
            }
        }
    }

    // ── 프롬프트 ────────────────────────────────────────────────────────
    private static let rules = """
    칸별 규칙 (App Store 한도는 글자 수 기준):
    - name: 30자 이하. 앱의 브랜드 이름. 다른 언어에 이미 쓰인 이름이 있으면 같은 브랜드를 유지하고, 필요하면 "브랜드: 짧은 설명" 형태로 검색어를 붙인다.
    - subtitle: 30자 이하. 이 앱이 무엇을 해 주는지 한 문장. name 과 같은 말을 반복하지 않는다.
    - keywords: 100자 이하. 쉼표로만 구분하고 공백을 넣지 않는다. name·subtitle 에 이미 있는 단어, 앱 이름, 다른 회사 상표는 넣지 않는다. 그 언어 사용자가 실제로 검색창에 칠 말로 고른다(직역 금지).
    - promotionalText: 170자 이하. 지금 이 앱을 써야 하는 이유를 한두 문장으로.
    - description: 4000자 이하. 평문 단락. 첫 두 줄에 핵심을 쓴다. 마크다운·이모지 금지.
    - whatsNew (릴리즈노트): 3~5줄, 한 줄에 한 문장, 한 줄 40자 이내. 글머리표·번호·이모지·마크다운 금지. 사용자에게 무엇이 좋아졌는지만 쓴다. 내부 구조·빌드·테스트·의존성 이야기와 기술 용어는 쓰지 않는다. 앱 이름과 고유명사는 그대로 둔다.
    """

    private static func koreanPrompt(appName: String, context: String, have: [Field: String],
                                     need: [Field], commits: [String]) -> String {
        var keys = need.map(key)
        if !commits.isEmpty { keys.append("whatsNew") }
        var s = "너는 App Store 마케팅 카피라이터다. 아래 iOS 앱의 한국어 App Store 문구를 쓴다.\n\n"
        s += "앱 폴더 이름: \(appName)\n\n"
        if !have.isEmpty {
            s += "이미 확정된 한국어 문구 (톤과 사실을 여기에 맞춘다):\n"
            for f in fields { if let v = have[f] { s += "[\(key(f))]\n\(v)\n\n" } }
        }
        if !context.isEmpty { s += "앱 설명 자료 (README 등):\n\(context)\n\n" }
        if !commits.isEmpty {
            s += "이번 버전의 커밋 제목 (whatsNew 는 이 중 사용자가 느끼는 변화만 골라 쓴다):\n"
            s += commits.prefix(40).map { "- \($0)" }.joined(separator: "\n") + "\n\n"
        }
        s += rules + "\n\n"
        s += "다음 키만 가진 JSON 객체 하나로만 답하라. 다른 말은 쓰지 않는다: \(keys.joined(separator: ", "))\n"
        s += "자료에 없는 기능을 지어내지 않는다."
        return s
    }

    private static func localizePrompt(appName: String, locale: String, korean: [Field: String],
                                       koreanNote: String?, need: [Field], names: [String]) -> String {
        var keys = need.map(key)
        if koreanNote != nil { keys.append("whatsNew") }
        let lang = Locale(identifier: "en_US").localizedString(forIdentifier: locale.replacingOccurrences(of: "-", with: "_")) ?? locale
        var s = "너는 \(lang) (\(locale)) 원어민 App Store 카피라이터다. 아래 한국어 App Store 문구를 "
        s += "\(lang) 사용자에게 자연스럽게 읽히도록 현지화한다. 기계번역처럼 직역하지 말고, 그 나라 앱스토어에서 쓰는 표현으로 다시 쓴다.\n\n"
        s += "앱 폴더 이름: \(appName)\n"
        if !names.isEmpty { s += "다른 언어에서 쓰는 앱 이름 (브랜드를 맞춘다): \(names.joined(separator: " / "))\n" }
        s += "\n한국어 원문:\n"
        for f in fields { if let v = korean[f] { s += "[\(key(f))]\n\(v)\n\n" } }
        if let n = koreanNote {
            s += "[whatsNew]\n\(n)\n(줄 수와 순서를 한국어와 똑같이 맞춘다)\n\n"
        }
        s += rules + "\n\n"
        s += "모든 값은 \(lang) 로 쓴다. 다음 키만 가진 JSON 객체 하나로만 답하라. 다른 말은 쓰지 않는다: \(keys.joined(separator: ", "))"
        return s
    }

    // ── 재료 ────────────────────────────────────────────────────────────
    /// AI 에게 앱이 무엇인지 알려 줄 글. README 앞부분이면 충분하다 — 소스를 통째로 주면 느리고 비싸다.
    private static func appContext(_ root: String) -> String {
        for name in ["README.md", "readme.md", "docs/README.md"] {
            let p = (root as NSString).appendingPathComponent(name)
            if let s = try? String(contentsOfFile: p, encoding: .utf8) { return String(s.prefix(6000)) }
        }
        return ""
    }

    /// 이번 버전에 들어간 커밋 — 스토어에 나가 있는 버전의 태그 이후.
    private static func releaseCommits(_ root: String, liveVersion: String?, localVersion: String) -> [String] {
        guard GitInfo.isRepo(root) else { return [] }
        let tag = liveVersion.flatMap { GitInfo.tagForVersion(root, $0) }
            ?? GitInfo.mostRecentTag(root, excludingVersion: localVersion)
        return GitInfo.commitsSince(root, tag: tag)
    }

    private struct ASCStore {
        var locales: [String] = []
        var values: [String: [Field: String]] = [:]
        var liveVersion: String?
        var editableVersion: String?
        var closedVersion: String?
    }

    /// App Store Connect 에 지금 적혀 있는 글. 못 물어보면 비어 있는 채로 — 레포만 보고 쓴다.
    private static func currentStore(bundleId: String) async -> ASCStore {
        var out = ASCStore()
        guard let appId = try? await ASCClient.appId(bundleId: bundleId),
              let vers = try? await ASCClient.appStoreVersions(appId: appId) else { return out }
        out.liveVersion = vers.first { $0.state == "READY_FOR_SALE" }?.versionString
        out.editableVersion = vers.first { ReleaseNotes.editableStates.contains($0.state) }?.versionString
        out.closedVersion = vers.filter { !ReleaseNotes.editableStates.contains($0.state) }
            .map(\.versionString).max { Status.cmpVer($0, $1) < 0 }
        let version = vers.first { ReleaseNotes.editableStates.contains($0.state) } ?? vers.first
        if let v = version, let texts = try? await ASCClient.storeTexts(versionId: v.id) {
            for t in texts {
                out.locales.append(t.locale)
                out.values[t.locale, default: [:]][.description] = t.description
                out.values[t.locale, default: [:]][.keywords] = t.keywords
                out.values[t.locale, default: [:]][.promotionalText] = t.promotionalText
            }
        }
        if let info = try? await ASCClient.appInfo(appId: appId),
           let texts = try? await ASCClient.infoTexts(appInfoId: info.id) {
            for t in texts {
                out.values[t.locale, default: [:]][.name] = t.name
                out.values[t.locale, default: [:]][.subtitle] = t.subtitle
            }
        }
        return out
    }

    // ── 파일에 끼워 넣기 ────────────────────────────────────────────────
    private static let storeHeader = """
    # App Store 페이지 문구

    DeployBar 가 이 파일을 읽어 App Store Connect 의 언어별 칸에 올린다.
    적힌 언어·칸만 건드리고, 적지 않은 칸은 그대로 둔다.
    글자 수 한도: 이름·부제 30, 키워드 100(쉼표 뒤 공백 없음), 프로모션 텍스트 170, 설명 4000.

    """

    private static let notesHeader = """
    # 릴리즈 노트

    App Store 의 "이 버전의 새로운 기능" 에 그대로 올라가는 글이다.
    평문만 쓴다. 한 줄에 한 문장, 3~5줄, 한 줄 40자 이내.

    """

    private static func isH2(_ line: String) -> Bool { line.hasPrefix("## ") && !line.hasPrefix("### ") }

    /// 그 언어 절에 칸을 넣는다. 제목만 있고 비어 있는 칸(뼈대 파일)이면 그 자리에, 없으면 절 끝에.
    /// 언어 절이 없으면 연령 등급 절 앞(없으면 파일 끝)에 새로 만든다.
    static func insertStore(_ body: String, locale: String, fields pairs: [(Field, String)],
                            locales: [String]) -> String {
        var lines = body.components(separatedBy: "\n")
        func sectionRange() -> Range<Int>? {
            guard let start = lines.indices.first(where: { i in
                guard isH2(lines[i]) else { return false }
                let title = String(lines[i].dropFirst(3))
                guard let loc = StoreMeta.sectionLocale(title, among: locales) else { return false }
                return Locales.sameLanguage(loc, locale)
            }) else { return nil }
            let end = lines.indices.first { $0 > start && isH2(lines[$0]) } ?? lines.count
            return start..<end
        }
        if sectionRange() == nil {
            let age = lines.indices.first { isH2(lines[$0]) && Locales.normalizeName(lines[$0]).contains("연령") }
            let at = age ?? lines.count
            var block = ["## \(locale)", ""]
            if age == nil, let last = lines.last, !last.isEmpty { block.insert("", at: 0) }
            if age != nil { block.append("") }
            lines.insert(contentsOf: block, at: at)
        }
        for (f, v) in pairs {
            guard let range = sectionRange() else { break }
            let header = range.dropFirst().first { i in
                lines[i].hasPrefix("###") && StoreMeta.normalizeField(String(lines[i].drop { $0 == "#" })) == f
            }
            if let h = header {
                lines.insert(contentsOf: ["", v], at: h + 1)
            } else {
                var at = range.upperBound
                while at > range.lowerBound + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
                lines.insert(contentsOf: ["", "### \(label(f))", "", v, ""], at: at)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `## 버전` 절에 언어 절을 넣는다. 버전 절이 없으면 맨 위 버전 절 앞에 새로 만든다 (최신이 위).
    /// 절 제목에는 언어 **이름**을 적는다 — 두 글자 코드(`de`)는 RepoNotes 가 알아보지 못한다.
    static func insertNotes(_ body: String, version: String, notes: [(String, String)]) -> String {
        var lines = body.components(separatedBy: "\n")
        let esc = NSRegularExpression.escapedPattern(for: version)
        let pattern = "(^|[^0-9.])\(esc)([^0-9.]|$)"
        var block: [String] = []
        for (loc, text) in notes {
            let name = Locales.isKorean(loc) ? "한국어" : Locales.displayName(loc)
            block += ["", "### 앱스토어 (\(name))", "", text]
        }
        if let start = lines.indices.first(where: { isH2(lines[$0])
            && String(lines[$0].dropFirst(3)).range(of: pattern, options: .regularExpression) != nil }) {
            var at = lines.indices.first { $0 > start && isH2(lines[$0]) } ?? lines.count
            while at > start + 1, lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty { at -= 1 }
            lines.insert(contentsOf: block + [""], at: at)
        } else {
            let first = lines.indices.first { isH2(lines[$0]) }
            let section = ["## \(version)"] + block + [""]
            if let first {
                lines.insert(contentsOf: section + [""], at: first)
            } else {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                lines += section
            }
        }
        return lines.joined(separator: "\n")
    }

    /// RepoNotes 가 찾는 순서 그대로 — 있으면 그 파일, 없으면 최상단 RELEASE_NOTES.md.
    private static func notesPath(_ root: String) -> String {
        for name in ["RELEASE_NOTES.md", "RELEASENOTES.md", "CHANGELOG.md", "docs/RELEASE_NOTES.md", "docs/CHANGELOG.md"] {
            let p = (root as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return (root as NSString).appendingPathComponent("RELEASE_NOTES.md")
    }
}
