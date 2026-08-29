import Foundation

// 앱이 DeployBar 로 배포되려면 갖춰야 할 "규칙"을 점검하고, 없으면 템플릿으로 깔아 준다.
//
// 규칙은 다섯 가지뿐이다 (README 의 표와 같은 순서):
//   1. Xcode 프로젝트가 앱 폴더 최상단에 하나
//   2. deploy.env       — SCHEME / VERSION_XCCONFIG / PREDEPLOY_SCRIPT / LOCALES / LOCALIZATION_GATE
//   3. 버전 소스 한 곳  — Version.xcconfig 의 MARKETING_VERSION·CURRENT_PROJECT_VERSION
//   4. scripts/predeploy.sh — 배포 전 게이트 (테스트)
//   5. 다국어           — .xcstrings 에 LOCALES 의 모든 언어가 빠짐없이
enum Scaffold {

    enum Level: String { case ok = "✅", warn = "⚠️", fail = "❌" }

    struct Check {
        let level: Level
        let title: String
        let detail: String
        var line: String { "\(level.rawValue) \(title) — \(detail)" }
    }

    /// xcconfig 본문에 `KEY = ...` 줄이 있는지.
    /// ⚠️ `^` 는 기본적으로 **문자열 전체**의 시작에만 걸린다 — 줄 단위로 보려면 (?m) 이 반드시 필요하다.
    static func hasSetting(_ body: String, _ key: String) -> Bool {
        body.range(of: "(?m)^\\s*\(key)\\s*=", options: .regularExpression) != nil
    }

