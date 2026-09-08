import Foundation

// 앱스토어 스크린샷·미리보기 영상을 다시 만들 때 붙여넣을 지시문을 만든다.
//
// 왜 앱이 이 글을 쓰나: 시뮬레이터를 켜고 찍는 일 자체는 Claude Code 가 한다.
// 못 하는 건 **무엇을 다시 찍어야 하는지 아는 것**이다 —
// 지금 걸려 있는 그림이 언제 찍혔는지, 그 뒤로 어느 화면 파일이 바뀌었는지,
// 이번 버전이 스토어에서 뭘 자랑한다고 써 뒀는지는 DeployBar 만 알고 있다.
// 그걸 매번 손으로 옮겨 적지 않게 한 번에 적어 준다.
//
// ⚠️ 여기서 AI 를 부르지 않는다. 글만 만들고 실제 작업은 사람이 붙여넣은 세션이 한다
//    (릴리즈노트 번역과 달리 API 키가 필요 없는 이유).
enum ShotPrompt {

    enum Kind: String {
        case shots      // 기본 캡처 + 마케팅 합성
        case video      // 앱 미리보기 영상
        var label: String { self == .shots ? "스크린샷" : "미리보기 영상" }
    }

    // ── 만들기 ────────────────────────────────────────────────────────
    static func text(for app: ManagedApp, status: AppStatus? = nil, kind: Kind = .shots) -> String {
        let r = AppRepo.resolve(app)
        let info = try? AppRepo.buildSettings(r)
        let platform = info?.platform ?? .iOS
        let version = status?.localVersion ?? info?.marketingVersion ?? ""
        let assets = scan(app.path)
        let locales = r.locales

        var s = "\(app.path) 의 App Store \(kind.label)을 v\(version.isEmpty ? "?" : version) 에 맞게 다시 만들어줘.\n"
        s += "appstore-assets 스킬이 있으면 먼저 읽고 그 순서를 따라라. 아래는 DeployBar 가 이 앱에 대해 알고 있는 사실이다.\n"

        // ── 앱 ────────────────────────────────────────────────────────
        s += "\n## 앱\n"
        s += "- \(app.name) · \(platform.rawValue)\n"
        if r.exists {
            s += "- 프로젝트: `\(r.projFlag) \((r.projContainer as NSString).lastPathComponent)` · scheme `\(r.scheme)`\n"
        }
        if let b = info?.bundleId { s += "- 번들 ID: \(b)\n" }
        let live = status?.liveVersion.map { "v\($0)" } ?? "미등록"
        s += "- 버전: 올릴 v\(version.isEmpty ? "?" : version)(\(status?.localBuild ?? info?.buildNumber ?? "?")) · 스토어 \(live)\n"
        if !locales.isEmpty {
            s += "- 스토어 언어: \(Locales.sorted(locales).joined(separator: ", "))"
            // 스크린샷은 언어별로 따로 올릴 수 있지만 영상은 보통 한 벌로 끝낸다
            s += kind == .shots ? " — 그림도 언어별로 올릴 수 있다. 한국어부터 찍고, 나머지는 시간이 남을 때.\n" : "\n"
        }
        if platform == .iOS, let sim = simulator() {
            s += "- 시뮬레이터: \(sim)\n"
        }

        // ── 지금 있는 그림 ────────────────────────────────────────────
        s += "\n## 지금 걸려 있는 것\n"
        if let dir = assets.dir {
            let rel = relative(dir, to: app.path)
            s += "\(rel)/\(assets.newest.map { " · 마지막 갱신 \(dateLabel($0))" } ?? "")\n"
            for a in assets.files { s += "  \(a.line)\n" }
            for g in assets.groups { s += "  \(g.name)/ — \(g.count)개\n" }
        } else {
            s += "없다. `docs/screenshots/` 에 새로 만들어라 (01-, 02- … 번호 접두사).\n"
        }
        if let m = assets.script {
            s += "합성 스크립트: \(relative(m.path, to: app.path))"
            s += m.size.map { " (출력 \($0))" } ?? ""
            s += " — 원본만 다시 찍고 이 스크립트를 다시 돌리면 된다.\n"
            if let size = m.size, size != Spec.submit {
                s += "⚠️ 제출 규격은 \(Spec.submit) 이다. 스크립트의 `W, H` 를 그 값으로 고치고 렌더링해라.\n"
            }
        } else if platform == .iOS {
            s += "합성 스크립트 없음 — appstore-assets 스킬의 `scripts/make_marketing_screenshots.py` 를"
            s += " 이 레포 `scripts/` 로 복사해서 쓰고, 다음 릴리즈에 재활용하도록 커밋해라.\n"
        }

        // ── 그 뒤로 바뀐 것 ──────────────────────────────────────────
        // 이 절이 이 글의 핵심이다. "다시 찍어야 하나" 는 여기서만 답이 나온다.
        if let since = assets.newest, GitInfo.isRepo(app.path) {
            let changed = changes(app.path, since: since)
            s += "\n## 그림을 찍은 뒤 바뀐 것 — 어느 화면을 다시 찍을지의 근거\n"
            if changed.commits.isEmpty && changed.screens.isEmpty {
                s += "없다. 화면이 그대로면 다시 찍을 필요도 없다 — 규격·문구만 확인하고 끝내라.\n"
            } else {
                s += "- 커밋 \(changed.commits.count)개 (\(dayOnly(since)) 이후)\n"
                if !changed.screens.isEmpty {
                    s += "- 손댄 화면 파일: \(changed.screens.joined(separator: ", "))\n"
                }
                for c in changed.commits.prefix(12) { s += "  · \(c)\n" }
                if changed.commits.count > 12 { s += "  · … 외 \(changed.commits.count - 12)개\n" }
            }
        }

        // ── 이번 버전이 자랑하는 것 ──────────────────────────────────
        if !version.isEmpty, let notes = RepoNotes.read(app.path, version: version, locales: locales) {
            let ko = notes.texts.first(where: { Locales.isKorean($0.key) })?.value
                ?? notes.texts.sorted(by: { $0.key < $1.key }).first?.value ?? ""
            if !ko.isEmpty {
                s += "\n## 이번 버전이 스토어에서 자랑하는 것 (\(notes.source))\n"
                for line in ko.split(separator: "\n") { s += "\(line)\n" }
                s += "\n헤드라인은 여기서 뽑아라 — 기능 이름이 아니라 사용자가 얻는 것으로.\n"
            }
        }

        // ── 할 일 ────────────────────────────────────────────────────
        s += "\n## 할 일\n"
        s += kind == .shots ? shotsSteps(assets, platform: platform)
                            : videoSteps(assets, platform: platform)

        // ── 규격 ─────────────────────────────────────────────────────
        s += "\n## 규격\n"
        s += platform == .macOS ? Spec.mac : (kind == .shots ? Spec.iosShots : Spec.iosVideo)

        // ── 지켜야 할 것 ─────────────────────────────────────────────
        s += """

        ## 지켜야 할 것
        - 빌드해서 올리지 마. 배포는 DeployBar 가 한다 — 너는 시뮬레이터로 찍기만 해라.
        - **App Store Connect 에 올리는 건 사람이 웹에서 한다.** DeployBar 도 스크린샷은 안 올린다.
          너는 규격에 맞는 파일을 폴더에 놓고, 어느 파일을 어느 자리에 올리면 되는지 목록으로 알려주면 된다.
        - 원본 캡처와 최종 제출본을 같은 폴더에 섞지 마라. 다음 릴리즈에 원본만 다시 찍게.
        - 찍다가 UI 버그(잘림·번역 누락·오타)를 보면 **고치지 말고 목록으로 알려줘.** 지금 목적은 에셋이다.
        - 빈 화면(empty state)은 찍지 마라. 데이터를 먼저 만들어 넣고 찍어라.
        - 각 장을 저장한 뒤 Read 로 열어 잘림·팝업·오타를 직접 확인해라. 안 본 그림은 만든 게 아니다.
        - 다 끝나면 커밋까지 해줘. 커밋되지 않은 변경이 남으면 배포가 막힌다.
        """
        return s
    }

