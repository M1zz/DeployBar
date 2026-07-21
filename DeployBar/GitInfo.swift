import Foundation

enum GitInfo {
    private static func git(_ dir: String, _ args: [String]) -> String {
        (try? Shell.capture("/usr/bin/git", args, cwd: URL(fileURLWithPath: dir)))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    static func isRepo(_ dir: String) -> Bool { git(dir, ["rev-parse", "--is-inside-work-tree"]) == "true" }
    static func isDirty(_ dir: String) -> Bool { !git(dir, ["status", "--porcelain"]).isEmpty }
    static func branch(_ dir: String) -> String { git(dir, ["rev-parse", "--abbrev-ref", "HEAD"]) }
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

    // 가장 최근 태그 (특정 버전 문자열이 든 태그는 제외 — 방금 만든 현재 버전 태그 회피용)
    static func mostRecentTag(_ dir: String, excludingVersion: String?) -> String? {
        let all = git(dir, ["tag", "--sort=-creatordate"]).split(separator: "\n").map(String.init)
        for t in all {
            if let ex = excludingVersion, !ex.isEmpty, t.contains(ex) { continue }
            return t
        }
        return nil
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
