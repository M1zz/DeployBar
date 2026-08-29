import Foundation

// fastlane 없이 배포: 게이트 → 빌드번호+1 → archive → export → altool 업로드
enum Deployer {
    enum Lane: String { case check, beta, appstore }

    struct Result { let version: String; let build: Int }

    // versionBump: nil = 빌드만 올리기(버전 유지), .patch/.minor/.major = 그만큼 버전 올린 뒤 배포(빌드 1부터)
    static func deploy(_ app: ManagedApp, lane: Lane, versionBump: VersionBump? = nil, onLog: @escaping @Sendable (String) -> Void) async throws -> Result {
        let r = AppRepo.resolve(app)
        guard r.exists else { throw err("Xcode 프로젝트 없음: \(r.path)") }
        let info = try AppRepo.buildSettings(r, fresh: true)
        var marketingVersion = info.marketingVersion
        let cwd = URL(fileURLWithPath: r.path)
        let workDir = cwd.appendingPathComponent("build/deploy-console")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 0) 최신 코드 반영: 배포 전 git pull (원격의 최신 커밋을 먼저 가져온다)
        if GitInfo.isRepo(r.path) {
            onLog("⬇️  git pull …")
            do {
                try await Shell.run("/usr/bin/git", ["pull", "--ff-only"], cwd: cwd, onLog: onLog)
            } catch {
                throw err("git pull 실패 — 원격과 동기화 후 다시 배포하세요. (\(error.localizedDescription))")
            }
        }

        // 1) 게이트 — 먼저 다국어(내장), 그다음 앱별 스크립트
        //    번역 구멍은 빌드가 아니라 사용자가 보는 화면의 문제라 xcodebuild 로는 절대 안 잡힌다.
        let gateMode = Localization.Mode(r.localizationGate)
        if gateMode == .off {
            onLog("🌐 다국어 검사: LOCALIZATION_GATE=off — 건너뜀")
        } else {
            let report = Localization.scan(r.path, expected: r.locales)
            for line in Localization.summaryLines(report, mode: gateMode) { onLog(line) }
            if gateMode == .strict && !report.ok {
                throw err("다국어 검사 실패 — 번역 문제 \(report.issues.count)건. 번역을 채운 뒤 다시 배포하세요.")
            }
        }

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

        // 1.5) 버전 처리 — 배포 전에 결정한다. 올릴지(버전), 유지할지(빌드만) 여기서 갈린다.
        if let bump = versionBump {
            let next = bumpVersion(marketingVersion, bump)
            onLog("⬆️  버전 올리기: \(marketingVersion) → \(next)")
            setMarketingVersion(r, to: next, onLog: onLog)
            marketingVersion = next
            AppRepo.clearCache()   // 이후 상태 조회가 새 버전을 읽도록
        } else {
            onLog("🔁 빌드만 올리기 — 버전 유지 (v\(marketingVersion))")
        }

        // 2) 빌드번호 설정 — 같은 마케팅 버전 안에서만 증가시키고, 새 버전이면 1부터 다시 시작한다.
        //    (App Store 는 빌드번호를 마케팅 버전별로만 고유하면 되므로 버전이 바뀌면 1 로 리셋 가능)
        onLog("🔎 App Store 최신 빌드 확인 중… (v\(marketingVersion))")
        var ascBuild = 0
        if let id = try? await ASCClient.appId(bundleId: info.bundleId),
           let n = try? await ASCClient.latestBuild(appId: id, marketingVersion: marketingVersion) {
            ascBuild = n ?? 0
        }
        let newBuild = ascBuild + 1
        onLog(ascBuild == 0
            ? "🔢 빌드번호: v\(marketingVersion) 첫 빌드 → \(newBuild)"
            : "🔢 빌드번호: v\(marketingVersion) · ASC \(ascBuild) → \(newBuild)")
        try await setBuild(r, to: newBuild, onLog: onLog)

