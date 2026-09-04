import Foundation

// fastlane 없이 배포: 게이트 → 빌드번호+1 → archive → export → altool 업로드
enum Deployer {
    enum Lane: String { case check, beta, appstore }

    /// git pull 이 왜 실패했는지 git 출력에서 읽어 낸다.
    /// "원격과 동기화 후 다시 배포하세요" 한 줄로는 무엇을 해야 할지 알 수 없어서,
    /// 갈라진 건지·인증인지·네트워크인지까지 나누고 각각의 할 일을 붙인다.
    private static func pullFailure(_ e: Shell.Error) -> (title: String, todo: [String]) {
        let out = e.output.lowercased()
        func has(_ needles: [String]) -> Bool { needles.contains { out.contains($0) } }

        if has(["not possible to fast-forward", "divergent", "non-fast-forward", "diverged"]) {
            return ("로컬과 원격이 갈라졌습니다 — 한쪽에만 있는 커밋이 서로 있습니다", [
                "터미널에서 `git pull --rebase` 로 원격 커밋 위에 내 커밋을 얹으세요",
                "또는 내 커밋을 먼저 `git push` 한 뒤 다시 배포하세요",
                "합친 뒤 [배포] 를 다시 누르면 됩니다",
            ])
        }
        if has(["local changes", "unstaged", "would be overwritten", "please commit your changes"]) {
            return ("저장 안 된 변경이 원격 변경과 겹칩니다", [
                "`git commit` 으로 커밋하거나 `git stash` 로 잠시 치워 두세요",
                "그다음 [배포] 를 다시 누르세요",
            ])
        }
        if has(["could not read username", "authentication failed", "permission denied", "403",
                "terminal prompts disabled", "invalid username or password"]) {
            return ("원격 인증에 실패했습니다", [
                "터미널에서 `git pull` 을 한 번 실행해 자격증명을 갱신하세요",
                "GitHub 토큰이 만료됐다면 새로 발급해 keychain 에 저장하세요",
                "GUI 앱에서는 비밀번호 입력창을 띄울 수 없어 그냥 실패합니다",
            ])
        }
        if has(["could not resolve host", "timed out", "connection refused",
                "network is unreachable", "failed to connect", "operation timed out"]) {
            return ("원격에 접속하지 못했습니다 (네트워크)", [
                "네트워크 연결을 확인하세요",
                "VPN·프록시를 쓰고 있으면 잠시 끄고 다시 시도하세요",
            ])
        }
        return ("git pull 이 종료코드 \(e.code) 로 끝났습니다", [
            "터미널에서 `git pull --ff-only` 를 직접 실행해 무슨 말이 나오는지 보세요",
            "아래 'git 이 한 말' 이 그대로 원인입니다",
        ])
    }

    /// 셸 명령 한 단계. 실패하면 그 단계에 맞는 '할 일' 을 붙여 던진다.
    @discardableResult
    private static func stage(
        _ name: String, _ app: ManagedApp, _ launch: String, _ args: [String], cwd: URL,
        title: String, todo: [String], fix: Fix? = nil,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        do { return try await Shell.run(launch, args, cwd: cwd, onLog: onLog) }
        catch let e as Shell.Error {
            throw DeployError(app: app.name, path: app.path, stage: name,
                              title: "\(title) (종료코드 \(e.code))",
                              todo: todo, detail: e.tail, fix: fix)
        }
    }

