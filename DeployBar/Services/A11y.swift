import Foundation

// '앱의 손쉬운 사용' (Accessibility Nutrition Labels) 의 **원본은 레포의 APPSTORE.md** 다.
//
//   ## 손쉬운 사용
//
//   ### iPhone
//   voiceOver
//   largerText
//
//   ### iPad
//   (키가 없으면 '지원 기능 없음' 으로 신고)
//
// 기기 절은 레포에 적은 것만 맞춘다. 적지 않은 기기는 스토어에 무엇이 있든 건드리지 않는다.
// 모르는 기기·키는 몇 번째 줄인지 말하고 **아무것도 올리지 않는다** — 반쯤 맞는 신고를 내는 것보다 낫다.
enum A11y {

    static let heading = "손쉬운 사용"

    enum Device: String, CaseIterable {
        case iPhone = "IPHONE", iPad = "IPAD", mac = "MAC"
        case watch = "APPLE_WATCH", tv = "APPLE_TV", vision = "VISION"

        var label: String {
            switch self {
            case .iPhone: return "iPhone"
            case .iPad: return "iPad"
            case .mac: return "Mac"
            case .watch: return "Apple Watch"
            case .tv: return "Apple TV"
            case .vision: return "Apple Vision Pro"
            }
        }

        /// `### iPhone` · `### Apple Watch` … 공백·대소문자는 가리지 않는다.
        init?(heading: String) {
            let k = heading.lowercased().filter { !$0.isWhitespace }
            switch k {
            case "iphone": self = .iPhone
            case "ipad": self = .iPad
            case "mac": self = .mac
            case "applewatch": self = .watch
            case "appletv": self = .tv
            case "applevisionpro", "visionpro": self = .vision
            default: return nil
            }
        }
    }

    /// 레포 키 → API 속성 → 화면 이름 (App Store Connect 한국어 화면과 같은 말)
    static let features: [(key: String, attribute: String, label: String)] = [
        ("voiceOver", "supportsVoiceover", "VoiceOver"),
        ("voiceControl", "supportsVoiceControl", "음성 명령"),
        ("largerText", "supportsLargerText", "더 큰 텍스트"),
        ("darkInterface", "supportsDarkInterface", "다크 모드 인터페이스"),
        ("differentiateWithoutColor", "supportsDifferentiateWithoutColorAlone", "색상 사용 없이 구별"),
        ("sufficientContrast", "supportsSufficientContrast", "충분한 대비"),
        ("reducedMotion", "supportsReducedMotion", "동작 줄이기"),
        ("captions", "supportsCaptions", "자막"),
        ("audioDescriptions", "supportsAudioDescriptions", "오디오 설명"),
    ]
    static var attributes: [String] { features.map(\.attribute) }

    /// 속성 집합을 사람이 읽는 한 줄로 (표의 순서대로)
    static func describe(_ supports: Set<String>) -> String {
        let names = features.filter { supports.contains($0.attribute) }.map(\.label)
        return names.isEmpty ? "지원 기능 없음" : names.joined(separator: " · ")
    }

    struct Declaration: Equatable {
        var device: Device
        var supports: Set<String>
    }

    struct Parsed {
        var source = ""
        var declarations: [Declaration] = []
        var errors: [String] = []
    }

    // ── 읽기 ────────────────────────────────────────────────────────────
    /// nil = APPSTORE.md 가 없거나 `## 손쉬운 사용` 절이 없다 → 스토어를 건드리지 않는다.
    static func read(_ dir: String) -> Parsed? {
        for name in StoreMeta.candidates {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let body = try? String(contentsOfFile: path, encoding: .utf8),
                  var parsed = parse(body, file: name) else { continue }
            parsed.source = name
            return parsed
        }
        return nil
    }