    // ── 단계 ─────────────────────────────────────────────────────────
    private static func shotsSteps(_ a: Assets, platform: Platform) -> String {
        if platform == .macOS {
            return """
            1. 앱을 Release 로 빌드해 실행하고, 창 크기를 규격 비율(16:10)에 맞춘다.
            2. `screencapture -l $(...windowid...) -o 01-main.png` 로 창만 찍는다 (그림자 없이).
            3. 배경·헤드라인을 붙일 거면 HTML/CSS → 헤드리스 Chrome 렌더링으로 합성한다.
            4. 각 장을 Read 로 열어 확인한다.

            """
        }
        var s = """
        1. `xcrun simctl list devices available` 에서 6.9인치급(iPhone 17 Pro Max 등)을 골라 부팅한다.
        2. Release 로 빌드해 설치·실행하고, 온보딩·권한 팝업·코치마크를 먼저 닫아 화면을 깨끗하게 만든다.
        3. 화면마다 `xcrun simctl io <UDID> screenshot <파일>` 로 **풀해상도**로 저장한다
           (MCP 스크린샷은 확인용이지 저장용이 아니다). 주요 화면 4~6장: 메인 · 핵심 기능 실행 중 · 부가 모드 · 설정.
        """
        if a.dir != nil, !a.files.isEmpty {
            s += "\n   \(a.rel)/ 의 기존 파일 이름을 그대로 덮어써라 — 합성 스크립트가 그 이름을 참조한다.\n"
        } else {
            s += "\n   `docs/screenshots/01-….png` 처럼 번호 접두사로 저장한다.\n"
        }
        s += """
        4. 마케팅 합성: 헤드라인 + 서브카피 + 디바이스 목업으로 슬라이드마다 레이아웃을 다르게
           (hero-bleed / left-text / text-bottom / flat-rotate / dark). 출력 캔버스를 \(Spec.submit) 로 두면
           변환 없이 그대로 제출할 수 있다.
        5. 렌더링한 각 장을 Read 로 열어 **핵심 UI 가 블리드에 잘리지 않았는지** 확인하고, 잘렸으면 폰 위치를 고쳐 다시 렌더링한다.

        """
        return s
    }