    /// 업로드한 빌드가 App Store Connect 에 실제로 도착했는지 확인한다.
    /// altool 의 말만 믿지 않기 위한 이중 확인 — 도착이 곧 진실이다.
    private static func confirmOnASC(bundleId: String, marketingVersion: String, build: Int,
                                     onLog: @escaping @Sendable (String) -> Void) async -> Bool {
        onLog("🔍 App Store Connect 에 빌드 도착 확인 중… (v\(marketingVersion) build \(build))")
        // 업로드 직후엔 아직 안 보일 수 있어 조금씩 기다리며 다시 본다 (최대 약 90초)
        for delay in [3, 7, 15, 25, 40] {
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard let id = try? await ASCClient.appId(bundleId: bundleId) else { continue }
            let latest = (try? await ASCClient.latestBuild(appId: id, marketingVersion: marketingVersion)) ?? nil
            guard let n = latest else { continue }
            if n >= build {
                onLog("✅ 확인됨 — App Store Connect 에 v\(marketingVersion) build \(n) 이 있습니다")
                return true
            }
        }
        onLog("⚠️  아직 확인되지 않았습니다 — Apple 처리가 늦는 것일 수 있습니다 (TestFlight 에서 확인하세요)")
        return false
    }

    struct Result { let version: String; let build: Int }

    // versionBump: nil = 빌드만 올리기(버전 유지), .patch/.minor/.major = 그만큼 버전 올린 뒤 배포(빌드 1부터)
    /// 단계가 바뀔 때마다 부르는 보고 채널. 로그(무슨 일이 있었나)와 별개로
    /// "지금 어느 칸인가" 를 UI 가 알 수 있게 한다.
    typealias StageReport = @Sendable (DeployStage, StageState, String?) -> Void

    static func deploy(_ app: ManagedApp, lane: Lane, versionBump: VersionBump? = nil,
                       onLog: @escaping @Sendable (String) -> Void,
                       onStage: @escaping StageReport = { _, _, _ in }) async throws -> Result {
        func begin(_ s: DeployStage) { onStage(s, .running, nil) }
        func done(_ s: DeployStage, _ note: String? = nil) { onStage(s, .done, note) }
        func skip(_ s: DeployStage, _ note: String) { onStage(s, .skipped, note) }

        begin(.prepare)
        let r = AppRepo.resolve(app)
        guard r.exists else {
            throw DeployError(app: app.name, path: app.path, stage: "프로젝트 확인",
                              title: "Xcode 프로젝트를 찾지 못했습니다",
                              todo: ["앱 폴더 최상단에 .xcodeproj / .xcworkspace 가 있어야 합니다",
                                     "폴더 안쪽에 있다면 최상단으로 옮기세요"])
        }
        let info: BuildInfo
        do { info = try AppRepo.buildSettings(r, fresh: true) }
        catch {
            throw DeployError(app: app.name, path: app.path, stage: "빌드 설정 조회",
                              title: "xcodebuild 가 빌드 설정을 읽지 못했습니다",
                              todo: ["deploy.env 의 SCHEME 이 실제 scheme 이름과 같은지 확인하세요",
                                     "터미널에서 `xcodebuild -list` 로 scheme 이름을 볼 수 있습니다",
                                     "[자동 설정] 이 scheme 을 다시 잡아 줍니다"],
                              detail: error.localizedDescription, fix: .configure)
        }
        done(.prepare, "\(r.scheme) · \(info.bundleId) · \(info.platform.rawValue)")
        var marketingVersion = info.marketingVersion
        let cwd = URL(fileURLWithPath: r.path)
        let workDir = cwd.appendingPathComponent("build/deploy-console")
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 0) 최신 코드 반영: 배포 전 git pull (원격의 최신 커밋을 먼저 가져온다)
        if GitInfo.isRepo(r.path) {
            if let up = GitInfo.upstream(r.path) {
                begin(.pull)
                onLog("⬇️  git pull --ff-only  (\(up))")
                do {
                    try await Shell.run("/usr/bin/git", ["pull", "--ff-only"], cwd: cwd, onLog: onLog)
                    done(.pull, up)
                } catch let e as Shell.Error {
                    let f = pullFailure(e)
                    throw DeployError(app: app.name, path: app.path, stage: "git pull",
                                      title: f.title, todo: f.todo, detail: e.tail)
                }
            } else {
                // 원격을 안 따라가는 브랜치는 당겨 올 것이 없다 — 여기서 배포를 막을 이유가 없다
                onLog("⏭  원격 추적 브랜치 없음 — git pull 건너뜀")
                skip(.pull, "원격 추적 브랜치 없음")
            }
        } else {
            skip(.pull, "git 저장소가 아님")
        }

