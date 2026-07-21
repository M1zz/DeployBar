import Foundation

// 관리 대상 앱 레지스트리 + 프로젝트 설정 자동 해석
final class BuildCache: @unchecked Sendable {
    private var map: [String: BuildInfo] = [:]
    private let lock = NSLock()
    func get(_ k: String) -> BuildInfo? { lock.lock(); defer { lock.unlock() }; return map[k] }
    func set(_ k: String, _ v: BuildInfo) { lock.lock(); defer { lock.unlock() }; map[k] = v }
    func clear() { lock.lock(); defer { lock.unlock() }; map.removeAll() }
}

enum AppRepo {
    static let cache = BuildCache()

    static let seed: [ManagedApp] = [
        .init(name: "클립키보드", path: "/Users/hyunholee/Documents/workspace/Auto/클립키보드"),
        .init(name: "두번알림", path: "/Users/hyunholee/Documents/workspace/Auto/두번알림"),
        .init(name: "장표스냅", path: "/Users/hyunholee/Documents/workspace/Auto/장표스냅"),
        .init(name: "달빛", path: "/Users/hyunholee/Documents/workspace/Auto/달빛"),
    ]

    static func registry() -> [ManagedApp] {
        if let data = try? Data(contentsOf: Config.appsJSON),
           let wrap = try? JSONDecoder().decode([String: [ManagedApp]].self, from: data),
           let apps = wrap["apps"] {
            return apps
        }
        save(seed)
        return seed
    }

    static func save(_ apps: [ManagedApp]) {
        let wrap = ["apps": apps]
        if let data = try? JSONEncoder.pretty.encode(wrap) {
            try? data.write(to: Config.appsJSON)
        }
    }

    static func resolve(_ app: ManagedApp) -> ResolvedApp {
        let dir = URL(fileURLWithPath: app.path)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: app.path)) ?? []
        var flag = "-project", container = "", base = app.name, exists = false
        if let ws = files.first(where: { $0.hasSuffix(".xcworkspace") }) {
            flag = "-workspace"; container = dir.appendingPathComponent(ws).path
            base = (ws as NSString).deletingPathExtension; exists = true
        } else if let pj = files.first(where: { $0.hasSuffix(".xcodeproj") }) {
            flag = "-project"; container = dir.appendingPathComponent(pj).path
            base = (pj as NSString).deletingPathExtension; exists = true
        }
        let envA = Config.loadEnv(dir.appendingPathComponent("deploy.env"))
        let envB = Config.loadEnv(dir.appendingPathComponent("fastlane/.env"))
        func pick(_ k: String) -> String? { envA[k] ?? envB[k] }
        return ResolvedApp(
            name: app.name,
            path: app.path,
            projFlag: flag,
            projContainer: container,
            scheme: pick("SCHEME") ?? base,
            versionXcconfig: pick("VERSION_XCCONFIG"),
            predeploy: pick("PREDEPLOY_SCRIPT"),
            exists: exists
        )
    }

    // xcodebuild -showBuildSettings 로 bundleId·버전·팀 획득 (느림 → 캐시)
    static func buildSettings(_ r: ResolvedApp, fresh: Bool = false) throws -> BuildInfo {
        if !fresh, let hit = cache.get(r.path) { return hit }
        guard r.exists else { throw NSError(domain: "DeployBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Xcode 프로젝트 없음: \(r.path)"]) }
        let out = try Shell.capture("/usr/bin/xcodebuild", [
            "-showBuildSettings", "-json",
            r.projFlag, r.projContainer,
            "-scheme", r.scheme, "-configuration", "Release",
        ], cwd: URL(fileURLWithPath: r.path))
        guard let arr = try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] else {
            throw NSError(domain: "DeployBar", code: 2, userInfo: [NSLocalizedDescriptionKey: "빌드 설정 파싱 실패: \(r.name)"])
        }
        var best: [String: Any]?
        for t in arr {
            guard let bs = t["buildSettings"] as? [String: Any],
                  let bid = bs["PRODUCT_BUNDLE_IDENTIFIER"] as? String else { continue }
            let bestBid = (best?["PRODUCT_BUNDLE_IDENTIFIER"] as? String) ?? ""
            if best == nil || bid.count < bestBid.count { best = bs }
        }
        guard let bs = best,
              let bid = bs["PRODUCT_BUNDLE_IDENTIFIER"] as? String else {
            throw NSError(domain: "DeployBar", code: 3, userInfo: [NSLocalizedDescriptionKey: "앱 타겟을 찾지 못함: \(r.name)"])
        }
        let info = BuildInfo(
            bundleId: bid,
            marketingVersion: bs["MARKETING_VERSION"] as? String ?? "?",
            buildNumber: bs["CURRENT_PROJECT_VERSION"] as? String ?? "?",
            team: bs["DEVELOPMENT_TEAM"] as? String
        )
        cache.set(r.path, info)
        return info
    }

    static func clearCache() { cache.clear() }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }
}
