import Foundation

// 다국어 게이트 — .xcstrings 를 직접 읽어 "번역 구멍"을 배포 전에 잡는다.
//
// 앱마다 scripts/check_localization.py 를 따로 두던 검사를 DeployBar 안으로 들여왔다.
// 스크립트가 없는 앱도 같은 기준으로 검사받게 하는 게 목적이다.
//
// 잡는 것:
//   1) 미번역   — 지원 언어인데 그 언어 값이 없다 (→ 소스 언어 문자열이 그대로 노출)
//   2) 미완료   — state 가 new / stale / needs_review (번역이 뒤처졌다는 Xcode 의 표시)
//   3) 언어 혼입 — 한국어가 아닌 언어 값에 한글이 들어 있다 (영어 유저가 한글을 봄)
enum Localization {

    enum Kind: String {
        case missing = "미번역"
        case incomplete = "미완료"
        case korean = "한글 혼입"
    }

    struct Issue {
        let file: String        // 앱 폴더 기준 상대 경로
        let locale: String
        let key: String
        let kind: Kind
        var line: String { "\(kind.rawValue) · \(locale) · \(file) · \"\(Localization.trim(key))\"" }
    }

    struct Report {
        var files: [String] = []
        var locales: [String] = []     // xcstrings 에서 발견한 언어 (소스 언어 포함)
        var sourceLanguages: [String] = []
        var keyCount = 0
        var issues: [Issue] = []
        var scanned: Bool { !files.isEmpty }
        var ok: Bool { issues.isEmpty }

        // 언어별 이슈 수 (많은 순)
        var byLocale: [(locale: String, count: Int)] {
            Dictionary(grouping: issues, by: { $0.locale })
                .map { (locale: $0.key, count: $0.value.count) }
                .sorted { $0.count == $1.count ? $0.locale < $1.locale : $0.count > $1.count }
        }
    }

    // 게이트 강도 — deploy.env 의 LOCALIZATION_GATE
    enum Mode: String {
        case strict, warn, off
        init(_ raw: String?) { self = Mode(rawValue: (raw ?? "").lowercased()) ?? .warn }
    }

    private static let hangul = try! NSRegularExpression(pattern: "[가-힣]")