    // ── 점검 ────────────────────────────────────────────────────────────
    static func doctor(_ app: ManagedApp) -> [Check] {
        var out: [Check] = []
        let r = AppRepo.resolve(app)
        let dir = URL(fileURLWithPath: app.path)
        let fm = FileManager.default

        // 1. Xcode 프로젝트
        if r.exists {
            // 최상단에 프로젝트가 둘 이상이면 xcodebuild 가 어느 쪽인지 몰라 멈춘다.
            // (Xcode Cloud 호환용 심볼릭 링크를 같이 두는 앱이 실제로 있다.)
            let projects = ((try? fm.contentsOfDirectory(atPath: app.path)) ?? [])
                .filter { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
            if projects.count > 1 {
                out.append(Check(level: .warn, title: "Xcode 프로젝트",
                                 detail: "최상단에 \(projects.count)개(\(projects.joined(separator: ", "))) — DeployBar 는 \((r.projContainer as NSString).lastPathComponent) 를 씁니다"))
            } else {
                out.append(Check(level: .ok, title: "Xcode 프로젝트",
                                 detail: "\((r.projContainer as NSString).lastPathComponent) · scheme \(r.scheme)"))
            }
        } else {
            out.append(Check(level: .fail, title: "Xcode 프로젝트",
                             detail: "앱 폴더 최상단에 .xcodeproj/.xcworkspace 가 없습니다 — 배포 불가"))
            return out
        }

        // 2. deploy.env
        let envPath = dir.appendingPathComponent("deploy.env")
        let legacyPath = dir.appendingPathComponent("fastlane/.env")
        if fm.fileExists(atPath: envPath.path) {
            out.append(Check(level: .ok, title: "deploy.env", detail: "있음"))
        } else if fm.fileExists(atPath: legacyPath.path) {
            out.append(Check(level: .warn, title: "deploy.env",
                             detail: "fastlane/.env 를 대신 읽고 있습니다 — deploy.env 로 옮기는 것을 권장"))
        } else {
            out.append(Check(level: .warn, title: "deploy.env",
                             detail: "없음 — scheme 을 폴더 이름(\(r.scheme))으로 추정 중. [자동 설정]으로 만드세요"))
        }

        // 3. 버전 소스
        if let xc = r.versionXcconfig {
            let file = dir.appendingPathComponent(xc)
            let body = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            let hasMarketing = hasSetting(body, "MARKETING_VERSION")
            let hasBuild = hasSetting(body, "CURRENT_PROJECT_VERSION")
            if !fm.fileExists(atPath: file.path) {
                // 경로만 틀린 경우가 흔하다 (예: Config/Version.xcconfig) — 실제 위치를 찾아 알려 준다.
                let hint = findVersionXcconfig(app.path).map { " → \($0) 로 고치세요" } ?? ""
                out.append(Check(level: .fail, title: "버전 소스",
                                 detail: "VERSION_XCCONFIG=\(xc) 파일이 없습니다\(hint) · 이대로면 배포 중 빌드번호 설정에서 실패합니다"))
            } else if hasMarketing && hasBuild {
                out.append(Check(level: .ok, title: "버전 소스", detail: "\(xc) (MARKETING_VERSION + CURRENT_PROJECT_VERSION)"))
            } else {
                let missing = [hasMarketing ? nil : "MARKETING_VERSION", hasBuild ? nil : "CURRENT_PROJECT_VERSION"].compactMap { $0 }
                out.append(Check(level: .warn, title: "버전 소스",
                                 detail: "\(xc) 에 \(missing.joined(separator: ", ")) 없음 — project.pbxproj 로 대체됩니다"))
            }
        } else {
            let pbx = URL(fileURLWithPath: r.projContainer).appendingPathComponent("project.pbxproj")
            let body = (try? String(contentsOf: pbx, encoding: .utf8)) ?? ""
            let ok = body.contains("MARKETING_VERSION") && body.contains("CURRENT_PROJECT_VERSION")
            out.append(Check(level: ok ? .ok : .fail, title: "버전 소스",
                             detail: ok ? "project.pbxproj (동작함 · 타겟이 여러 개면 Version.xcconfig 로 옮기는 편이 안전)"
                                        : "project.pbxproj 에서 MARKETING_VERSION/CURRENT_PROJECT_VERSION 을 찾지 못함"))
        }

        // 3.5 플랫폼 — archive destination·altool -t·산출물 확장자가 여기서 갈린다
        if let info = try? AppRepo.buildSettings(r) {
            let src = r.platformOverride == nil ? "자동 판별" : "deploy.env PLATFORM"
            out.append(Check(level: .ok, title: "플랫폼",
                             detail: "\(info.platform.rawValue) (\(src)) · \(info.bundleId)"))
        } else {
            out.append(Check(level: .fail, title: "플랫폼",
                             detail: "xcodebuild -showBuildSettings 실패 — scheme(\(r.scheme))이 맞는지 확인하세요"))
        }

        // 4. 배포 전 게이트
        if let p = r.predeploy {
            let script = dir.appendingPathComponent(p)
            out.append(fm.fileExists(atPath: script.path)
                ? Check(level: .ok, title: "배포 전 게이트", detail: p)
                : Check(level: .fail, title: "배포 전 게이트", detail: "PREDEPLOY_SCRIPT=\(p) 파일이 없습니다"))
        } else {
            out.append(Check(level: .warn, title: "배포 전 게이트",
                             detail: "없음 — 테스트 없이 배포됩니다. [자동 설정]으로 scripts/predeploy.sh 를 만드세요"))
        }

        // 5. 다국어
        let report = Localization.scan(app.path, expected: r.locales)
        let mode = Localization.Mode(r.localizationGate)
        if !report.scanned {
            out.append(Check(level: .ok, title: "다국어", detail: ".xcstrings 없음 — 단일 언어 앱"))
        } else {
            let declared = r.locales
            if !declared.isEmpty {
                let extra = report.locales.filter { l in !declared.contains { Locales.sameLanguage($0, l) } }
                let missing = declared.filter { d in !report.locales.contains { Locales.sameLanguage($0, d) } }
                if !missing.isEmpty {
                    out.append(Check(level: .fail, title: "LOCALES 선언",
                                     detail: "deploy.env 에 \(missing.joined(separator: ", ")) 를 적었는데 .xcstrings 에는 없습니다"))
                } else if !extra.isEmpty {
                    out.append(Check(level: .warn, title: "LOCALES 선언",
                                     detail: ".xcstrings 에만 있는 언어: \(extra.joined(separator: ", ")) — LOCALES 에 추가하거나 Xcode 에서 제거하세요"))
                } else {
                    out.append(Check(level: .ok, title: "LOCALES 선언", detail: declared.joined(separator: ", ")))
                }
            } else {
                out.append(Check(level: .warn, title: "LOCALES 선언",
                                 detail: "없음 — .xcstrings 의 \(report.locales.joined(separator: ", ")) 를 그대로 기준으로 씁니다"))
            }
            if report.ok {
                out.append(Check(level: .ok, title: "번역 완성도",
                                 detail: "\(report.keyCount)개 문자열 · 구멍 없음 (게이트 \(mode.rawValue))"))
            } else {
                let head = report.byLocale.prefix(4).map { "\($0.locale) \($0.count)건" }.joined(separator: ", ")
                out.append(Check(level: mode == .strict ? .fail : .warn, title: "번역 완성도",
                                 detail: "구멍 \(report.issues.count)건 — \(head) (게이트 \(mode.rawValue))"))
            }
        }

        // 6. git — 더러운 작업트리는 규칙 위반이 아니라 그때그때의 상태라 ✅ 로 둔다(대시보드 뱃지가 알려 준다)
        if GitInfo.isRepo(app.path) {
            let dirty = GitInfo.isDirty(app.path)
            out.append(Check(level: .ok, title: "git",
                             detail: "\(GitInfo.branch(app.path))\(dirty ? " · 커밋되지 않은 변경 있음" : " · clean")"))
        } else {
            out.append(Check(level: .warn, title: "git", detail: "저장소가 아님 — 릴리즈노트 자동 생성·배포 태그를 쓸 수 없습니다"))
        }

        return out
    }

    // ── 템플릿 설치 ─────────────────────────────────────────────────────
    struct InstallResult {
        var created: [String] = []
        var skipped: [String] = []
        var changed: [String] = []
        var notes: [String] = []
        var lines: [String] {
            created.map { "＋ 생성: \($0)" }
                + changed.map { "✎ 수정: \($0)" }
                + skipped.map { "· 그대로 둠: \($0)" }
                + notes.map { "ℹ️  \($0)" }
        }
    }

    /// env 파일 본문에서 `KEY=값` 을 넣거나 고친다.
    /// 주석 처리된 `# KEY=` 가 있으면 그 자리를 살려 쓰고, 아무것도 없으면 끝에 붙인다.
    /// (사용자가 적어 둔 주석·순서를 보존하기 위해 통째로 다시 쓰지 않는다.)
    static func upsertEnv(_ body: String, _ key: String, _ value: String) -> String {
        var lines = body.components(separatedBy: "\n")
        let live = "(?m)^\\s*\(key)\\s*="
        let commented = "(?m)^\\s*#\\s*\(key)\\s*="
        for (i, line) in lines.enumerated() {
            if line.range(of: live, options: .regularExpression) != nil {
                lines[i] = "\(key)=\(value)"
                return lines.joined(separator: "\n")
            }
        }
        for (i, line) in lines.enumerated() {
            if line.range(of: commented, options: .regularExpression) != nil {
                lines[i] = "\(key)=\(value)"
                return lines.joined(separator: "\n")
            }
        }
        // 끝에 붙인다. 여러 키를 연달아 붙여도 사이에 빈 줄이 끼지 않도록
        // 꼬리의 빈 줄을 먼저 걷어내고, 설명글 뒤일 때만 한 줄 띄운다.
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        let lastIsSetting = lines.last?.range(of: "^\\s*[A-Z_][A-Z0-9_]*\\s*=", options: .regularExpression) != nil
        if !lines.isEmpty && !lastIsSetting { lines.append("") }
        lines.append("\(key)=\(value)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// "배포가 자동으로 되도록" 앱 폴더를 정리한다 — UI 의 [자동 설정] 버튼.
    ///
    /// 파일을 새로 만들 뿐 아니라 **이미 있는 deploy.env 도 손본다**: 빠진 키를 채우고,
    /// 경로가 틀린 VERSION_XCCONFIG 를 실제 위치로 고친다. 사용자가 쓴 값은 덮지 않는다.
    static func autoConfigure(_ app: ManagedApp) -> InstallResult {
        var result = InstallResult()
        let r = AppRepo.resolve(app)
        let dir = URL(fileURLWithPath: app.path)
        let fm = FileManager.default
        guard r.exists else {
            result.notes.append("Xcode 프로젝트가 없어 설정할 수 없습니다")
            return result
        }

        let report = Localization.scan(app.path)
        let locales = r.locales.isEmpty ? report.locales : r.locales
        let platform = (try? AppRepo.buildSettings(r))?.platform ?? .iOS
        let xcconfig = findVersionXcconfig(app.path)
        let predeployPath = r.predeploy ?? "scripts/predeploy.sh"

        // 번역이 이미 완벽한 앱만 strict 로 시작한다.
        // 구멍이 있는 앱을 갑자기 strict 로 바꾸면 다음 배포가 통째로 막혀 놀라게 된다.
        let gate: String = locales.count > 1 ? (report.ok ? "strict" : "warn") : "off"

        // 1) deploy.env
        let envURL = dir.appendingPathComponent("deploy.env")
        if let body = try? String(contentsOf: envURL, encoding: .utf8) {
            var updated = body
            var touched: [String] = []
            func set(_ k: String, _ v: String, when: Bool) {
                guard when else { return }
                let next = upsertEnv(updated, k, v)
                if next != updated { updated = next; touched.append(k) }
            }
            set("SCHEME", r.scheme, when: !hasSetting(body, "SCHEME"))
            set("PLATFORM", platform == .macOS ? "macos" : "ios", when: !hasSetting(body, "PLATFORM"))
            // 경로가 틀렸거나 안 적혀 있으면 실제 위치로
            let xcBroken = r.versionXcconfig.map { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) } ?? true
            set("VERSION_XCCONFIG", xcconfig ?? "", when: xcconfig != nil && xcBroken)
            set("PREDEPLOY_SCRIPT", predeployPath, when: !hasSetting(body, "PREDEPLOY_SCRIPT"))
            set("LOCALES", Locales.sorted(locales).joined(separator: ","), when: r.locales.isEmpty && locales.count > 1)
            set("LOCALIZATION_GATE", gate, when: !hasSetting(body, "LOCALIZATION_GATE"))
            if touched.isEmpty {
                result.skipped.append("deploy.env (고칠 것 없음)")
            } else {
                try? updated.write(to: envURL, atomically: true, encoding: .utf8)
                result.changed.append("deploy.env — \(touched.joined(separator: ", "))")
            }
        } else {
            // fastlane/.env 만 있던 앱도 여기서 deploy.env 로 옮겨 온다 (기존 값은 r 에 이미 반영돼 있음)
            var text = deployEnvTemplate(scheme: r.scheme, locales: locales,
                                         versionXcconfig: xcconfig, platform: platform)
            text = upsertEnv(text, "PREDEPLOY_SCRIPT", predeployPath)
            text = upsertEnv(text, "LOCALIZATION_GATE", gate)
            try? text.write(to: envURL, atomically: true, encoding: .utf8)
            result.created.append("deploy.env")
            if fm.fileExists(atPath: dir.appendingPathComponent("fastlane/.env").path) {
                result.notes.append("기존 fastlane/.env 값을 그대로 옮겨 왔습니다 — 이제 deploy.env 가 우선입니다")
            }
        }

        // 2) scripts/predeploy.sh
        let shURL = dir.appendingPathComponent(predeployPath)
        if fm.fileExists(atPath: shURL.path) {
            result.skipped.append("\(predeployPath) (이미 있음)")
        } else {
            try? fm.createDirectory(at: shURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? predeployTemplate(scheme: r.scheme, projectFlag: r.projFlag,
                                   container: (r.projContainer as NSString).lastPathComponent,
                                   isMac: platform == .macOS)
                .write(to: shURL, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shURL.path)
            result.created.append(predeployPath)
            result.notes.append("\(predeployPath) 는 테스트 타겟이 없으면 실패합니다 — 테스트가 없다면 그 단계를 지우세요")
        }

        if locales.count > 1 && gate == "warn" {
            result.notes.append("번역 구멍이 있어 게이트를 warn 으로 뒀습니다 — 다 채운 뒤 LOCALIZATION_GATE=strict 로 바꾸면 배포가 막아 줍니다")
        }
        return result
    }

    // ── 템플릿 본문 ─────────────────────────────────────────────────────
    /// MARKETING_VERSION·CURRENT_PROJECT_VERSION 을 가진 xcconfig 를 앱 폴더에서 찾는다 (앱 루트 기준 상대경로).
    /// 흔한 위치: ./Version.xcconfig, ./Config/Version.xcconfig
    static func findVersionXcconfig(_ dir: String) -> String? {
        let fm = FileManager.default
        var candidates = ["Version.xcconfig", "Config/Version.xcconfig", "Configs/Version.xcconfig"]
        // 그래도 못 찾으면 한 단계 아래에서 *.xcconfig 를 훑는다
        for sub in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] {
            var isDir: ObjCBool = false
            let p = "\(dir)/\(sub)"
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue,
                  !sub.hasPrefix("."), !sub.contains(".xcodeproj"), !sub.contains(".xcworkspace") else { continue }
            for f in (try? fm.contentsOfDirectory(atPath: p)) ?? [] where f.hasSuffix(".xcconfig") {
                candidates.append("\(sub)/\(f)")
            }
        }
        for rel in candidates {
            let full = "\(dir)/\(rel)"
            guard let body = try? String(contentsOfFile: full, encoding: .utf8) else { continue }
            if hasSetting(body, "MARKETING_VERSION"), hasSetting(body, "CURRENT_PROJECT_VERSION") { return rel }
        }
        return nil
    }

    static func deployEnvTemplate(scheme: String, locales: [String], versionXcconfig: String?,
                                  platform: Platform = .iOS) -> String {
        let localeLine = locales.isEmpty
            ? "# LOCALES=ko,en-US            # 다국어 앱이면 App Store 언어를 적는다"
            : "LOCALES=\(Locales.sorted(locales).joined(separator: ","))"
        let xcconfigLine = versionXcconfig.map { "VERSION_XCCONFIG = \($0)" }
            ?? "# VERSION_XCCONFIG=Version.xcconfig   # 버전을 xcconfig 로 중앙 관리하면 주석 해제"
        return """
        # DeployBar 배포 설정 — 이 파일이 이 앱의 배포 규칙 전부다.
        # 참고: DeployBar/README.md 의 "앱 쪽 규칙" 표

        # 필수: archive 할 scheme
        SCHEME=\(scheme)

        # 플랫폼 (ios | macos). 자동 판별이 맞으면 지워도 된다.
        # 멀티플랫폼 타겟은 SDKROOT 만으로 구분되지 않아 명시해 두는 편이 안전하다.
        PLATFORM=\(platform == .macOS ? "macos" : "ios")

        # 권장: 버전·빌드번호의 단일 소스. 없으면 project.pbxproj 를 직접 고친다(타겟이 여러 개면 위험).
        \(xcconfigLine.replacingOccurrences(of: " = ", with: "="))

        # 권장: 배포 전 게이트. 실패하면 아카이브를 만들지 않는다.
        PREDEPLOY_SCRIPT=scripts/predeploy.sh

        # 다국어: App Store 에 등록한 언어. 이 목록이 곧
        #   (1) 다국어 게이트의 검사 기준이고
        #   (2) 릴리즈노트를 만들 언어다.
        \(localeLine)

        # 다국어 게이트 강도
        #   strict — 번역 구멍이 하나라도 있으면 배포 중단 (다국어 앱 권장)
        #   warn   — 로그에만 남기고 배포는 진행 (기본값)
        #   off    — 검사 안 함
        LOCALIZATION_GATE=\(locales.isEmpty ? "off" : "strict")

        """
    }

    static func predeployTemplate(scheme: String, projectFlag: String, container: String, isMac: Bool) -> String {
        let destination = isMac
            ? """
              DEST='platform=macOS'
              """
            : """
              # 시뮬레이터는 **가장 최신 iOS 런타임의 iPhone** 으로 고른다.
              # `grep iPhone | head -1` 로 고르면 구버전 런타임 기기가 먼저 잡혀
              # "Unable to find a destination matching..." (exit 70) 로 죽는다.
              DEST_ID="$(xcrun simctl list devices available --json | python3 -c '
              import json, re, sys
              best = None
              for runtime, devices in json.load(sys.stdin)["devices"].items():
                  m = re.search(r"iOS-(\\d+)-(\\d+)", runtime)
                  if not m:
                      continue
                  version = (int(m.group(1)), int(m.group(2)))
                  for d in devices:
                      if d.get("isAvailable") and "iPhone" in d.get("name", ""):
                          if best is None or version > best[0]:
                              best = (version, d["udid"])
              print(best[1] if best else "")
              ')"
              if [ -z "$DEST_ID" ]; then
                echo "❌ 사용 가능한 iPhone 시뮬레이터가 없습니다"
                xcrun simctl list devices available | head -30
                exit 1
              fi
              DEST="platform=iOS Simulator,id=$DEST_ID"
              """
        return """
        #!/bin/sh
        # 배포 전 게이트 — 여기서 실패하면 DeployBar 가 아카이브를 만들지 않는다.
        #
        # 사용법:
        #   sh scripts/predeploy.sh
        #
        # 다국어(.xcstrings) 검사는 DeployBar 에 내장돼 있으므로 여기서 다시 하지 않는다.
        # 이 스크립트는 "이 앱만의" 검사 — 테스트, 금지 패턴 검사 등 — 를 담는다.
        #
        # ⚠️ CODE_SIGNING_ALLOWED=NO 로 테스트를 빠르게 만들지 말 것.
        #    entitlements 가 빠지면 CloudKit 등 실제 배포 경로에서만 터지는 문제를 놓친다.
        set -e
        ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
        cd "$ROOT"

        SCHEME="\(scheme)"
        PROJECT_FLAG="\(projectFlag)"
        PROJECT="\(container)"

        \(destination)

        echo "🧪 전체 테스트 실행 ($SCHEME)"
        xcodebuild test \\
          "$PROJECT_FLAG" "$PROJECT" \\
          -scheme "$SCHEME" \\
          -destination "$DEST" \\
          -quiet

        echo ""
        echo "✅ 게이트 통과 — 배포 가능"

        """
    }
}
