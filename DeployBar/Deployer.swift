import Foundation

// fastlane 없이 배포: 게이트 → 빌드번호+1 → archive → export → altool 업로드
enum Deployer {
    enum Lane: String { case check, beta, appstore }

    struct Result { let version: String; let build: Int }

    static func deploy(_ app: ManagedApp, lane: Lane, onLog: @escaping @Sendable (String) -> Void) async throws -> Result {
        let r = AppRepo.resolve(app)
        guard r.exists else { throw err("Xcode 프로젝트 없음: \(r.path)") }
        let info = try AppRepo.buildSettings(r, fresh: true)
        let cwd = URL(fileURLWithPath: r.path)
        let workDir = cwd.appendingPathComponent("build/deploy-console")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1) 게이트
        if let predeploy = r.predeploy {
            onLog("🛡  배포 전 게이트: \(predeploy)")
            try await Shell.run("/bin/sh", [predeploy], cwd: cwd, onLog: onLog)
        } else {
            onLog("⚠️  PREDEPLOY_SCRIPT 미설정 — 게이트 건너뜀")
        }
        if lane == .check {
            onLog("✅ 게이트 통과 (check 모드 — 배포 없음)")
            return Result(version: info.marketingVersion, build: Int(info.buildNumber) ?? 0)
        }

        // 2) 빌드번호 +1
        let newBuild = try bump(r, onLog: onLog)

        // 3) archive
        let archivePath = workDir.appendingPathComponent("\(r.scheme).xcarchive").path
        try await Shell.run("/usr/bin/xcodebuild", [
            "archive", r.projFlag, r.projContainer,
            "-scheme", r.scheme, "-configuration", "Release",
            "-destination", "generic/platform=iOS",
            "-archivePath", archivePath,
            "-allowProvisioningUpdates", "-quiet",
        ], cwd: cwd, onLog: onLog)

        // 4) export IPA
        let exportDir = workDir.appendingPathComponent("export")
        try? FileManager.default.removeItem(at: exportDir)
        let plist = try writeExportOptions(workDir, team: info.team)
        try await Shell.run("/usr/bin/xcodebuild", [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportPath", exportDir.path,
            "-exportOptionsPlist", plist.path,
            "-allowProvisioningUpdates",
        ], cwd: cwd, onLog: onLog)

        // 5) altool 업로드
        let ipas = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        guard let ipa = ipas.first(where: { $0.hasSuffix(".ipa") }) else { throw err("export 결과에서 .ipa 를 찾지 못함") }
        let ipaPath = exportDir.appendingPathComponent(ipa).path
        onLog("📦 IPA: \(ipaPath)")
        let asc = Config.asc
        try await Shell.run("/usr/bin/xcrun", [
            "altool", "--upload-app", "-f", ipaPath, "-t", "ios",
            "--apiKey", asc.keyId, "--apiIssuer", asc.issuer,
        ], cwd: cwd, onLog: onLog)

        onLog("🚀 [\(r.scheme)] 업로드 완료 — v\(info.marketingVersion) (build \(newBuild))")
        if GitInfo.isRepo(r.path) {
            let tag = "deploy-\(r.scheme)-\(info.marketingVersion)-\(newBuild)"
            if GitInfo.tag(r.path, name: tag, message: "deploy-bar: \(info.marketingVersion) (\(newBuild))") {
                onLog("🏷  태그: \(tag)")
            }
        }
        return Result(version: info.marketingVersion, build: newBuild)
    }

    // 빌드번호 +1 (VERSION_XCCONFIG 우선, 없으면 agvtool)
    private static func bump(_ r: ResolvedApp, onLog: @escaping @Sendable (String) -> Void) throws -> Int {
        if let xc = r.versionXcconfig {
            let file = URL(fileURLWithPath: r.path).appendingPathComponent(xc)
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { throw err("VERSION_XCCONFIG 없음: \(file.path)") }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var current = 0, found = false
            let updated = lines.map { line -> String in
                if let range = line.range(of: #"^CURRENT_PROJECT_VERSION\s*=\s*(\d+)"#, options: .regularExpression) {
                    let digits = line[range].components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                    current = Int(digits) ?? 0
                    found = true
                    return "CURRENT_PROJECT_VERSION = \(current + 1)"
                }
                return line
            }
            guard found else { throw err("\(xc) 에서 CURRENT_PROJECT_VERSION 을 찾지 못함") }
            try updated.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            onLog("🔢 빌드번호: \(current) → \(current + 1) (\(xc))")
            return current + 1
        } else {
            onLog("🔢 빌드번호 +1 (agvtool)")
            return 0
        }
    }

    private static func writeExportOptions(_ dir: URL, team: String?) throws -> URL {
        let teamLine = team.map { "\n  <key>teamID</key><string>\($0)</string>" } ?? ""
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>method</key><string>app-store-connect</string>
          <key>destination</key><string>export</string>
          <key>signingStyle</key><string>automatic</string>\(teamLine)
          <key>uploadSymbols</key><true/>
          <key>stripSwiftSymbols</key><true/>
          <key>manageAppVersionAndBuildNumber</key><false/>
        </dict></plist>
        """
        let url = dir.appendingPathComponent("ExportOptions.plist")
        try plist.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "DeployBar", code: 10, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
