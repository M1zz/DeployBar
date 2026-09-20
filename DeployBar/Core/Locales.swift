import Foundation

// App Store Connect 로케일 ↔ 표시 이름 ↔ 온디바이스 번역 언어 매핑.
//
// ASC 로케일은 "ko", "en-US", "zh-Hans", "pt-BR" 처럼 지역이 붙기도 하고 안 붙기도 한다.
// 반면 Apple Translation 은 "ko", "en", "zh-Hans" 같은 언어 코드를 받는다.
// 이 사이를 오가는 변환을 한 곳에 모아 둔다 — 로케일 처리가 여러 파일에 흩어지면
// "한/영만 반영되고 나머지는 조용히 건너뛰는" 버그가 다시 생긴다.
enum Locales {

    // "en-US" → "en", "zh-Hans" → "zh-Hans" (스크립트 표기는 유지)
    static func language(_ locale: String) -> String {
        let parts = locale.split(separator: "-").map(String.init)
        guard parts.count > 1 else { return locale }
        // 두 번째 조각이 4글자면 스크립트(Hans/Hant) → 언어의 일부로 유지
        if parts[1].count == 4 { return "\(parts[0])-\(parts[1])" }
        return parts[0]
    }

    // 한국어 표시 이름 ("ko" → "한국어", "zh-Hans" → "중국어(간체)")
    static func displayName(_ locale: String) -> String {
        let ko = Locale(identifier: "ko_KR")
        if let n = ko.localizedString(forIdentifier: locale.replacingOccurrences(of: "-", with: "_")) {
            return n
        }
        return ko.localizedString(forIdentifier: language(locale)) ?? locale
    }

    // Apple Translation(온디바이스)이 지원하는 언어. 미지원 언어는 AI 번역으로만 채운다.
    // 출처: Apple Translate 지원 언어 (macOS 15+). 지역 변형은 언어 코드로 축약해 판단.
    private static let onDeviceLanguages: Set<String> = [
        "ar", "zh-Hans", "zh-Hant", "nl", "en", "fr", "de", "hi", "id", "it",
        "ja", "ko", "pl", "pt", "ru", "es", "th", "tr", "uk", "vi",
    ]

    static func supportsOnDeviceTranslation(_ locale: String) -> Bool {
        onDeviceLanguages.contains(language(locale))
    }

    // 두 로케일이 같은 언어인지 ("en-US" 와 "en-GB" 는 같은 언어 → 번역 결과 재사용)
    static func sameLanguage(_ a: String, _ b: String) -> Bool {
        language(a).caseInsensitiveCompare(language(b)) == .orderedSame
    }

    static func isKorean(_ locale: String) -> Bool { language(locale) == "ko" }

    // xcstrings 의 로케일 키를 ASC 로케일 후보로 넓힌다 ("en" ↔ "en-US" 매칭용)
    static func matches(xcstrings x: String, asc: String) -> Bool { sameLanguage(x, asc) }

    // ── 제목이 가리키는 언어 ────────────────────────────────────────
    /// `### 앱스토어 (중국어 간체)` 같은 절 제목이 어느 로케일을 말하는지.
    ///
    /// 이 앱이 실제로 쓰는 로케일 목록에 대고만 맞춘다 — 세상의 모든 언어 이름을
    /// 표로 들고 있을 이유가 없고, 목록 밖의 언어는 알아봐야 올릴 자리도 없다.
    /// RELEASE_NOTES.md 와 APPSTORE.md 가 **같은 표**를 봐야 한쪽에서만 읽히는 일이 없다.
    static func match(heading: String, among locales: [String]) -> String? {
        let h = normalizeName(heading)
        guard !h.isEmpty else { return nil }
        var best: (locale: String, score: Int)?
        for loc in locales {
            for alias in aliases(for: loc) where h.contains(alias) {
                // 더 긴 이름이 이긴다 — "중국어(간체)" 가 "중국어" 보다 구체적이다
                if best == nil || alias.count > best!.score { best = (loc, alias.count) }
            }
        }
        return best?.locale
    }

    /// 로케일 하나를 제목에서 알아볼 이름들 (한국어 이름·영어 이름·현지 이름·코드).
    static func aliases(for locale: String) -> [String] {
        var out: Set<String> = []
        let ids = Set([locale, language(locale)])
        for id in ids {
            let under = id.replacingOccurrences(of: "-", with: "_")
            // 코드 자체 ("zh-Hans" → "zhhans"). 두 글자 코드("ko","en")는 아무 단어에나
            // 걸리므로 쓰지 않는다 — 이름으로 충분하다.
            let code = normalizeName(id)
            if code.count >= 4 { out.insert(code) }
            for named in [Locale(identifier: "ko_KR"), Locale(identifier: "en_US"), Locale(identifier: under)] {
                if let n = named.localizedString(forIdentifier: under) {
                    let x = normalizeName(n)
                    if x.count >= 2 { out.insert(x) }
                }
            }
        }
        return Array(out)
    }

    /// 이름 대조용 정규화 — 괄호·공백·하이픈을 걷어내고 소문자로.
    /// "중국어(간체)" 와 "중국어 간체" 가 같은 것으로 읽혀야 한다.
    static func normalizeName(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// 로케일 코드처럼 생겼나 — `## ko`, `## en-US`, `## zh-Hans` 를 제목 그대로 받아들이기 위해.
    /// 이 앱의 로케일 목록을 아직 모를 때(첫 출시 앱)도 절을 읽을 수 있어야 한다.
    static func looksLikeCode(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.range(of: "^[a-z]{2}(-[A-Za-z]{2,4})?$", options: .regularExpression) != nil
    }

    // 번역 대상 언어 정렬 — 한국어·영어를 앞에, 나머지는 이름순
    static func sorted(_ locales: [String]) -> [String] {
        locales.sorted { a, b in
            func rank(_ l: String) -> Int {
                if isKorean(l) { return 0 }
                if language(l) == "en" { return 1 }
                return 2
            }
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            return a < b
        }
    }
}
