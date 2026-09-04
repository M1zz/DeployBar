import Foundation

// 레포에 **사람이 이미 써 둔** 릴리즈노트를 찾아 읽는다.
//
// 왜 필요한가: 이 앱들 중 상당수가 RELEASE_NOTES.md / CHANGELOG.md 에
// "앱스토어용 짧은 버전" 을 따로 써 둔다. 스토어에서 그대로 읽히는 글이라
// 공들여 다듬은 문장이다. 그런데 DeployBar 는 그걸 한 번도 보지 않고
// 커밋 제목에서 초안을 새로 만들었다 — 그래서 배포할 때마다
// "모아둔 재 회수·재의 흐름 화면·1년 열람 (1.0.9)" 같은 개발자용 문구가 올라갔다.
//
// 사람이 쓴 글이 있으면 그게 1순위다. AI 도 커밋도 그다음이다.
//
// ⚠️ 없는 걸 지어내지 않는다. **스토어용이라고 명시된 절**만 가져온다.
//    "상세 변경 사항" 이나 "개발 메모" 를 스토어에 올리는 사고는 되돌릴 수 없다.
enum RepoNotes {

    struct Found {
        /// 언어 코드 → 문구 (ko / ja / en 을 글자를 보고 정한다)
        var texts: [String: String]
        /// 어느 파일 어느 절에서 가져왔나 (로그에 그대로 남긴다)
        var source: String
    }

    private static let candidates = [
        "RELEASE_NOTES.md", "RELEASENOTES.md", "CHANGELOG.md",
        "docs/RELEASE_NOTES.md", "docs/CHANGELOG.md",
    ]

    /// 스토어에 올릴 글이라고 **명시된** 절만 받아들인다.
    private static let storeMarkers = [
        "앱스토어", "app store", "appstore", "스토어",
        "새로운 기능", "what's new", "whats new", "짧은 버전", "붙여넣기",
    ]
    /// 이게 들어간 절은 스토어용 표시가 있어도 쓰지 않는다.
    private static let neverMarkers = ["개발 메모", "상세", "내부", "노출 안 함", "detail"]

    static func read(_ dir: String, version: String) -> Found? {
        for name in candidates {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let body = try? String(contentsOfFile: path, encoding: .utf8),
                  let block = versionBlock(body, version: version) else { continue }
            let texts = storeTexts(in: block)
            if !texts.isEmpty { return Found(texts: texts, source: "\(name) · v\(version)") }
        }
        return nil
    }

    // ── "## 1.0.9" 절 잘라내기 ────────────────────────────────────────
    // 버전 앞뒤로 숫자·점이 붙지 않아야 한다 — 그러지 않으면 1.0.1 이 1.0.10 에 걸린다.
    private static func versionBlock(_ body: String, version: String) -> [String]? {
        let esc = NSRegularExpression.escapedPattern(for: version)
        let pattern = "(?<![0-9.])\(esc)(?![0-9.])"
        let lines = body.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { line in
            line.hasPrefix("## ") && line.range(of: pattern, options: .regularExpression) != nil
        }) else { return nil }
        let rest = lines[(start + 1)...]
        let end = rest.firstIndex { $0.hasPrefix("## ") } ?? lines.endIndex
        return Array(lines[(start + 1)..<end])
    }

    // ── 절 안에서 스토어용 문구 찾기 ──────────────────────────────────
    private static func storeTexts(in block: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var heading: String?
        var buf: [String] = []

        func flush() {
            defer { buf = []; }
            guard let h = heading?.lowercased() else { return }
            guard storeMarkers.contains(where: { h.contains($0) }) else { return }
            guard !neverMarkers.contains(where: { h.contains($0) }) else { return }
            let text = extractText(buf)
            guard !text.isEmpty, let lang = language(of: text) else { return }
            // 같은 언어가 두 번 나오면 앞의 것을 쓴다 (스토어용이 대개 먼저 온다)
            if out[lang] == nil { out[lang] = text }
        }

        for line in block {
            if line.hasPrefix("#") {          // ###, ####… 어떤 깊이든 새 절
                flush()
                heading = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            } else {
                buf.append(line)
            }
        }
        flush()
        return out
    }

    /// 절 본문에서 실제 문구만. 코드펜스(```)가 있으면 그 안이 곧 붙여넣기용 원문이다.
    private static func extractText(_ lines: [String]) -> String {
        var fenced: [String] = []
        var inFence = false
        var sawFence = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inFence { break }          // 첫 블록만 쓴다
                inFence = true; sawFence = true; continue
            }
            if inFence { fenced.append(line) }
        }
        // 펜스가 없으면 절 본문을 그대로 (글머리표·이모지는 sanitize 가 걷어낸다)
        let raw = (sawFence ? fenced : lines).joined(separator: "\n")
        return ReleaseNotes.sanitize(raw)
    }

    /// 글자를 보고 언어를 정한다. 절 제목으로 판단하면 틀린다 —
    /// `### App Store "이번 버전의 새로운 기능"` 밑에 한국어가 들어 있는 앱이 실제로 있다.
    /// 모르는 언어는 **비워 둔다**. 잘못 붙이면 엉뚱한 언어 칸에 올라간다.
    private static func language(of text: String) -> String? {
        let hangul = text.unicodeScalars.contains { 0xAC00...0xD7A3 ~= $0.value || 0x3131...0x318E ~= $0.value }
        if hangul { return "ko" }
        // 가나(히라가나·가타카나)가 있으면 일본어다. 한자만으로는 중국어와 구분되지 않으므로
        // 가나를 요구한다 — 애매하면 붙이지 않는 쪽이 안전하다 (엉뚱한 언어 칸에 올라간다).
        let kana = text.unicodeScalars.contains { 0x3041...0x309F ~= $0.value || 0x30A0...0x30FF ~= $0.value }
        if kana { return "ja" }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return nil }
        let latin = letters.filter { $0.value < 0x250 }.count
        return Double(latin) / Double(letters.count) > 0.9 ? "en" : nil
    }
}