    private static func videoSteps(_ a: Assets, platform: Platform) -> String {
        if platform == .macOS {
            return """
            1. 앱을 실행하고 창을 규격 비율에 맞춘 뒤 `screencapture -v` 또는 QuickTime 으로 창만 녹화한다.
            2. 핵심 흐름을 2~4초 간격으로 천천히 시연한다.
            3. ffmpeg 로 정지 구간을 잘라내고 15~30초로 맞춘다.

            """
        }
        return """
        1. 녹화 시작: `xcrun simctl io <UDID> recordVideo --codec h264 --force demo.mov` (백그라운드)
           **"Recording started" 가 찍힐 때까지 기다리고 +3초 여유를 둔 뒤** 조작을 시작해라. 안 그러면 앞부분이 잘린다.
        2. 시연 흐름: 설정 → 시작 → 핵심 상태 → 전환 → 종료. 각 탭 사이에 2~4초 의도된 대기.
        3. 종료: `pkill -INT -f "simctl io.*recordVideo"` (exit code 1 은 무시). 파일이 다 써질 때까지 기다린다.
        4. 정지 구간 컷 편집 — 멈춰 있는 구간은 각 1.2초만 남긴다:
           `ffmpeg -i demo.mov -vf "freezedetect=n=0.0005:d=2.5" -map 0:v -f null - 2>&1 | grep freeze_`
           찾은 구간으로 `trim` + `concat` 하고 `scale=886:1920,fps=30` 으로 규격 변환.
        5. 완성본에서 여러 시점 프레임을 뽑아 콘택트 시트로 만들어 Read 로 확인한다.
        6. **15~30초**에 맞춘다. 넘치면 freeze 유지를 0.8초로 줄이거나 시연 단계를 덜어낸다.
        \(a.videos.isEmpty ? "" : "   (지금 걸린 영상: \(a.videos.joined(separator: ", ")))\n")

        """
    }