    /// 서식 지정자(%@ · %1$lld …)와 {토큰} 을 걷어내고도 글자가 남는가.
    /// 남지 않으면 옮길 문장이 없는 키다.
    static func hasTranslatableText(_ s: String) -> Bool {
        var body = s.replacingOccurrences(
            of: "%[0-9]*\\$?[@a-zA-Z]|%[0-9]*\\$?l{0,2}[dfsu]",
            with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: "\\{[^}]*\\}", with: " ", options: .regularExpression)
        return body.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    static func hasHangul(_ s: String) -> Bool {
        hangul.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func trim(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > 48 ? String(one.prefix(48)) + "…" : one
    }

    // 앱 폴더에서 .xcstrings 를 찾는다 (build/DerivedData/Pods 등은 제외)
    static func findCatalogs(_ dir: String, maxDepth: Int = 4) -> [String] {
        let skip: Set<String> = ["build", "DerivedData", "Pods", "Carthage", ".git", ".build", "fastlane"]
        var out: [String] = []
        let root = URL(fileURLWithPath: dir)
        var queue: [(URL, Int)] = [(root, 0)]
        while let (url, depth) = queue.popLast() {
            guard depth <= maxDepth else { continue }
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in entries {
                if name.hasPrefix(".") || skip.contains(name) { continue }
                let child = url.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    // .xcodeproj/.xcassets 같은 번들 내부는 볼 필요 없다
                    if name.contains(".xcodeproj") || name.contains(".xcworkspace") || name.hasSuffix(".xcassets") { continue }
                    queue.append((child, depth + 1))
                } else if name.hasSuffix(".xcstrings") {
                    out.append(child.path)
                }
            }
        }
        return out.sorted()
    }

    /// 앱 폴더의 모든 .xcstrings 를 검사한다.
    /// - expected: 반드시 채워져 있어야 할 언어. 비우면 카탈로그에 실제로 등장한 언어들을 기준으로 삼는다.
    static func scan(_ dir: String, expected: [String] = []) -> Report {
        var report = Report()
        let catalogs = findCatalogs(dir)
        guard !catalogs.isEmpty else { return report }

        // InfoPlist.xcstrings 는 앱 이름·권한 문구라 소스 언어만 있는 게 정상인 경우가 많다.
        // 그래도 값이 있는 언어의 한글 혼입은 잡아야 하므로 검사 대상에는 남긴다.
        var found = Set<String>()
        var sources = Set<String>()
        var parsed: [(path: String, rel: String, source: String, strings: [String: Any], isInfoPlist: Bool)] = []

        for path in catalogs {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let strings = json["strings"] as? [String: Any] else { continue }
            let source = json["sourceLanguage"] as? String ?? "en"
            let rel = path.hasPrefix(dir + "/") ? String(path.dropFirst(dir.count + 1)) : path
            sources.insert(source)
            found.insert(source)
            for (_, v) in strings {
                guard let entry = v as? [String: Any],
                      let locs = entry["localizations"] as? [String: Any] else { continue }
                found.formUnion(locs.keys)
            }
            report.keyCount += strings.count
            parsed.append((path, rel, source, strings, (path as NSString).lastPathComponent == "InfoPlist.xcstrings"))
        }
        report.files = parsed.map { $0.rel }
        report.locales = Locales.sorted(Array(found))
        report.sourceLanguages = sources.sorted()
        guard !parsed.isEmpty else { return report }

        // 기준 언어 목록 = 카탈로그에 실제로 있는 언어 **∪** deploy.env 의 LOCALES.
        //
        // 예전엔 LOCALES 가 있으면 그것'만' 검사했다. 그래서 LOCALES 를 줄이는 순간
        // 카탈로그에 멀쩡히 있는 언어의 번역 구멍이 조용히 안 보이게 됐다 —
        // 소스 언어 하나만 남기면 게이트는 늘 통과한다(소스는 값이 없어도 정상이므로).
        // 앱이 이미 그 언어로 말하고 있으면 구멍은 실제로 외국 사용자에게 보이는 문제다.
        // LOCALES 는 "여기에 더해 이 언어도 갖출 것" 이라는 선언으로만 쓴다.
        //
        // (LOCALES 를 줄이는 이유는 대개 App Store 페이지에 그 언어가 없어서인데,
        //  그건 스토어 쪽 사정이지 앱이 그 언어를 안 한다는 뜻이 아니다.)
        let targets = Locales.sorted(Array(Set(report.locales).union(expected)))

        for file in parsed {
            for (key, raw) in file.strings {
                guard let entry = raw as? [String: Any] else { continue }
                // 번역 대상이 아니라고 표시된 문자열은 건너뛴다
                if let should = entry["shouldTranslate"] as? Bool, should == false { continue }
                // 빈 키는 화면에 아무것도 안 나오는 잔재 항목 — 번역 구멍이 아니다
                if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                // Xcode 가 stale 로 표시한 키 = 코드 어디에서도 더 이상 안 쓰는 문자열.
                //
                // 이걸 세면 **고칠 수 없는 경고**가 된다. 사람이 번역을 채워도 다음 배포에
                // 또 나오고(안 쓰는 키니까), 지우자니 Xcode 가 카탈로그에 계속 들고 있다.
                // 클립키보드는 이렇게 쌓인 잔재가 377개라 "번역 구멍 417건" 이 떴는데
                // 그중 실제로 사용자에게 보이는 건 0건이었다. 앱의 i18n 검사는 통과하는데
                // DeployBar 만 빨간, 아무도 못 믿는 숫자였다.
                if let st = entry["extractionState"] as? String, st == "stale" { continue }
                // 자리표시자뿐인 키는 옮길 글이 없다.
                // "{가격}" 은 글자가 들어 있지만 통째로 토큰이라 번역할 문장이 아니다 —
                // 이런 걸 세면 채울 수도 없는 구멍이 영원히 남는다.
                if !hasTranslatableText(key) { continue }
                let locs = entry["localizations"] as? [String: Any] ?? [:]

                for target in targets {
                    // 소스 언어는 값이 없어도 키 자체가 쓰이므로 정상
                    let isSource = Locales.sameLanguage(target, file.source)
                    let match = locs.first { Locales.sameLanguage($0.key, target) }

                    guard let unit = match.map({ units($0.value) }) else {
                        // InfoPlist 는 소스 언어만 두는 게 흔해 미번역로 몰아세우지 않는다
                        if !isSource && !file.isInfoPlist {
                            report.issues.append(Issue(file: file.rel, locale: target, key: key, kind: .missing))
                        }
                        continue
                    }
                    if unit.isEmpty {
                        if !isSource && !file.isInfoPlist {
                            report.issues.append(Issue(file: file.rel, locale: target, key: key, kind: .missing))
                        }
                        continue
                    }
                    for (state, value) in unit {
                        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if !isSource { report.issues.append(Issue(file: file.rel, locale: target, key: key, kind: .missing)) }
                            continue
                        }
                        if ["new", "stale", "needs_review"].contains(state), !isSource {
                            report.issues.append(Issue(file: file.rel, locale: target, key: key, kind: .incomplete))
                        }
                        // 한국어가 아닌 언어에 한글이 남아 있으면 번역이 안 된 것
                        if !Locales.isKorean(target), hasHangul(value) {
                            report.issues.append(Issue(file: file.rel, locale: target, key: key, kind: .korean))
                        }
                    }
                }
            }
        }
        return report
    }

