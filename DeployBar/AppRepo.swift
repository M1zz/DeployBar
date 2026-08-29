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

    // 관리 대상 앱들이 모여 있는 루트 — 이 아래에서 앱을 자동 발견한다.
    static let root = "/Users/hyunholee/Documents/workspace/Auto"
    // 자동 발견에서 제외할 폴더 (배포 도구 자신 등). Swift 패키지(xcodeproj 없음)는 자동으로 빠진다.
    static let excludedDirs: Set<String> = ["DeployBar"]

    // root 바로 아래 폴더 중 .xcodeproj/.xcworkspace 를 가진 것을 배포 대상 앱으로 발견한다.
    static func discover() -> [ManagedApp] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        var apps: [ManagedApp] = []
        for name in entries.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            if name.hasPrefix(".") || excludedDirs.contains(name) { continue }
            let dir = "\(root)/\(name)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
            let hasProject = files.contains { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
            if hasProject { apps.append(ManagedApp(name: name, path: dir)) }
        }
        return apps
    }

    // apps.json 에 저장된 목록 — 이 **배열 순서가 곧 배포 순서**다.
    static func savedApps() -> [ManagedApp] {
        guard let data = try? Data(contentsOf: Config.appsJSON),
              let wrap = try? JSONDecoder().decode([String: [ManagedApp]].self, from: data),
              let saved = wrap["apps"] else { return [] }
        return saved
    }

    static func registry() -> [ManagedApp] {
        let discovered = discover()
        let byPath = Dictionary(discovered.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var ordered: [ManagedApp] = []
        var seen = Set<String>()

        // 1) 저장된 순서를 먼저 그대로 따른다 — 사용자가 정한 배포 순서를 폴더 이름순이 덮어쓰지 않게.
        for a in savedApps() where !seen.contains(a.path) {
            if let d = byPath[a.path] {
                ordered.append(d); seen.insert(a.path)          // root 안: 폴더가 아직 있는 것만
            } else if !a.path.hasPrefix("\(root)/") {
                ordered.append(a); seen.insert(a.path)          // root 밖에 수동 등록한 앱은 유지
            }
        }
        // 2) 새로 생긴 폴더는 뒤에 붙인다 (기존 순서를 흔들지 않는다)
        for d in discovered where !seen.contains(d.path) {
            ordered.append(d); seen.insert(d.path)
        }

        // apps.json 에는 숨긴 앱까지 전부 유지 — 되돌릴 때 root 밖 수동 등록 앱도 복원되도록
        save(ordered)
        // 관리에서 잠시 빼둔 앱만 화면·배포 대상에서 제외
        let hidden = Set(hiddenApps().map { $0.path })
        return ordered.filter { !hidden.contains($0.path) }
    }

    /// 화면에 보이는 앱들의 새 순서를 저장한다. 숨긴 앱은 목록 끝에 그대로 남긴다.
    static func reorder(visible paths: [String]) {
        let all = savedApps()
        let byPath = Dictionary(all.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        var out = paths.compactMap { byPath[$0] }
        let placed = Set(paths)
        out.append(contentsOf: all.filter { !placed.contains($0.path) })
        save(out)
    }

    // ── 관리에서 잠시 빼두기(숨김) ──────────────────────────────
    static func hiddenApps() -> [ManagedApp] {
        guard let data = try? Data(contentsOf: Config.hiddenJSON),
              let wrap = try? JSONDecoder().decode([String: [ManagedApp]].self, from: data),
              let saved = wrap["hidden"] else { return [] }
        return saved
    }

    private static func saveHidden(_ apps: [ManagedApp]) {
        let wrap = ["hidden": apps]
        if let data = try? JSONEncoder.pretty.encode(wrap) {
            try? data.write(to: Config.hiddenJSON)
        }
    }

    // 앱을 관리 목록에서 뺀다 (폴더는 그대로 둔다)
    static func hide(_ app: ManagedApp) {
        var h = hiddenApps()
        guard !h.contains(where: { $0.path == app.path }) else { return }
        h.append(app)
        saveHidden(h)
    }

    // 다시 관리 대상으로 되돌린다
    static func unhide(_ path: String) {
        saveHidden(hiddenApps().filter { $0.path != path })
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
        // LOCALES=ko,en-US,ja  (쉼표/공백 구분). 비면 .xcstrings·ASC 에서 자동 판단한다.
        let locales = (pick("LOCALES") ?? "")
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ResolvedApp(
            name: app.name,
            path: app.path,
            projFlag: flag,
            projContainer: container,
            scheme: pick("SCHEME") ?? base,
            versionXcconfig: pick("VERSION_XCCONFIG"),
            predeploy: pick("PREDEPLOY_SCRIPT"),
            exists: exists,
            locales: locales,
            localizationGate: pick("LOCALIZATION_GATE") ?? "warn",
            platformOverride: pick("PLATFORM")
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
        // 플랫폼 판별.
        // ⚠️ SDKROOT 만 보면 안 된다: -destination 없이 -showBuildSettings 를 부르면
        //    iOS 앱이어도 SDKROOT 가 MacOSX SDK 로 잡히는 타겟이 있다(멀티플랫폼/Catalyst).
        //    그대로 믿으면 iOS 앱을 macOS 로 archive 하고 altool -t macos 로 올려 버린다.
        //    → SUPPORTED_PLATFORMS 에 iphoneos 가 있으면 iOS 로 본다. deploy.env 의 PLATFORM 이 최우선.
        let sdkroot = (bs["SDKROOT"] as? String ?? "").lowercased()
        let supported = (bs["SUPPORTED_PLATFORMS"] as? String ?? "").lowercased()
        var isMac = supported.isEmpty
            ? sdkroot.contains("macosx")
            : (supported.contains("macosx") && !supported.contains("iphoneos"))
        switch r.platformOverride?.lowercased() {
        case "macos", "mac", "osx": isMac = true
        case "ios", "iphoneos": isMac = false
        default: break
        }
        let info = BuildInfo(
            bundleId: bid,
            marketingVersion: bs["MARKETING_VERSION"] as? String ?? "?",
            buildNumber: bs["CURRENT_PROJECT_VERSION"] as? String ?? "?",
            team: bs["DEVELOPMENT_TEAM"] as? String,
            platform: isMac ? .macOS : .iOS
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