        // 1) 게이트 — 먼저 다국어(내장), 그다음 앱별 스크립트
        //    번역 구멍은 빌드가 아니라 사용자가 보는 화면의 문제라 xcodebuild 로는 절대 안 잡힌다.
        let gateMode = Localization.Mode(r.localizationGate)
        if gateMode == .off {
            onLog("🌐 다국어 검사: LOCALIZATION_GATE=off — 건너뜀")
            skip(.l10n, "LOCALIZATION_GATE=off")
        } else {
            begin(.l10n)
            let report = Localization.scan(r.path, expected: r.locales)
            for line in Localization.summaryLines(report, mode: gateMode) { onLog(line) }
            if gateMode == .strict && !report.ok {
                let head = report.byLocale.prefix(3)
                    .map { "\(Locales.displayName($0.locale)) \($0.count)건" }.joined(separator: ", ")
                throw DeployError(
                    app: app.name, path: app.path, stage: "다국어 검사",
                    title: "번역 구멍 \(report.issues.count)건 — LOCALIZATION_GATE=strict 라 배포를 멈췄습니다",
                    todo: ["Xcode 에서 String Catalog(.xcstrings)를 열어 빈 번역을 채우세요",
                           "지금 당장 내야 한다면 deploy.env 의 LOCALIZATION_GATE 를 warn 으로 바꾸면 경고만 하고 진행합니다",
                           "채운 뒤 커밋하고 [배포] 를 다시 누르세요"],
                    detail: head)
            }
            done(.l10n, report.ok ? "\(report.locales.count)개 언어 · 번역 구멍 없음"
                                  : "번역 구멍 \(report.issues.count)건 — \(gateMode == .strict ? "" : "warn 이라 진행")")
        }

