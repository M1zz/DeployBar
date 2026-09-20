import Foundation

// 스토어 페이지 문구(이름·부제·설명·키워드·URL)의 **원본은 레포의 APPSTORE.md** 다.
//
// RELEASE_NOTES.md 와 같은 생각이다: 스토어에서 사람이 읽는 글은 App Store Connect 의
// 입력칸이 아니라 레포에 있어야 한다. 그래야 (1) 커밋 이력이 남고 (2) 번역이 코드 리뷰를
// 거치고 (3) 실수로 지워도 되돌릴 수 있고 (4) 다음 버전에 그대로 다시 쓸 수 있다.
//
// 형식은 RELEASE_NOTES.md 를 그대로 따라간다 — 사람이 규칙을 두 번 배우지 않게.
//
//   ## 한국어            ← 절 제목이 언어 (`## ko`, `## App Store (English)` 다 알아본다)
//
//   ### 이름
//   뇌모리
//
//   ### 부제
//   잊어도 되는 것들의 임시 기억
//
//   ### 설명
//   ...본문...
//
//   ### 키워드
//   주차위치,사물함,비밀번호,임시메모
//
//   ### 지원 URL
//   https://...
//
// 없는 값은 **안 건드린다.** 비운 칸을 올려서 이미 있던 글을 지우는 사고를 막기 위해
// "빈 문자열" 과 "안 적음" 을 구분한다.
enum StoreMeta {

    /// 한 언어의 스토어 문구. nil = 이 파일에 안 적혀 있음 = 건드리지 않음.
    struct Entry {
        var name: String?
        var subtitle: String?
        var description: String?
        var keywords: String?
        var promotionalText: String?
        var supportUrl: String?
        var marketingUrl: String?
        var privacyPolicyUrl: String?

        var isEmpty: Bool {
            [name, subtitle, description, keywords, promotionalText,
             supportUrl, marketingUrl, privacyPolicyUrl].allSatisfy { $0 == nil }
        }
    }

    struct Found {
        var entries: [String: Entry]      // 로케일 → 문구
        var source: String                // "APPSTORE.md"
        /// 사람이 `## 연령 등급` 절에 "해당 없음" 이라고 적어 뒀나.
        /// 애플에 하는 내용 신고라서 도구가 알아서 정하지 않는다 — 사람의 뜻만 전달한다.
        var ageRatingNone: Bool = false
        var locales: [String] { Locales.sorted(Array(entries.keys)) }
    }

    static let candidates = ["APPSTORE.md", "docs/APPSTORE.md", "STORE.md", "docs/STORE.md"]

    // ── 읽기 ────────────────────────────────────────────────────────────
    /// - locales: 이 앱이 쓰는 로케일. 절 제목이 언어 이름일 때 여기 대고 맞춘다.
    ///   비어 있어도 `## ko` 처럼 코드로 적힌 절은 읽는다 (첫 출시 앱은 목록을 모른다).
    static func read(_ dir: String, locales: [String] = []) -> Found? {
        for name in candidates {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let body = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let parsed = parse(body, locales: locales)
            guard !parsed.entries.isEmpty || parsed.ageRatingNone else { continue }
            return Found(entries: parsed.entries, source: name, ageRatingNone: parsed.ageRatingNone)
        }
        return nil
    }

