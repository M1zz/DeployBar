import Foundation

enum GitInfo {
    private static func git(_ dir: String, _ args: [String]) -> String {
        (try? Shell.capture("/usr/bin/git", args, cwd: URL(fileURLWithPath: dir)))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func isRepo(_ dir: String) -> Bool { git(dir, ["rev-parse", "--is-inside-work-tree"]) == "true" }
    static func isDirty(_ dir: String) -> Bool { !git(dir, ["status", "--porcelain"]).isEmpty }

    /// 커밋 안 된 파일 경로들
    static func dirtyFiles(_ dir: String) -> [String] {
        git(dir, ["status", "--porcelain"]).split(separator: "\n").map {
            String($0.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }.filter { !$0.isEmpty }
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

    static func lastDeployTag(_ dir: String) -> String? {
        let t = git(dir, ["describe", "--tags", "--match", "deploy-*", "--abbrev=0"])
        return t.isEmpty ? nil : t
    }

    // 특정 버전(예: "4.3.9")에 해당하는 태그 찾기 (v4.3.9 / 4.3.9 / deploy-*-4.3.9-*)
    static func tagForVersion(_ dir: String, _ version: String) -> String? {
        for pat in ["v\(version)", version, "*-\(version)-*", "*\(version)"] {
            let out = git(dir, ["tag", "--list", pat, "--sort=-creatordate"])
            if let first = out.split(separator: "\n").first, !first.isEmpty { return String(first) }
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
            if let ex = excludingVersion, !ex.isEmpty, t.contains(ex) { return false }
            return true
        }
        return usable.first(where: isRelease) ?? usable.first
    }
    static func commitsSince(_ dir: String, tag: String?) -> [String] {
        let raw: String
        if let tag { raw = git(dir, ["log", "\(tag)..HEAD", "--pretty=%s"]) }
        else { raw = git(dir, ["log", "-n", "50", "--pretty=%s"]) }
        return raw.split(separator: "\n").map(String.init)
    }
    @discardableResult
    static func tag(_ dir: String, name: String, message: String) -> Bool {
        !git(dir, ["tag", "-a", name, "-m", message]).contains("fatal")
            && ((try? Shell.capture("/usr/bin/git", ["rev-parse", name], cwd: URL(fileURLWithPath: dir))) ?? "").isEmpty == false
    }
}