        // 1.2) 릴리즈노트 게이트 — 빌드를 만들기 전에 막는다.
        //      업로드 뒤에 알면 이미 빈 '이 버전의 새로운 기능' 으로 버전이 나간 뒤다.
        let notesGate = Localization.Mode(r.releaseNotesGate)
        if notesGate == .off {
            onLog("📝 릴리즈노트 검사: RELEASE_NOTES_GATE=off — 건너뜀")
            skip(.notes, "RELEASE_NOTES_GATE=off")
        } else {
            begin(.notes)
            // ⚠️ 여기서 오류를 삼키면 안 된다.
            //    예전엔 `try?` 로 물어보고, 실패하면 nil → "편집 가능한 버전 없음" 으로 지나갔다.
            //    즉 **ASC 에 못 물어본 것을 '물어봤더니 괜찮더라' 로 읽었다.**
            //    strict 게이트는 빈 노트가 나가는 걸 막으려고 있는데, 못 물어본 순간
            //    조용히 통과해 버리면 게이트가 있으나 마나다. 못 물어봤으면 못 물어봤다고 말한다.
            var notes: ReleaseNotes.NotesState?
            var probeError: String?
            do {
                if let ascId = try await ASCClient.appId(bundleId: info.bundleId) {
                    notes = try await ReleaseNotes.notesState(appId: ascId)
                } else {
                    probeError = "ASC 에서 앱을 찾지 못했습니다 (bundleId \(info.bundleId))"
                }
            } catch let e as ASCClient.APIError {
                probeError = "App Store Connect 응답 HTTP \(e.status)"
            } catch {
                probeError = error.localizedDescription
            }
            if let probeError {
                if notesGate == .strict {
                    throw DeployError(
                        app: app.name, path: app.path, stage: "릴리즈노트 검사",
                        title: "릴리즈노트가 비었는지 확인하지 못했습니다",
                        todo: ["App Store Connect 조회가 실패했습니다 — 자격증명이나 네트워크를 확인하세요",
                               "~/Documents/workspace/fastlane-shared/asc.env 의 ASC_KEY_ID·ASC_ISSUER_ID 와 .p8 키를 확인하세요",
                               "확인 없이 내야 한다면 deploy.env 에 RELEASE_NOTES_GATE=warn 을 넣으세요"],
                        detail: probeError)
                }
                onLog("⚠️  릴리즈노트 확인 실패(\(probeError)) — RELEASE_NOTES_GATE=warn 이라 진행합니다")
                done(.notes, "확인 실패 — \(probeError)")
            } else if let notes {
                if notes.missing.isEmpty {
                    onLog("📝 릴리즈노트 준비됨 — v\(notes.version) · \(notes.filled.count)개 언어")
                    done(.notes, "v\(notes.version) · \(notes.filled.count)개 언어 채워짐")
                } else {
                    let head = notes.missing.prefix(5).map { Locales.displayName($0) }.joined(separator: ", ")
                    let msg = "v\(notes.version) 의 '이 버전의 새로운 기능' 이 \(notes.missing.count)개 언어에서 비어 있습니다"
                    // check 는 스토어에 쓰지 않으므로 채우기(.notesPrefill)를 건너뛴다.
                    // 그래서 **진짜 배포라면 채워졌을 칸**을 비어 있다고 보고 ❌ 를 냈다 —
                    // 레포에 원고를 써 둔 사람에게 "그래도 비어 있다" 고 답하는 셈이라,
                    // 시키는 대로 원고를 다시 써도 check 는 계속 빨갛다. 여기서만 원고를 본다.
                    // (진짜 배포에서는 절대 이 완화를 쓰지 않는다. 채우기가 실패했는데도
                    //  통과시키면 빈 노트가 그대로 심사에 나간다 — 게이트가 있는 이유가 그거다.)
                    let repoCovers = lane == .check
                        && RepoNotes.read(app.path, version: info.marketingVersion).map { found in
                            notes.missing.allSatisfy { loc in
                                found.texts.keys.contains { Locales.sameLanguage($0, loc) }
                            }
                        } == true
                    if repoCovers {
                        onLog("📝 릴리즈노트: App Store 칸은 비었지만 레포 원고가 \(notes.missing.count)개 언어를 덮습니다 — 배포하면 채웁니다")
                        done(.notes, "레포 원고로 채워집니다 (\(head))")
                    } else if notesGate == .strict {
                        throw DeployError(
                            app: app.name, path: app.path, stage: "릴리즈노트 검사",
                            title: msg,
                            todo: ["[릴리즈노트] 창을 열어 [빈 언어 채우기] 를 누른 뒤 적용하세요",
                                   "빈 채로 내야 한다면 deploy.env 에 RELEASE_NOTES_GATE=warn 을 넣으세요",
                                   "채운 뒤 [배포] 를 다시 누르면 됩니다"],
                            detail: "빈 언어: \(head)\(notes.missing.count > 5 ? " 외" : "")",
                            fix: .openNotes)
                    } else {
                        onLog("⚠️  릴리즈노트 비어 있음 (\(head)) — RELEASE_NOTES_GATE=warn 이라 진행합니다")
                        done(.notes, "\(notes.missing.count)개 언어 비어 있음 — warn 이라 진행")
                    }
                }
            } else {
                // 업로드가 App Store 버전을 만들어 주지는 않는다 (altool 은 빌드만 올린다).
                // 사람이 App Store Connect 에서 버전을 만들기 전까지는 쓸 자리가 없다.
                onLog("📝 릴리즈노트: App Store Connect 에 편집 가능한 버전이 없어 확인 생략 — 버전을 만든 뒤에 반영됩니다")
                skip(.notes, "편집 가능한 App Store 버전 없음 — ASC 에서 버전을 먼저 만드세요")
            }
        }