    static func path(in dir: String) -> String? {
        candidates.map { (dir as NSString).appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    private static func parse(_ body: String, locales: [String])
        -> (entries: [String: Entry], ageRatingNone: Bool) {
        var entries: [String: Entry] = [:]
        var ageRatingNone = false

        var locale: String?              // 지금 읽고 있는 언어 절
        var inAgeRating = false
        var field: String?               // 지금 읽고 있는 항목
        var buf: [String] = []

        func flushField() {
            defer { buf = [] }
            let text = clean(buf)
            // 연령 등급 절은 항목을 따지지 않고 본문만 본다.
            // 정확히 "해당 없음" 한 줄일 때만 받아들인다 — 설명을 곁들여 적은 글이
            //  "없음" 을 포함한다고 애플에 내용 신고를 대신 해 줄 수는 없다.
            if inAgeRating, !text.isEmpty,
               ["해당없음", "모두없음", "없음", "none"].contains(Locales.normalizeName(text)) {
                ageRatingNone = true
            }
            guard let loc = locale, let key = field, !text.isEmpty else { return }
            var e = entries[loc] ?? Entry()
            switch normalizeField(key) {
            case .name: e.name = text
            case .subtitle: e.subtitle = text
            case .description: e.description = text
            case .keywords: e.keywords = text.replacingOccurrences(of: "\n", with: ",")
            case .promotionalText: e.promotionalText = text
            case .supportUrl: e.supportUrl = firstURL(text)
            case .marketingUrl: e.marketingUrl = firstURL(text)
            case .privacyPolicyUrl: e.privacyPolicyUrl = firstURL(text)
            case .unknown: return
            }
            entries[loc] = e
        }

        for line in stripComments(body).components(separatedBy: "\n") {
            if line.hasPrefix("## ") && !line.hasPrefix("### ") {
                flushField()
                field = nil
                let title = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                inAgeRating = Locales.normalizeName(title).contains("연령")
                    || title.lowercased().contains("age rating")
                locale = inAgeRating ? nil : sectionLocale(title, among: locales)
            } else if line.hasPrefix("###") {
                flushField()
                field = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            } else {
                buf.append(line)
            }
        }
        flushField()
        return (entries, ageRatingNone)
    }

    /// `## 한국어` · `## ko` · `## App Store (English)` 를 다 알아본다.
    private static func sectionLocale(_ title: String, among locales: [String]) -> String? {
        let t = title.trimmingCharacters(in: .whitespaces)
        if Locales.looksLikeCode(t) { return t }
        if let m = Locales.match(heading: t, among: locales) { return m }
        // 로케일 목록을 모를 때를 위한 최소한의 표. 여기 없는 언어는 `## zh-Hans` 처럼
        // 코드로 적으면 된다 — 지어내서 엉뚱한 칸에 올리는 것보다 낫다.
        let common = ["ko", "en-US", "ja", "zh-Hans", "zh-Hant", "es-ES", "fr-FR",
                      "de-DE", "pt-BR", "ru", "it", "vi", "th", "id", "tr", "ar-SA"]
        return Locales.match(heading: t, among: common)
    }

    private enum Field { case name, subtitle, description, keywords, promotionalText
                         case supportUrl, marketingUrl, privacyPolicyUrl, unknown }

    private static func normalizeField(_ raw: String) -> Field {
        let k = Locales.normalizeName(raw)
        func has(_ words: [String]) -> Bool { words.contains { k.contains($0) } }
        // 긴 것부터 본다 — "개인정보처리방침url" 이 "url" 에 먼저 걸리면 안 된다
        if has(["개인정보", "privacy"]) { return .privacyPolicyUrl }
        if has(["지원", "support"]) { return .supportUrl }
        if has(["마케팅", "marketing"]) { return .marketingUrl }
        if has(["프로모션", "홍보", "promotional", "promo"]) { return .promotionalText }
        if has(["키워드", "검색어", "keyword"]) { return .keywords }
        if has(["설명", "description"]) { return .description }
        if has(["부제", "subtitle"]) { return .subtitle }
        if has(["이름", "제목", "name", "title"]) { return .name }
        return .unknown
    }

    /// 절 본문 다듬기 — 코드펜스가 있으면 그 안이 원문이다 (RELEASE_NOTES.md 와 같은 규칙).
    private static func clean(_ lines: [String]) -> String {
        var fenced: [String] = []
        var inFence = false, sawFence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence { break }
                inFence = true; sawFence = true; continue
            }
            if inFence { fenced.append(line) }
        }
        let raw = (sawFence ? fenced : lines).joined(separator: "\n")
        // 설명문은 줄바꿈·단락이 그대로 의미라서 sanitize 하지 않는다.
        // 앞뒤 빈 줄만 걷어낸다.
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `<!-- ... -->` 는 통째로 지운다. 주석으로 꺼 둔 예시가 그대로 올라가면
    /// 뼈대 파일을 만들어 준 것이 오히려 사고가 된다 (연령 등급 신고가 특히 그렇다).
    private static func stripComments(_ body: String) -> String {
        body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "",
                                  options: .regularExpression)
    }

    private static func firstURL(_ text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map(String.init)
            .first { $0.hasPrefix("http://") || $0.hasPrefix("https://") }
    }

    // ── 검사 ────────────────────────────────────────────────────────────
    // App Store 의 글자 수 제한. 넘으면 API 가 409 로 거부하는데, 그 메시지는
    // 어느 언어의 어느 칸인지 말해 주지 않는다. 올리기 전에 우리가 말한다.
    static func problems(_ locale: String, _ e: Entry) -> [String] {
        var out: [String] = []
        func over(_ label: String, _ v: String?, _ limit: Int) {
            guard let v, v.count > limit else { return }
            out.append("\(Locales.displayName(locale)) \(label) \(v.count)자 — \(limit)자까지입니다")
        }
        over("이름", e.name, 30)
        over("부제", e.subtitle, 30)
        over("설명", e.description, 4000)
        over("키워드", e.keywords, 100)
        over("프로모션 텍스트", e.promotionalText, 170)
        if let k = e.keywords, k.contains(", ") {
            out.append("\(Locales.displayName(locale)) 키워드에 공백이 있습니다 — 쉼표만으로 나누면 글자 수를 아낍니다")
        }
        return out
    }

    // ── 뼈대 만들기 ─────────────────────────────────────────────────────
    /// 없는 앱에 APPSTORE.md 초안을 만들어 준다. 문구는 사람이 채운다 —
    /// 도구가 지어낸 설명이 스토어에 올라가면 되돌리는 데 심사가 한 번 더 든다.
    static func template(appName: String, locales: [String]) -> String {
        let list = locales.isEmpty ? ["ko"] : Locales.sorted(locales)
        var s = "# \(appName) — App Store 페이지\n\n"
        s += "DeployBar 가 이 파일을 읽어 App Store Connect 의 스토어 페이지를 채운다.\n"
        s += "적지 않은 칸은 건드리지 않는다 (빈 줄로 두면 기존 문구가 그대로 남는다).\n"
        for loc in list {
            s += "\n## \(Locales.displayName(loc)) (\(loc))\n"
            s += "\n### 이름\n\n\n### 부제\n\n\n### 설명\n\n\n### 키워드\n\n\n"
            s += "### 지원 URL\n\n\n### 개인정보처리방침 URL\n\n"
        }
        s += "\n## 연령 등급\n\n"
        s += "<!-- 내용 문항이 전부 '해당 없음' 인 앱이면 아래 줄의 주석을 풀어라.\n"
        s += "     애플에 하는 내용 신고이므로 사람이 판단해서 적는다. -->\n"
        s += "<!-- 해당 없음 -->\n"
        return s
    }
}
