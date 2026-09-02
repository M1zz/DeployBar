import Foundation

enum ReleaseNotes {
    /// 한 버전의 릴리즈노트 초안. texts 는 App Store 로케일 → 문구.
    /// 값이 비어 있는 로케일은 "아직 못 채운 언어" 로, 호출측(Store)이 온디바이스 번역으로 메운다.
    struct Draft {
        var commits: [String]
        var base: String                    // 기준 한국어 원문 (번역의 출발점)
        var texts: [String: String]
        var note: String?

        var filled: [String] { texts.filter { !$0.value.isEmpty }.keys.sorted() }
        var empty: [String] { texts.filter { $0.value.isEmpty }.keys.sorted() }
    }

    /// 릴리즈노트 초안을 만든다.
    /// - locales: 이 앱이 App Store 에서 지원하는 로케일. 비우면 ko/en 만 만든다.
    static func draft(_ app: ManagedApp,
                      liveVersion: String? = nil,
                      localVersion: String? = nil,
                      locales: [String] = []) async -> Draft {
        // 기준점 = "직전 릴리즈" → 이 값 이후의 커밋이 이번 버전의 변경사항이다.
        // 1) App Store 라이브 버전의 태그 (사용자가 현재 쓰는 버전 = 직전 릴리즈)
        // 2) 방금 만든 현재 버전 태그를 제외한 가장 최근 태그
        // 3) 아무 태그도 없으면 최근 커밋 (부정확할 수 있음 → note 로 안내)
        var baseTag: String?
        var baseLabel: String
        if let lv = liveVersion, let t = GitInfo.tagForVersion(app.path, lv) {
            baseTag = t; baseLabel = "App Store v\(lv) 이후 변경사항"
        } else if let t = GitInfo.mostRecentTag(app.path, excludingVersion: localVersion) {
            baseTag = t; baseLabel = "\(t) 이후 변경사항"
        } else {
            baseTag = nil; baseLabel = "최근 커밋 기준 (직전 릴리즈 태그가 없어 부정확할 수 있음)"
        }

        let targets = Locales.sorted(locales.isEmpty ? ["ko", "en-US"] : locales)
        var texts = Dictionary(uniqueKeysWithValues: targets.map { ($0, "") })

        let commits = GitInfo.commitsSince(app.path, tag: baseTag)
        if commits.isEmpty {
            return Draft(commits: [], base: "", texts: texts, note: "\(baseLabel) — 새 커밋 없음")
        }

        // AI 키가 있으면 한 번의 호출로 모든 언어를 한꺼번에 만든다.
        if let key = Config.anthropicKey {
            do {
                let produced = try await callAnthropic(commits: commits, locales: targets, key: key)
                // AI 가 규칙을 어겨도 결과물에는 특수기호가 남지 않게 한 번 더 거른다
                for (loc, text) in produced where texts[loc] != nil { texts[loc] = sanitize(text) }
                let base = texts.first { Locales.isKorean($0.key) }?.value
                    ?? produced["ko"] ?? heuristicNotes(commits)
                let missing = texts.filter { $0.value.isEmpty }.keys.sorted()
                let tail = missing.isEmpty ? "" : " · 미생성: \(missing.joined(separator: ", "))"
                return Draft(commits: commits, base: base, texts: texts, note: baseLabel + tail)
            } catch {
                let base = heuristicNotes(commits)
                for loc in targets where Locales.isKorean(loc) { texts[loc] = base }
                return Draft(commits: commits, base: base, texts: texts,
                             note: "\(baseLabel) · AI 호출 실패(\(error.localizedDescription)) — 커밋 기반 초안 + 온디바이스 번역으로 대체")
            }
        }

        // AI 키가 없으면 커밋에서 뽑은 한국어 초안만 만들고, 나머지 언어는 온디바이스 번역에 맡긴다.
        let base = heuristicNotes(commits)
        for loc in targets where Locales.isKorean(loc) { texts[loc] = base }
        let tail = base.isEmpty
            ? "사용자 대상 변경이 없어 보입니다 — 커밋을 확인하고 직접 작성하세요."
            : "커밋 기반 초안입니다. 언어별 문구 품질을 높이려면 config.env 에 ANTHROPIC_API_KEY 를 넣으세요."
        return Draft(commits: commits, base: base, texts: texts, note: "\(baseLabel) · \(tail)")
    }