        if let predeploy = r.predeploy {
            begin(.gate)
            onLog("🛡  배포 전 게이트: \(predeploy)")
            try await stage("배포 전 검사", app, "/bin/sh", [predeploy], cwd: cwd,
                            title: "\(predeploy) 가 실패했습니다",
                            todo: ["위 로그에서 실패한 테스트·검사를 찾아 고치세요",
                                   "터미널에서 `sh \(predeploy)` 로 같은 검사를 돌려 볼 수 있습니다",
                                   "테스트 타겟이 없어서 실패하는 거라면 \(predeploy) 에서 그 단계를 지우세요"],
                            onLog: onLog)
            done(.gate, predeploy)
        } else {
            onLog("⚠️  PREDEPLOY_SCRIPT 미설정 — 게이트 건너뜀")
            skip(.gate, "PREDEPLOY_SCRIPT 미설정")
        }
        if lane == .check {
            onLog("✅ 게이트 통과 (check 모드 — 배포 없음)")
            onStage(.version, .skipped, "check 모드 — 여기까지만 합니다")
            return Result(version: info.marketingVersion, build: Int(info.buildNumber) ?? 0)
        }

        // 1.5) 버전 처리 — 배포 전에 결정한다. 올릴지(버전), 유지할지(빌드만) 여기서 갈린다.
        begin(.version)
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
        done(.version, "v\(marketingVersion) · build \(newBuild)")

        // 3) archive — 플랫폼(iOS/macOS)에 맞는 destination 사용
        onLog("🖥  플랫폼: \(info.platform.rawValue) (destination \(info.platform.destination))")
        let archivePath = workDir.appendingPathComponent("\(r.scheme).xcarchive").path
        begin(.archive)
        try await stage("archive", app, "/usr/bin/xcodebuild", [
            "archive", r.projFlag, r.projContainer,
            "-scheme", r.scheme, "-configuration", "Release",
            "-destination", info.platform.destination,
            "-archivePath", archivePath,
            "-allowProvisioningUpdates", "-quiet",
        ], cwd: cwd,
           title: "xcodebuild archive 가 실패했습니다",
           todo: ["로그에서 **첫 번째** `error:` 줄이 원인입니다 (뒤쪽 줄은 그 여파인 경우가 많습니다)",
                  "Xcode 에서 같은 scheme 을 Product ▸ Archive 로 한 번 돌려 보면 같은 오류가 더 잘 보입니다",
                  "서명·프로비저닝 오류라면 Xcode ▸ Settings ▸ Accounts 에서 팀 로그인을 확인하세요"],
           onLog: onLog)
        done(.archive, "Release · \(info.platform.rawValue)")

        // 4) export IPA
        let exportDir = workDir.appendingPathComponent("export")
        try? FileManager.default.removeItem(at: exportDir)
        let plist = try writeExportOptions(workDir, team: info.team)
        begin(.export)
        try await stage("export", app, "/usr/bin/xcodebuild", [
            "-exportArchive",
            "-archivePath", archivePath,
            "-exportPath", exportDir.path,
            "-exportOptionsPlist", plist.path,
            "-allowProvisioningUpdates",
        ], cwd: cwd,
           title: "xcodebuild -exportArchive 가 실패했습니다",
           todo: ["아카이브는 됐는데 서명해서 꺼내는 데서 막혔습니다 — 대개 프로비저닝 프로파일 문제입니다",
                  "Xcode ▸ Settings ▸ Accounts 에서 팀(\(info.team ?? "미지정"))이 로그인돼 있는지 확인하세요",
                  "App Store Connect 에 이 번들 ID(\(info.bundleId))로 앱이 등록돼 있어야 합니다"],
           onLog: onLog)