    // ── 규격 표 ──────────────────────────────────────────────────────
    private enum Spec {
        /// 이 사람의 App Store Connect 제출은 늘 이 크기를 쓴다.
        static let submit = "1242×2688"
        static let iosShots = """
        | 용도 | 크기(세로) |
        |---|---|
        | **iPhone 제출 규격 (이 계정이 쓰는 값)** | **\(submit)** |
        | iPhone 6.9" 원본 캡처 | 1320×2868 (시뮬레이터가 그대로 출력) |
        | iPad 13" | 2064×2752 또는 2048×2732 |

        원본(1320×2868)을 제출 규격으로 바꿀 땐 리사이즈+크롭:
        `ffmpeg -i in.png -vf "scale=1242:2699,crop=1242:2688" out.png`
        합성 파이프라인이 있으면 변환 대신 **출력 캔버스를 \(submit) 로** 두는 쪽이 화질이 좋다.

        """
        static let iosVideo = """
        | 용도 | 값 |
        |---|---|
        | 앱 미리보기 (6.5"/6.9") | 886×1920 · H.264 |
        | 길이 | **15~30초** (넘으면 App Store 가 거절한다) |

        """
        static let mac = """
        | 용도 | 크기(가로) |
        |---|---|
        | Mac App Store 스크린샷 | 1280×800 · 1440×900 · 2560×1600 · 2880×1800 중 하나 |
        | 앱 미리보기 | 1920×1080 · 15~30초 |

        """
    }

    // ── 지금 있는 에셋 훑기 ──────────────────────────────────────────
    private struct Assets {
        var dir: String?
        /// 레포 기준 상대 경로 ("docs/screenshots") — 지시문에 그대로 쓴다
        var rel: String = "docs/screenshots"
        var files: [(name: String, line: String)] = []
        var groups: [(name: String, count: Int)] = []
        var videos: [String] = []   // "demo.mp4 48초"
        var newest: Date?
        var script: (path: String, size: String?)?
    }

    private static let shotDirs = ["docs/screenshots", "screenshots", "fastlane/screenshots", "docs/스크린샷"]
    private static let imageExts = ["png", "jpg", "jpeg"]
    private static let videoExts = ["mp4", "mov", "m4v"]

    private static func scan(_ root: String) -> Assets {
        var a = Assets(dir: nil)
        let fm = FileManager.default
        a.script = marketingScript(root)

        guard let dir = shotDirs
            .map({ (root as NSString).appendingPathComponent($0) })
            .first(where: { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue })
        else { return a }
        a.dir = dir
        a.rel = relative(dir, to: root)

        let names = ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        for name in names where !name.hasPrefix(".") {
            let path = (dir as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: path, isDirectory: &isDir)
            let ext = (name as NSString).pathExtension.lowercased()
            let attrs = try? fm.attributesOfItem(atPath: path)
            if let m = attrs?[.modificationDate] as? Date, !isDir.boolValue {
                if a.newest == nil || m > a.newest! { a.newest = m }
            }
            if isDir.boolValue {
                let inner = ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                a.groups.append((name, inner.count))
            } else if imageExts.contains(ext) {
                let dim = pngSize(path).map { "\($0.w)×\($0.h)" } ?? ""
                a.files.append((name, "\(name.padded(28))\(dim)"))
            } else if videoExts.contains(ext) {
                let secs = duration(path).map { "\(Int($0.rounded()))초" } ?? ""
                a.files.append((name, "\(name.padded(28))\(secs)"))
                a.videos.append(secs.isEmpty ? name : "\(name) \(secs)")
            }
        }
        return a
    }

