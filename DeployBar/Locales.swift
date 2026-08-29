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