        // 5) altool 업로드 — 산출물(iOS: .ipa / macOS: .pkg)과 -t 타입을 플랫폼에 맞춘다
        let ext = info.platform.exportExt
        let artifacts = (try? FileManager.default.contentsOfDirectory(atPath: exportDir.path)) ?? []
        guard let file = artifacts.first(where: { $0.hasSuffix(".\(ext)") }) else {
            throw DeployError(
                app: app.name, path: app.path, stage: "export",
                title: "export 는 끝났는데 .\(ext) 파일이 없습니다",
                todo: ["deploy.env 의 PLATFORM 이 실제 플랫폼과 맞는지 확인하세요 (지금 \(info.platform.rawValue))",
                       "iOS 앱인데 macos 로 잡혀 있으면 .ipa 대신 .pkg 를 찾게 됩니다",
                       "[자동 설정] 이 플랫폼을 다시 판별해 줍니다"],
                detail: "찾은 파일: \(artifacts.isEmpty ? "없음" : artifacts.joined(separator: ", "))",
                fix: .configure)
        }
        let uploadPath = exportDir.appendingPathComponent(file).path
        onLog("📦 \(ext.uppercased()): \(uploadPath)")
        done(.export, "\(ext.uppercased()) — \(file)")
        let asc = Config.asc
        begin(.upload)
        let uploadOutput = try await stage("업로드", app, "/usr/bin/xcrun", [
            "altool", "--upload-app", "-f", uploadPath, "-t", info.platform.altoolType,
            "--apiKey", asc.keyId, "--apiIssuer", asc.issuer,
        ], cwd: cwd,
           title: "altool 업로드가 실패했습니다",
           todo: ["로그의 `ERROR ITMS-xxxx` 줄이 App Store 가 말하는 거부 사유입니다",
                  "자격증명 문제라면 ~/Documents/workspace/fastlane-shared/asc.env 와 .p8 키를 확인하세요",
                  "빌드는 이미 만들어졌으니, 원인을 고친 뒤 [배포] 를 다시 누르면 됩니다"],
           onLog: onLog)
        // altool 은 업로드 실패에도 종료코드 0 을 반환한다.
        // 예전엔 "오류 문구가 없으면 성공" 으로 봤는데, 출력이 잘리거나 문구가 바뀌면
        // **실패를 성공으로 읽는다.** 40개를 연속 배포할 때 이건 가장 비싼 실수다.
        // 그래서 성공은 성공이라고 말할 때만 인정하고, 애매하면 App Store Connect 에 직접 물어본다.
        let lower = uploadOutput.lowercased()
        let saidOK = lower.contains("no errors uploading") || lower.contains("upload succeeded")
        let saidBad = lower.contains("failed to upload") || lower.contains("error itms-")
            || lower.contains("*** error")
        done(.upload, saidOK ? "altool 이 성공을 보고했습니다" : "altool 응답이 애매합니다 — 도착으로 판정합니다")
        begin(.confirm)
        if saidBad || !saidOK {
            // 성공 문구가 없다고 바로 실패로 단정하지 않는다 — ASC 에 빌드가 도착했는지 확인한다.
            // (altool 문구가 바뀌었을 뿐인데 배포를 실패로 처리하면 그것대로 사고다)
            let landed = await confirmOnASC(bundleId: info.bundleId, marketingVersion: marketingVersion,
                                            build: newBuild, onLog: onLog)
            if !landed {
                let itms = uploadOutput.split(separator: "\n").map(String.init)
                    .filter { $0.contains("ITMS-") || $0.lowercased().contains("error") }
                    .prefix(4).joined(separator: "\n")
                throw DeployError(
                    app: app.name, path: app.path, stage: "업로드",
                    title: saidBad ? "App Store Connect 가 업로드를 거부했습니다"
                                   : "업로드 결과를 확인하지 못했습니다 — App Store Connect 에 빌드가 없습니다",
                    todo: ["아래 `ERROR ITMS-xxxx` 가 있으면 그게 거부 사유입니다",
                           "빌드번호 중복(ITMS-4238)이면 [배포] 를 다시 누르면 자동으로 +1 됩니다",
                           "App Store Connect ▸ TestFlight 에서 빌드가 정말 없는지 확인하세요"],
                    detail: itms.isEmpty ? "altool 출력에 성공/실패 문구가 없었습니다" : itms)
            }
        } else {
            // 성공 문구가 있어도 실제 도착까지 확인해 둔다
            _ = await confirmOnASC(bundleId: info.bundleId, marketingVersion: marketingVersion,
                                   build: newBuild, onLog: onLog)
        }
        done(.confirm, "v\(marketingVersion) build \(newBuild)")