        // 3) archive — 플랫폼(iOS/macOS)에 맞는 destination 사용
        onLog("🖥  플랫폼: \(info.platform.rawValue) (destination \(info.platform.destination))")
        let archivePath = workDir.appendingPathComponent("\(r.scheme).xcarchive").path
        try await Shell.run("/usr/bin/xcodebuild", [
            "archive", r.projFlag, r.projContainer,
            "-scheme", r.scheme, "-configuration", "Release",
            "-destination", info.platform.destination,
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

        // 5) altool 업로드 — 산출물(iOS: .ipa / macOS: .pkg)과 -t 타입을 플랫폼에 맞춘다
        let ext = info.platform.exportExt
        let artifacts = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        guard let file = artifacts.first(where: { $0.hasSuffix(".\(ext)") }) else {
            throw err("export 결과에서 .\(ext) 를 찾지 못함")
        }
        let uploadPath = exportDir.appendingPathComponent(file).path
        onLog("📦 \(ext.uppercased()): \(uploadPath)")
        let asc = Config.asc
        let uploadOutput = try await Shell.run("/usr/bin/xcrun", [
            "altool", "--upload-app", "-f", uploadPath, "-t", info.platform.altoolType,
            "--apiKey", asc.keyId, "--apiIssuer", asc.issuer,
        ], cwd: cwd, onLog: onLog)
        // altool 은 업로드 실패에도 종료코드 0 을 반환할 수 있으므로 출력으로 실패를 판정한다
        let lower = uploadOutput.lowercased()
        if lower.contains("failed to upload") || lower.contains("error:") || lower.contains("\"errors\"") {
            throw err("업로드 실패 — App Store Connect 가 거부했습니다. 위 로그를 확인하세요.")
        }

        onLog("🚀 [\(r.scheme)] 업로드 완료 — v\(marketingVersion) (build \(newBuild))")
        if GitInfo.isRepo(r.path) {
            let tag = "deploy-\(r.scheme)-\(marketingVersion)-\(newBuild)"
            if GitInfo.tag(r.path, name: tag, message: "deploy-bar: \(marketingVersion) (\(newBuild))") {
                onLog("🏷  태그: \(tag)")
            }
        }
        // 버전은 사용자가 '버전 올리기'를 고를 때만 바뀐다 — 배포 후 자동 증가 없음
        return Result(version: marketingVersion, build: newBuild)
    }

    // 빌드번호를 지정한 값으로 설정 (VERSION_XCCONFIG 우선, 없으면 agvtool)
    private static func setBuild(_ r: ResolvedApp, to target: Int, onLog: @escaping @Sendable (String) -> Void) async throws {
        if let xc = r.versionXcconfig {
            let file = URL(fileURLWithPath: r.path).appendingPathComponent(xc)
            guard let content = try? String(contentsOf: file, encoding: .utf8) else { throw err("VERSION_XCCONFIG 없음: \(file.path)") }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var found = false
            let updated = lines.map { line -> String in
                if line.range(of: #"^\s*CURRENT_PROJECT_VERSION\s*="#, options: .regularExpression) != nil {
                    found = true
                    return "CURRENT_PROJECT_VERSION = \(target)"
                }
                return line
            }
            guard found else { throw err("\(xc) 에서 CURRENT_PROJECT_VERSION 을 찾지 못함") }
            try updated.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            onLog("🔢 \(xc): CURRENT_PROJECT_VERSION = \(target)")
        } else if r.projFlag == "-project" {
            // xcconfig 가 없는 앱: project.pbxproj 의 CURRENT_PROJECT_VERSION 을 직접 설정
            // (agvtool 은 VERSIONING_SYSTEM=apple-generic 이 아니면 동작하지 않음)
            let pbxproj = URL(fileURLWithPath: r.projContainer).appendingPathComponent("project.pbxproj")
            guard let content = try? String(contentsOf: pbxproj, encoding: .utf8) else {
                throw err("project.pbxproj 를 읽지 못함: \(r.projContainer)")
            }
            guard content.range(of: #"CURRENT_PROJECT_VERSION = [^;]+;"#, options: .regularExpression) != nil else {
                throw err("project.pbxproj 에서 CURRENT_PROJECT_VERSION 을 찾지 못함. VERSION_XCCONFIG 설정을 권장합니다.")
            }
            let updated = content.replacingOccurrences(
                of: #"CURRENT_PROJECT_VERSION = [^;]+;"#,
                with: "CURRENT_PROJECT_VERSION = \(target);",
                options: .regularExpression)
            try updated.write(to: pbxproj, atomically: true, encoding: .utf8)
            onLog("🔢 project.pbxproj: CURRENT_PROJECT_VERSION = \(target)")
        } else {
            try await Shell.run("/usr/bin/xcrun", ["agvtool", "new-version", "-all", "\(target)"],
                                cwd: URL(fileURLWithPath: r.path), onLog: onLog)
        }
    }

    enum VersionBump { case patch, minor, major }

    // "4.4.0" → patch:4.4.1 / minor:4.5.0 / major:5.0.0
    static func bumpVersion(_ v: String, _ kind: VersionBump) -> String {
        var p = v.split(separator: ".").map { Int($0) ?? 0 }
        while p.count < 3 { p.append(0) }
        switch kind {
        case .patch: p[2] += 1
        case .minor: p[1] += 1; p[2] = 0
        case .major: p[0] += 1; p[1] = 0; p[2] = 0
        }
        return "\(p[0]).\(p[1]).\(p[2])"
    }

    static func nextPatchVersion(_ v: String) -> String { bumpVersion(v, .patch) }

    // 수동 버전 설정 진입점 (UI 에서 호출)
    @discardableResult
    static func applyMarketingVersion(_ app: ManagedApp, to version: String) -> String {
        let r = AppRepo.resolve(app)
        var msg = ""
        setMarketingVersion(r, to: version) { msg = $0 }
        return msg
    }

    // MARKETING_VERSION 을 지정 값으로 설정 (xcconfig 에 있으면 거기, 없으면 pbxproj)
    private static func setMarketingVersion(_ r: ResolvedApp, to version: String, onLog: @escaping @Sendable (String) -> Void) {
        // 1) VERSION_XCCONFIG 에 MARKETING_VERSION 이 있으면 거기서
        if let xc = r.versionXcconfig {
            let file = URL(fileURLWithPath: r.path).appendingPathComponent(xc)
            if let content = try? String(contentsOf: file, encoding: .utf8) {
                let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                var found = false
                let updated = lines.map { line -> String in
                    if line.range(of: #"^\s*MARKETING_VERSION\s*="#, options: .regularExpression) != nil {
                        found = true
                        return "MARKETING_VERSION = \(version)"
                    }
                    return line
                }
                if found {
                    try? updated.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
                    onLog("📈 \(xc): MARKETING_VERSION = \(version)")
                    return
                }
            }
        }
        // 2) project.pbxproj
        if r.projFlag == "-project" {
            let pbxproj = URL(fileURLWithPath: r.projContainer).appendingPathComponent("project.pbxproj")
            if let content = try? String(contentsOf: pbxproj, encoding: .utf8),
               content.range(of: #"MARKETING_VERSION = [^;]+;"#, options: .regularExpression) != nil {
                let updated = content.replacingOccurrences(
                    of: #"MARKETING_VERSION = [^;]+;"#,
                    with: "MARKETING_VERSION = \(version);",
                    options: .regularExpression)
                try? updated.write(to: pbxproj, atomically: true, encoding: .utf8)
                onLog("📈 project.pbxproj: MARKETING_VERSION = \(version)")
                return
            }
        }
        onLog("⚠️ MARKETING_VERSION 을 찾지 못해 버전 자동 증가를 건너뜀")
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