    // API 키 없이 커밋 메시지에서 "적당히" 릴리즈노트 초안을 만든다.
    // - 내부 작업(chore/build/refactor 등) 제외, 사용자 대상 변경만
    // - conventional prefix(feat:, fix(scope): 등) 제거, 최대 8줄
    private static func heuristicNotes(_ commits: [String]) -> String {
        let skip = ["chore", "build", "ci", "docs", "test", "refactor", "style", "perf", "merge", "revert", "wip", "bump"]
        var lines: [String] = []
        for c in commits {
            let lower = c.lowercased()
            if skip.contains(where: { lower.hasPrefix($0) }) { continue }
            var s = c
            if let range = s.range(of: "^[a-zA-Z]+(\\([^)]*\\))?!?:\\s*", options: .regularExpression) {
                s.removeSubrange(range)
            }
            s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            lines.append(s)
            if lines.count >= 5 { break }
        }
        return sanitize(lines.joined(separator: "\n"))
    }

    /// App Store 릴리즈노트 문구 규칙을 문자열 차원에서 강제한다.
    /// 특수기호로 시작하는 줄(·, -, •, *, 1. …)과 마크다운·이모지를 걷어내고,
    /// 각 줄을 한 문장으로 간결하게 남긴다. AI·커밋 초안·온디바이스 번역 모두 이걸 통과한다.
    static func sanitize(_ text: String) -> String {
        var out: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw).trimmingCharacters(in: .whitespaces)
            // 줄머리 글머리표·번호 제거 (· • - – — * + 1. 1) 등)
            line = line.replacingOccurrences(
                of: #"^\s*(?:[\u{00B7}\u{2022}\u{25CF}\u{25AA}\-–—*+>]+|\d+[.)])\s*"#,
                with: "", options: .regularExpression)
            // 마크다운 강조 제거
            line = line.replacingOccurrences(of: #"[*_`#]"#, with: "", options: .regularExpression)
            // 이모지·기호 제거 (문장부호와 글자만 남긴다)
            line = line.unicodeScalars.filter { u in
                !(0x1F000...0x1FAFF ~= u.value || 0x2190...0x2BFF ~= u.value
                  || 0xFE00...0xFE0F ~= u.value || 0x2600...0x27BF ~= u.value)
            }.map(String.init).joined()
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { out.append(line) }
        }
        return out.prefix(5).joined(separator: "\n")
    }

    // 커밋 → 언어별 릴리즈노트. 로케일 하나하나 부르지 않고 한 번에 받는다(호출 1회, 톤 일관).
    private static func callAnthropic(commits: [String], locales: [String], key: String) async throws -> [String: String] {
        let localeList = locales
            .map { "  \"\($0)\": \"\(Locales.displayName($0)) 로 쓴 릴리즈노트\"" }
            .joined(separator: ",\n")
        let prompt = """
        다음은 iOS/macOS 앱의 마지막 배포 이후 git 커밋 메시지입니다. 이를 바탕으로 App Store 릴리즈노트를 작성하세요.

        규칙:
        - 사용자 관점의 개선·신기능 중심. 내부 리팩터링·빌드 설정·테스트는 제외.
        - 기술용어 배제, 각 항목 한 줄, 3~5개.
        - **특수기호를 쓰지 말 것.** 글머리표(·, •, -, *), 번호(1.), 이모지, 마크다운(**, `) 모두 금지.
          한 줄에 한 문장씩, 줄바꿈으로만 구분한다.
        - 각 언어권에서 자연스럽게 읽히도록 현지화할 것(직역 금지). 언어마다 항목 수와 순서는 동일하게.
        - 앱 이름·고유명사는 그대로 둘 것.
        - 간결하게. 한 줄이 40자를 넘지 않게 한다.

        아래 JSON 형식으로만 답하세요. 모든 키를 빠짐없이 채우세요.
        {
        \(localeList)
        }

        커밋:
        \(commits.map { "- \($0)" }.joined(separator: "\n"))
        """
        let payload: [String: Any] = [
            "model": Config.anthropicModel,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code < 400 else { throw NSError(domain: "Anthropic", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]) }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (j?["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return [:] }
        let jsonStr = String(text[start...end])
        let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8))) as? [String: Any] ?? [:]
        var out: [String: String] = [:]
        for loc in locales {
            // 정확히 일치하는 키가 없으면 같은 언어의 키라도 받아들인다 ("en" ↔ "en-US")
            if let v = parsed[loc] as? String { out[loc] = v }
            else if let hit = parsed.first(where: { Locales.sameLanguage($0.key, loc) })?.value as? String { out[loc] = hit }
        }
        return out
    }

    // 편집 가능한 App Store 버전과 그 버전이 지원하는 언어(로케일) 목록
    struct EditableVersion {
        let versionId: String
        let versionString: String
        let locales: [ASCClient.Localization]
        var localeCodes: [String] { Locales.sorted(locales.map { $0.locale }) }
    }

    /// 릴리즈노트를 고칠 수 있는 App Store 버전 상태. 판정 기준이 갈라지지 않게 한곳에 둔다.
    static let editableStates = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"]

    /// 지금 편집 가능한 버전의 릴리즈노트가 채워져 있나. 배포 전 게이트와 체크리스트가 함께 쓴다.
    struct NotesState {
        var version: String
        var filled: [String] = []
        var missing: [String] = []
        var ready: Bool { missing.isEmpty && !filled.isEmpty }
    }
    static func notesState(appId: String) async throws -> NotesState? {
        try await notesState(versions: try await ASCClient.appStoreVersions(appId: appId))
    }
    /// 이미 조회한 버전 목록으로 판정 — 상태 조회가 같은 요청을 두 번 보내지 않게.
    static func notesState(versions vers: [ASCClient.Version]) async throws -> NotesState? {
        guard let editable = vers.first(where: { editableStates.contains($0.state) }) else { return nil }
        let locs = try await ASCClient.versionLocalizations(versionId: editable.id)
        return NotesState(version: editable.versionString,
                          filled: locs.filter { !$0.isEmpty }.map(\.locale).sorted(),
                          missing: locs.filter { $0.isEmpty }.map(\.locale).sorted())
    }

    static func editableVersionAndLocales(_ app: ManagedApp) async throws -> EditableVersion? {
        let r = AppRepo.resolve(app)
        let info = try AppRepo.buildSettings(r)
        guard let id = try await ASCClient.appId(bundleId: info.bundleId) else { return nil }
        let vers = try await ASCClient.appStoreVersions(appId: id)
        guard let editable = vers.first(where: { editableStates.contains($0.state) }) else { return nil }
        let locs = try await ASCClient.versionLocalizations(versionId: editable.id)
        return EditableVersion(versionId: editable.id, versionString: editable.versionString, locales: locs)
    }

    struct UploadResult {
        let version: String
        let locales: [String]
        let skipped: [String]
        /// 이미 사람이 써 둔 게 있어서 손대지 않은 언어 (자동 반영에서만 생긴다)
        let kept: [String]
    }

    /// 사람이 쓴 글을 기계가 덮어쓸 수 있는가.
    ///
    /// 이걸 기본값 없는 인자로 둔 이유가 있다. 예전엔 이 구분이 아예 없어서
    /// **배포할 때마다 자동 초안이 이미 채워진 릴리즈노트를 덮어썼다.**
    /// 공들여 쓴 문구가 커밋 제목 한 줄로 바뀌어 심사에 나가는 일이 실제로 일어났다.
    /// 되돌릴 수 없는 글이니, 부르는 쪽이 매번 의도를 밝히게 한다.
    enum WriteMode {
        /// 자동 반영(배포 중) — 비어 있는 언어만 채운다. 있는 글은 건드리지 않는다.
        case fillEmptyOnly
        /// 사람이 [릴리즈노트] 창에서 직접 눌렀다 — 그 뜻대로 덮어쓴다.
        case overwrite
    }

    /// 언어별 문구를 App Store 에 반영한다. texts 에 없거나 빈 언어는 건드리지 않는다.
    static func upload(_ app: ManagedApp, texts: [String: String],
                       mode: WriteMode) async throws -> UploadResult {
        guard let target = try await editableVersionAndLocales(app) else {
            throw NSError(domain: "DeployBar", code: 21, userInfo: [NSLocalizedDescriptionKey: "편집 가능한 App Store 버전이 없습니다 (먼저 새 버전을 준비하세요)"])
        }
        var updated: [String] = []
        var skipped: [String] = []
        var kept: [String] = []
        for loc in target.locales {
            // 이미 글이 있는데 자동 반영이라면 그대로 둔다 — 덮어쓸 권한이 없다
            if mode == .fillEmptyOnly && !loc.isEmpty { kept.append(loc.locale); continue }
            // 정확히 일치하는 로케일 우선, 없으면 같은 언어의 문구를 재사용 ("en" 문구를 "en-GB" 에)
            let text = texts[loc.locale] ?? texts.first { Locales.sameLanguage($0.key, loc.locale) && !$0.value.isEmpty }?.value
            guard let whatsNew = text, !whatsNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                skipped.append(loc.locale); continue
            }
            try await ASCClient.patchWhatsNew(localizationId: loc.id, whatsNew: whatsNew)
            updated.append(loc.locale)
        }
        return UploadResult(version: target.versionString, locales: updated,
                            skipped: skipped, kept: kept)
    }
}