    static func parse(_ body: String, file: String = "APPSTORE.md") -> Parsed? {
        var out = Parsed()
        var inSection = false, found = false
        var current: Int?               // out.declarations 의 지금 절
        for (i, raw) in blankComments(body).components(separatedBy: "\n").enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let at = "\(file) \(i + 1)행"
            if line.hasPrefix("## ") {
                inSection = line.dropFirst(3).trimmingCharacters(in: .whitespaces) == heading
                found = found || inSection
                current = nil
                continue
            }
            guard inSection, !line.isEmpty else { continue }
            if line.hasPrefix("#") {
                let title = String(line.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("### "), let device = Device(heading: title) else {
                    out.errors.append("\(at): 모르는 기기 '\(title)' — \(Device.allCases.map { "### \($0.label)" }.joined(separator: " · ")) 중 하나여야 합니다")
                    current = nil; continue
                }
                if out.declarations.contains(where: { $0.device == device }) {
                    out.errors.append("\(at): '### \(device.label)' 절이 두 번 있습니다")
                    current = nil; continue
                }
                out.declarations.append(Declaration(device: device, supports: []))
                current = out.declarations.count - 1
                continue
            }
            let key = line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces) : line
            guard let f = features.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame }) else {
                out.errors.append("\(at): 모르는 키 '\(key)' — \(features.map(\.key).joined(separator: ", ")) 중 하나여야 합니다")
                continue
            }
            guard let c = current else {
                out.errors.append("\(at): '\(key)' 가 어느 기기 절(### iPhone 등)에도 속하지 않습니다")
                continue
            }
            out.declarations[c].supports.insert(f.attribute)
        }
        return found ? out : nil
    }

    /// `<!-- … -->` 를 지우되 줄 수는 그대로 둔다 — 오류가 말하는 행 번호가 파일과 맞아야 한다.
    private static func blankComments(_ body: String) -> String {
        var s = body
        while let open = s.range(of: "<!--") {
            let close = s.range(of: "-->", range: open.upperBound..<s.endIndex)
            let end = close?.upperBound ?? s.endIndex
            let newlines = String(repeating: "\n", count: s[open.lowerBound..<end].filter { $0 == "\n" }.count)
            s.replaceSubrange(open.lowerBound..<end, with: newlines)
        }
        return s
    }

    // ── 맞추기 ──────────────────────────────────────────────────────────
    enum Action: Equatable {
        case same                       // 게시본이 레포와 같다
        case create                     // 초안을 새로 만들어 게시
        case updateDraft(String)        // 남아 있던 초안을 고쳐 게시
    }

    struct Step {
        var want: Declaration
        var live: Set<String>?          // 지금 게시된 것 (없으면 nil)
        var action: Action
    }

    static func plan(_ repo: [Declaration], live: [ASCClient.AccessibilityDeclaration]) -> [Step] {
        repo.map { d in
            let mine = live.filter { $0.deviceFamily == d.device.rawValue }
            let published = mine.first { $0.state == "PUBLISHED" }?.supports
            if published == d.supports { return Step(want: d, live: published, action: .same) }
            if let draft = mine.first(where: { $0.state == "DRAFT" }) {
                return Step(want: d, live: published, action: .updateDraft(draft.id))
            }
            return Step(want: d, live: published, action: .create)
        }
    }

    struct Outcome {
        var changed: [String] = []
        var kept: [String] = []
        var warnings: [String] = []
    }

    /// 레포 신고를 스토어에 맞춘다. **던지지 않는다** — 배포를 막을 일이 아니라서 실패는 경고 한 줄이 된다.
    /// 기기 하나가 거부돼도 나머지 기기는 계속한다.
    /// - live: 이미 읽어 둔 스토어의 신고 (`--a11y` 가 보여 주려고 읽은 것). nil 이면 여기서 읽는다.
    static func sync(appId: String, repo: Parsed, dryRun: Bool,
                     live known: [ASCClient.AccessibilityDeclaration]? = nil,
                     onLog: (String) -> Void = { _ in }) async -> Outcome {
        var o = Outcome()
        guard repo.errors.isEmpty else {
            o.warnings.append("손쉬운 사용: \(repo.source) 의 `## 손쉬운 사용` 에 잘못된 줄이 있어 올리지 않았습니다 — " + repo.errors.joined(separator: " / "))
            return o
        }
        let live: [ASCClient.AccessibilityDeclaration]
        do {
            if let known { live = known } else { live = try await ASCClient.accessibilityDeclarations(appId: appId) }
        } catch {
            o.warnings.append("손쉬운 사용: 스토어의 신고를 읽지 못했습니다 — \(StorePublish.reason(error))")
            return o
        }
        for step in plan(repo.declarations, live: live) {
            let d = step.want, label = d.device.label
            if step.action == .same {
                o.kept.append("손쉬운 사용 \(label) — 이미 레포와 같습니다")
                continue
            }
            let what = "손쉬운 사용 \(label) 게시: \(describe(d.supports))"
            if dryRun { o.changed.append("\(what) (미리보기)"); continue }
            var created: String?
            do {
                let id: String
                switch step.action {
                case .updateDraft(let draft):
                    try await ASCClient.updateAccessibilityDeclaration(id: draft, supports: d.supports)
                    id = draft
                default:
                    id = try await ASCClient.createAccessibilityDeclaration(appId: appId, deviceFamily: d.device.rawValue,
                                                                            supports: d.supports)
                    created = id
                }
                try await ASCClient.publishAccessibilityDeclaration(id: id)
                o.changed.append(what)
                onLog("♿️ \(what)")
            } catch {
                // 이번에 만든 초안이 게시되지 못했으면 거둔다 — 스토어에 주인 없는 초안을 남기지 않는다
                if let created { try? await ASCClient.deleteAccessibilityDeclaration(id: created) }
                o.warnings.append(refusal(label, error))
            }
        }
        return o
    }

    /// 애플은 그 기기로 출시한 적이 있는 앱에만 신고를 받는다. 409·422 는 대개 그 뜻이다.
    static func refusal(_ label: String, _ error: Error) -> String {
        let why = StorePublish.reason(error)
        if let e = error as? ASCClient.APIError, [409, 422].contains(e.status) {
            return "\(label) 는 아직 출시된 버전이 없어 손쉬운 사용을 게시하지 못함 (애플: \(why))"
        }
        return "\(label) 손쉬운 사용을 게시하지 못함 — \(why)"
    }
}
