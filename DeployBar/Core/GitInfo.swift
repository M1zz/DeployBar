import Foundation

enum GitInfo {
    private static func git(_ dir: String, _ args: [String]) -> String {
        (try? Shell.capture("/usr/bin/git", args, cwd: URL(fileURLWithPath: dir)))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func isRepo(_ dir: String) -> Bool { git(dir, ["rev-parse", "--is-inside-work-tree"]) == "true" }
    static func isDirty(_ dir: String) -> Bool { !git(dir, ["status", "--porcelain"] + pathspec(dir)).isEmpty }

    // ── 한 레포에 앱이 여럿일 때 ─────────────────────────────────────────
    // 맥 앱 레포 안의 하위 폴더에 따로 배포하는 아이폰 앱(예: StickyPresenter/StickyPresenterRemote)이 있으면
    // 두 앱이 git 을 같이 쓴다. 그대로 두면 리모컨만 고쳐도 맥 앱이 '올릴 변경 있음' 이 되고,
    // 리모컨의 배포 태그를 맥 앱이 '직전 배포' 로 잡고, 리모컨 릴리즈노트에 맥 앱 커밋이 섞인다.
    // 그래서 git 명령에 **이 앱 폴더의 몫만** 보게 하는 경로 제한을 붙인다. 앱이 하나뿐인 레포는 그대로다.

    /// 이 앱의 몫만 보는 경로 제한 (`-- . :(exclude)하위앱`). 앱이 하나뿐인 레포면 빈 배열.
    static func pathspec(_ dir: String) -> [String] {
        guard let top = toplevel(dir) else { return [] }
        if !samePath(dir, top) {
            // 하위 폴더 앱 — 자기 폴더 + deploy.env 의 GIT_PATHS (바깥과 같이 쓰는 소스, 예: ../Shared)
            let extra = (Config.loadEnv(URL(fileURLWithPath: dir).appendingPathComponent("deploy.env"))["GIT_PATHS"] ?? "")
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return ["--", "."] + extra
        }
        let nested = AppRepo.nestedAppDirs(top)
        return nested.isEmpty ? [] : ["--", "."] + nested.map { ":(exclude)\($0)" }  // 바깥 앱 — 하위 앱 폴더는 빼고
    }

    /// 레포를 다른 앱과 같이 쓰는가
    static func sharesRepo(_ dir: String) -> Bool { !pathspec(dir).isEmpty }

    private static func toplevel(_ dir: String) -> String? {
        let t = git(dir, ["rev-parse", "--show-toplevel"])
        return t.isEmpty ? nil : t
    }
    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    /// 같이 쓰는 레포에서 이 앱의 태그만 고른다. 배포 태그는 `deploy-<SCHEME>-…` 라 scheme 으로 가른다.
    /// 옛 `v1.2.3` 같은 태그는 누구 것인지 모르니 바깥 앱(레포 주인)의 것으로 본다.
    private static func ownsTag(_ dir: String, _ tag: String) -> Bool {
        guard sharesRepo(dir) else { return true }
        let scheme = Config.loadEnv(URL(fileURLWithPath: dir).appendingPathComponent("deploy.env"))["SCHEME"] ?? ""
        if tag.hasPrefix("deploy-") { return !scheme.isEmpty && tag.hasPrefix("deploy-\(scheme)-") }
        guard let top = toplevel(dir) else { return true }
        return samePath(dir, top)
    }

    /// 커밋 안 된 파일 경로들
    ///
    /// ⚠️ git() 을 쓰면 안 된다. porcelain 한 줄은 "XY 경로" 인데 미스테이징 변경은
    ///    X 가 공백이라 " M deploy.env" 로 시작한다. git() 이 출력 전체를 trim 하면
    ///    첫 줄의 그 선행 공백이 사라지고, dropFirst(3) 이 파일명 첫 글자를 먹는다
    ///    ("deploy.env" → "eploy.env"). 그러면 배포를 막는 이유로 있지도 않은
    ///    파일 이름을 보여 주게 된다. 줄 끝 개행만 걷어내고 앞은 그대로 둔다.
    static func dirtyFiles(_ dir: String) -> [String] {
        let raw = (try? Shell.capture("/usr/bin/git", ["status", "--porcelain"] + pathspec(dir),
                                      cwd: URL(fileURLWithPath: dir))) ?? ""
        // porcelain 경로는 하위 폴더에서 불러도 **레포 최상단 기준**이다. 하위 폴더 앱은 그 접두사를 떼어
        // 앱 폴더 기준으로 돌려준다 — 배포가 번호 파일을 커밋할 때 앱 폴더 기준 경로와 맞춰 보기 때문이다.
        let prefix = git(dir, ["rev-parse", "--show-prefix"])
        return raw.split(separator: "\n").compactMap { line -> String? in
            guard line.count > 3 else { return nil }
            var path = String(line.dropFirst(3))
            // 이름이 바뀐 파일은 "옛 이름 -> 새 이름" 으로 온다 — 지금 있는 쪽을 쓴다
            if let r = path.range(of: " -> ") { path = String(path[r.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"\r"))
            if !prefix.isEmpty, path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
            return path.isEmpty ? nil : path
        }
    }

    /// Xcode·macOS 가 알아서 건드리는 파일 — 사람이 한 변경이 아니다.
    /// 이것만 남아 배포가 막히는 앱이 대부분이라, 실제 변경과 구분해서 보여 준다.
    static let noisePatterns = [
        "xcuserdata/", "UserInterfaceState.xcuserstate", "xcschememanagement.plist",
        ".DS_Store", "xcshareddata/swiftpm/Package.resolved", "xcshareddata/IDEWorkspaceChecks.plist",
    ]
    static func isNoise(_ path: String) -> Bool { noisePatterns.contains { path.contains($0) } }

    /// .gitignore 에 넣을 표준 항목 (이미 있는 줄은 안 넣는다)
    static let ignoreLines = [
        ".DS_Store",
        "*.xcuserdatad/",
        "xcuserdata/",
        "**/xcshareddata/IDEWorkspaceChecks.plist",
    ]
    static func branch(_ dir: String) -> String { git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) }
    /// 이 브랜치가 따라가는 원격 브랜치 (없으면 nil — 로컬 전용 저장소)
    static func upstream(_ dir: String) -> String? {
        let u = git(dir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        return (u.isEmpty || u.contains("fatal")) ? nil : u
    }
    /// 원격 대비 앞선/뒤처진 커밋 수. upstream 이 없으면 nil.
    /// 둘 다 0보다 크면 갈라진 것 — 이 상태로 배포하면 git pull 단계에서 반드시 실패한다.
    static func aheadBehind(_ dir: String) -> (ahead: Int, behind: Int)? {
        guard upstream(dir) != nil else { return nil }
        let out = git(dir, ["rev-list", "--left-right", "--count", "@{u}...HEAD"])
        let parts = out.split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return (ahead: parts[1], behind: parts[0])
    }

    // ── 원격 다녀오기 ──────────────────────────────────────────────────
    // 자격증명을 물어보는 순간 새로고침 전체가 멈춘다. 프롬프트는 모두 끄고,
    // 키체인에 이미 저장된 자격증명(credential helper)만 쓰게 둔다.
    private static let networkEnv = [
        "GIT_TERMINAL_PROMPT": "0",
        "GIT_ASKPASS": "/usr/bin/true",
        "SSH_ASKPASS": "/usr/bin/true",
        "GIT_SSH_COMMAND": "ssh -oBatchMode=yes",
    ]

    /// 원격 상태를 받아 온다(작업 파일은 건드리지 않음). 성공하면 nil, 실패하면 사람이 읽을 이유.
    ///
    /// 이걸 안 하면 `@{u}` 는 마지막 fetch 시점에 멈춰 있어서, 원격에 커밋이 쌓여도
    /// "원격과 동기화됨" 이라고 말하게 된다.
    static func fetch(_ dir: String, timeout: TimeInterval = 20) -> String? {
        let o = Shell.outcome("/usr/bin/git", ["fetch", "--quiet"],
                              cwd: URL(fileURLWithPath: dir), env: networkEnv, timeout: timeout)
        return o.ok ? nil : o.reason
    }

    /// 앞당기기만 하는 pull. 병합 커밋도 충돌도 만들지 않아, 안 되면 그냥 실패한다.
    /// (배포 파이프라인도 첫 단계에서 이걸 쓴다 — 같은 기준이어야 결과가 어긋나지 않는다)
    static func pullFFOnly(_ dir: String, timeout: TimeInterval = 60) -> String? {
        let o = Shell.outcome("/usr/bin/git", ["pull", "--ff-only"],
                              cwd: URL(fileURLWithPath: dir), env: networkEnv, timeout: timeout)
        return o.ok ? nil : o.reason
    }

    static func lastDeployTag(_ dir: String) -> String? {
        guard sharesRepo(dir) else {
            let t = git(dir, ["describe", "--tags", "--match", "deploy-*", "--abbrev=0"])
            return t.isEmpty ? nil : t
        }
        // 같이 쓰는 레포: describe 는 '가장 가까운 아무 deploy 태그' 를 주므로 이 앱의 태그만 따로 고른다
        let scheme = Config.loadEnv(URL(fileURLWithPath: dir).appendingPathComponent("deploy.env"))["SCHEME"] ?? ""
        guard !scheme.isEmpty else { return nil }
        let t = git(dir, ["describe", "--tags", "--match", "deploy-\(scheme)-*", "--abbrev=0"])
        return t.isEmpty ? nil : t
    }

    // 특정 버전(예: "4.3.9")에 해당하는 태그 찾기 (v4.3.9 / 4.3.9 / deploy-*-4.3.9-*)
    static func tagForVersion(_ dir: String, _ version: String) -> String? {
        for pat in ["v\(version)", version, "*-\(version)-*", "*\(version)"] {
            let out = git(dir, ["tag", "--list", pat, "--sort=-creatordate"])
            if let first = out.split(separator: "\n").map(String.init).first(where: { ownsTag(dir, $0) }) { return first }
        }
        return nil
    }

    // 가장 최근 '릴리즈' 태그 (특정 버전 문자열이 든 태그는 제외 — 방금 만든 현재 버전 태그 회피용).
    //
    // 아무 태그나 쓰면 안 된다: archive/… 처럼 작업 보관용 태그가 최근이면
    // 그걸 직전 릴리즈로 잡아 릴리즈노트가 수십 개 커밋을 긁어 온다.
    // 릴리즈처럼 생긴 태그(v1.2.3 · 1.2.3 · deploy-…)만 후보로 본다.
    static func mostRecentTag(_ dir: String, excludingVersion: String?) -> String? {
        let all = git(dir, ["tag", "--sort=-creatordate"]).split(separator: "\n").map(String.init)
        func isRelease(_ t: String) -> Bool {
            if t.hasPrefix("deploy-") { return true }
            return t.range(of: #"^v?\d+\.\d+(\.\d+)?$"#, options: .regularExpression) != nil
        }
        let usable = all.filter { t in
            if !ownsTag(dir, t) { return false }
            if let ex = excludingVersion, !ex.isEmpty, t.contains(ex) { return false }
            return true
        }
        return usable.first(where: isRelease) ?? usable.first
    }
    static func commitsSince(_ dir: String, tag: String?, shippingOnly: Bool = false) -> [String] {
        let raw: String
        // 같이 쓰는 레포면 이 앱 폴더를 건드린 커밋만
        var spec = pathspec(dir)
        if shippingOnly { spec = (spec.isEmpty ? ["--", "."] : spec) + notShipped.map { ":(exclude)\($0)" } }
        if let tag { raw = git(dir, ["log", "\(tag)..HEAD", "--pretty=%s"] + spec) }
        else { raw = git(dir, ["log", "-n", "50", "--pretty=%s"] + spec) }
        return raw.split(separator: "\n").filter { !$0.isEmpty }.map(String.init)
    }

    /// 앱 바이너리에 들어가지 않는 파일. 이것만 바꾼 커밋은 '올릴 변경' 이 아니다 —
    /// 스토어 문구·릴리즈노트·스크린샷을 고친 커밋 하나로 출시된 앱이 '배포 가능' 이 되면 안 된다.
    /// (문구·그림은 배포 없이 [스토어 올리기] 로 올라간다)
    static let notShipped = [
        "*.md", "docs", "Docs", "AppStore", "Screenshots", "screenshots", "fastlane", "scripts",
        "deploy.env", ".gitignore", ".github", ".sprintcommander", "todo.md",
    ]
    @discardableResult
    static func tag(_ dir: String, name: String, message: String) -> Bool {
        !git(dir, ["tag", "-a", name, "-m", message]).contains("fatal")
            && ((try? Shell.capture("/usr/bin/git", ["rev-parse", name], cwd: URL(fileURLWithPath: dir))) ?? "").isEmpty == false
    }
}