        onLog("🚀 [\(r.scheme)] 업로드 완료 — v\(marketingVersion) (build \(newBuild))")
        // '배포 완료' 가 '출시됨' 으로 읽히지 않게, 여기서 끝나는 지점을 분명히 말한다.
        // DeployBar 는 빌드를 올리는 데까지다 — 버전에 빌드를 붙이고 심사에 내는 건 사람이 한다.
        onLog("ℹ️  여기까지가 '빌드 업로드' 입니다. App Store 에 올리려면 남은 일이 있습니다:")
        onLog("   1) App Store Connect ▸ \(app.name) ▸ v\(marketingVersion) 에서 빌드 \(newBuild) 선택")
        onLog("   2) '심사에 제출' 누르기 — DeployBar 는 심사 제출까지는 하지 않습니다")
        onLog("   · 빌드가 목록에 뜨기까지 Apple 처리에 몇 분 걸릴 수 있습니다")
        if GitInfo.isRepo(r.path) {
            begin(.tag)
            let tag = "deploy-\(r.scheme)-\(marketingVersion)-\(newBuild)"
            if GitInfo.tag(r.path, name: tag, message: "deploy-bar: \(marketingVersion) (\(newBuild))") {
                onLog("🏷  태그: \(tag)")
                done(.tag, tag)
            } else {
                skip(.tag, "같은 이름의 태그가 이미 있습니다")
            }
        } else {
            skip(.tag, "git 저장소가 아님")
        }
        // 버전은 사용자가 '버전 올리기'를 고를 때만 바뀐다 — 배포 후 자동 증가 없음
        return Result(version: marketingVersion, build: newBuild)
    }

    // 빌드번호를 지정한 값으로 설정 (VERSION_XCCONFIG 우선, 없으면 agvtool)
    private static func setBuild(_ r: ResolvedApp, to target: Int, onLog: @escaping @Sendable (String) -> Void) async throws {
        if let xc = r.versionXcconfig {
            let file = URL(fileURLWithPath: r.path).appendingPathComponent(xc)
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                throw DeployError(app: r.name, path: r.path, stage: "빌드번호 설정",
                                  title: "VERSION_XCCONFIG 파일이 없습니다",
                                  todo: ["deploy.env 의 VERSION_XCCONFIG 경로가 실제 파일과 다릅니다",
                                         "[자동 설정] 이 실제 위치를 찾아 고쳐 줍니다"],
                                  detail: file.path, fix: .configure)
            }
            let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var found = false
            let updated = lines.map { line -> String in
                if line.range(of: #"^\s*CURRENT_PROJECT_VERSION\s*="#, options: .regularExpression) != nil {
                    found = true
                    return "CURRENT_PROJECT_VERSION = \(target)"
                }
                return line
            }
            guard found else {
                throw DeployError(app: r.name, path: r.path, stage: "빌드번호 설정",
                                  title: "\(xc) 에 CURRENT_PROJECT_VERSION 줄이 없습니다",
                                  todo: ["그 파일에 `CURRENT_PROJECT_VERSION = 1` 한 줄을 추가하세요",
                                         "MARKETING_VERSION 도 같은 파일에 두면 버전 관리가 한곳으로 모입니다"],
                                  detail: file.path)
            }
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