    // localizations[locale] 안의 stringUnit / variations 를 (state, value) 목록으로 펼친다.
    // 복수형·기기별 변형(variations)까지 봐야 "복수형만 미번역"인 구멍을 잡는다.
    private static func units(_ raw: Any) -> [(String, String)] {
        guard let dict = raw as? [String: Any] else { return [] }
        var out: [(String, String)] = []
        if let u = dict["stringUnit"] as? [String: Any] {
            out.append((u["state"] as? String ?? "", u["value"] as? String ?? ""))
        }
        if let variations = dict["variations"] as? [String: Any] {
            for (_, group) in variations {
                guard let cases = group as? [String: Any] else { continue }
                for (_, c) in cases { out.append(contentsOf: units(c)) }
            }
        }
        return out
    }

    // 배포 로그용 요약 (최대 maxLines 개까지 상세)
    static func summaryLines(_ r: Report, mode: Mode, maxLines: Int = 12) -> [String] {
        guard r.scanned else {
            return ["🌐 다국어 검사: .xcstrings 없음 — 단일 언어 앱으로 보고 건너뜁니다"]
        }
        var out = ["🌐 다국어 검사: \(r.files.count)개 카탈로그 · \(r.keyCount)개 문자열 · 언어 \(r.locales.joined(separator: ", "))"]
        if r.ok {
            out.append("   ✓ 번역 구멍 없음")
            return out
        }
        let head = r.byLocale.map { "\($0.locale) \($0.count)건" }.joined(separator: ", ")
        out.append("   \(mode == .strict ? "❌" : "⚠️") 번역 문제 \(r.issues.count)건 — \(head)")
        for issue in r.issues.prefix(maxLines) { out.append("     · \(issue.line)") }
        if r.issues.count > maxLines { out.append("     … 외 \(r.issues.count - maxLines)건") }
        if mode != .strict {
            out.append("   ↳ deploy.env 에 LOCALIZATION_GATE=strict 를 넣으면 이 상태에서 배포가 중단됩니다")
        }
        return out
    }
}