    /// 마케팅 합성 스크립트와 그 출력 크기 (`W, H = 1284, 2778` 를 읽는다)
    private static func marketingScript(_ root: String) -> (path: String, size: String?)? {
        for name in ["scripts/make_marketing_screenshots.py", "scripts/make_shots.py", "scripts/make_shot.py"] {
            let path = (root as NSString).appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            var size: String?
            if let body = try? String(contentsOfFile: path, encoding: .utf8),
               let m = body.range(of: #"W,\s*H\s*=\s*(\d+),\s*(\d+)"#, options: .regularExpression) {
                let nums = body[m].split(whereSeparator: { !$0.isNumber }).map(String.init)
                if nums.count == 2 { size = "\(nums[0])×\(nums[1])" }
            }
            return (path, size)
        }
        return nil
    }

    /// PNG 머리(IHDR)에서 크기를 읽는다 — 파일 하나에 프로세스 하나씩 띄우지 않으려고.
    private static func pngSize(_ path: String) -> (w: Int, h: Int)? {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 24), head.count == 24,
              head.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]) else { return nil }
        func be(_ r: Range<Int>) -> Int { head[r].reduce(0) { $0 << 8 | Int($1) } }
        return (be(16..<20), be(20..<24))
    }

    /// 영상 길이 — Spotlight 가 이미 알고 있다 (ffprobe 가 없어도 된다)
    private static func duration(_ path: String) -> Double? {
        let out = (try? Shell.capture("/usr/bin/mdls", ["-name", "kMDItemDurationSeconds", "-raw", path])) ?? ""
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // ── 그림을 찍은 뒤의 변화 ────────────────────────────────────────
    private static func changes(_ dir: String, since: Date) -> (commits: [String], screens: [String]) {
        let iso = ISO8601DateFormatter().string(from: since)
        func git(_ args: [String]) -> String {
            (try? Shell.capture("/usr/bin/git", args, cwd: URL(fileURLWithPath: dir))) ?? ""
        }
        let commits = git(["log", "--since", iso, "--pretty=%s"])
            .split(separator: "\n").map(String.init)
        // 화면 파일만 고른다 — 커밋 목록만으로는 "찍은 그림이 낡았나" 에 답이 안 된다
        let files = Set(git(["log", "--since", iso, "--name-only", "--pretty=format:", "--", "*.swift"])
            .split(separator: "\n").map { ($0 as NSString).lastPathComponent })
        let screens: [String] = files
            .filter { (n: String) in n.contains("View") || n.contains("Screen") || n.contains("Panel") }
            .sorted().prefix(12).map { $0 }
        return (commits, screens)
    }

    // ── 시뮬레이터 ───────────────────────────────────────────────────
    /// 6.9인치급 기기 하나. 부팅돼 있으면 그걸 먼저 준다 — 새로 부팅할 이유가 없다.
    private static func simulator() -> String? {
        let out = (try? Shell.capture("/usr/bin/xcrun", ["simctl", "list", "devices", "available"])) ?? ""
        let lines = out.split(separator: "\n").map(String.init)
            .filter { $0.contains("iPhone") && $0.contains("(") }
        func pick(_ f: (String) -> Bool) -> String? { lines.last(where: f) }
        let line = pick { $0.contains("Booted") }
            ?? pick { $0.contains("Pro Max") }
            ?? lines.last
        guard let line else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        let name = t.components(separatedBy: " (").first ?? t
        let udid = t.components(separatedBy: " (").dropFirst().first?
            .components(separatedBy: ")").first ?? ""
        let booted = t.contains("Booted")
        return "\(name) · \(udid)\(booted ? " (부팅됨)" : " (꺼짐 — `xcrun simctl boot \(udid)`)")"
    }

    // ── 표시 ─────────────────────────────────────────────────────────
    private static func relative(_ path: String, to root: String) -> String {
        path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    /// 날짜만 ("8월 23일") — 문장 안에 상대일수까지 넣으면 "16일 전 이후" 가 된다
    private static func dayOnly(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        return f.string(from: d)
    }

    private static func dateLabel(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "M월 d일"
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        return days <= 0 ? "오늘" : "\(f.string(from: d)) · \(days)일 전"
    }
}

private extension String {
    func padded(_ n: Int) -> String {
        count >= n ? self + " " : self + String(repeating: " ", count: n - count)
    }
}
