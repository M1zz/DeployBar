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
