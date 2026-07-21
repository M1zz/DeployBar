import Foundation

// 앱 설정: ASC 자격증명은 fastlane-shared/asc.env 를 재사용, 앱 목록·AI키는 Application Support 에.
enum Config {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    static var supportDir: URL {
        let dir = home
            .appendingPathComponent("Library/Application Support/DeployBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var appsJSON: URL { supportDir.appendingPathComponent("apps.json") }
    static var configEnv: URL { supportDir.appendingPathComponent("config.env") }

    static func loadEnv(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") || line.isEmpty { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            out[k] = v
        }
        return out
    }

    // fastlane-shared 위치 (config.env 로 재정의 가능)
    static var sharedDir: URL {
        let local = loadEnv(configEnv)
        if let p = local["FASTLANE_SHARED_DIR"] { return URL(fileURLWithPath: p) }
        return home.appendingPathComponent("Documents/workspace/fastlane-shared")
    }

    struct ASC { let keyId: String; let issuer: String; let keyPath: URL }

    static var asc: ASC {
        let local = loadEnv(configEnv)
        let shared = loadEnv(sharedDir.appendingPathComponent("asc.env"))
        let keyId = local["ASC_KEY_ID"] ?? shared["ASC_KEY_ID"] ?? ""
        let issuer = local["ASC_ISSUER_ID"] ?? shared["ASC_ISSUER_ID"] ?? ""
        // .p8 탐색: altool 표준 경로 우선
        let named = "AuthKey_\(keyId).p8"
        let candidates = [
            home.appendingPathComponent(".appstoreconnect/private_keys/\(named)"),
            home.appendingPathComponent(".private_keys/\(named)"),
            home.appendingPathComponent("private_keys/\(named)"),
        ]
        var keyPath = candidates[0]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) { keyPath = c; break }
        if let raw = shared["ASC_KEY_PATH"], !FileManager.default.fileExists(atPath: keyPath.path) {
            keyPath = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        return ASC(keyId: keyId, issuer: issuer, keyPath: keyPath)
    }

    static var anthropicKey: String? {
        let local = loadEnv(configEnv)
        return local["ANTHROPIC_API_KEY"] ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
    }
    static var anthropicModel: String {
        loadEnv(configEnv)["ANTHROPIC_MODEL"] ?? "claude-opus-4-8"
    }
}
