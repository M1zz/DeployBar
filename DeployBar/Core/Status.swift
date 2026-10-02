import Foundation

enum Status {
    // "4.4.0" 비교: a>b → 1, a<b → -1, 같으면 0
    static func cmpVer(_ a: String?, _ b: String?) -> Int {
        let pa = (a ?? "0").split(separator: ".").map { Int($0) ?? 0 }
        let pb = (b ?? "0").split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let d = (i < pa.count ? pa[i] : 0) - (i < pb.count ? pb[i] : 0)
            if d != 0 { return d > 0 ? 1 : -1 }
        }
        return 0
    }

    static func of(_ app: ManagedApp, fresh: Bool = false, sync: GitSync.Result? = nil) async -> AppStatus {
        let r = AppRepo.resolve(app)
        var st = AppStatus(name: app.name, path: app.path, state: .error)
        guard r.exists else { st.error = "Xcode 프로젝트를 찾을 수 없음"; return st }

        let info: BuildInfo
        do { info = try AppRepo.buildSettings(r, fresh: fresh) }
        catch { st.error = error.localizedDescription; return st }

        st.projectFile = AppRepo.projectKey(app.path)
        st.bundleId = info.bundleId
        st.team = info.team
        st.localVersion = info.marketingVersion
        st.localBuild = info.buildNumber
        st.shots = StorePublish.shotReport(app.path, platform: info.platform, locales: r.locales)
        st.locales = r.locales
        st.dirty = GitInfo.isRepo(app.path) ? GitInfo.isDirty(app.path) : false
        st.branch = GitInfo.isRepo(app.path) ? GitInfo.branch(app.path) : nil
        if GitInfo.isRepo(app.path), let ab = GitInfo.aheadBehind(app.path) {
            st.ahead = ab.ahead; st.behind = ab.behind
        }
        // 이번 새로고침에서 원격을 다녀온 결과 (Store 가 조회 직전에 돌린다)
        st.remoteError = sync?.fetchError ?? sync?.pullError
        st.pulledCommits = sync?.pulled ?? 0
        st.pullSkipped = sync?.skipped
        st.pullAttempted = sync?.attemptedPull ?? false
        // 배포 준비 검사가 쓸 번호 — 스토어 버전 목록을 받으면 그 규칙으로, 못 받으면 로컬 번호로
        var known = DeployPrep.Known(version: info.marketingVersion, released: true)

        do {
            if let id = try await ASCClient.appId(bundleId: info.bundleId) {
                let vers = try await ASCClient.appStoreVersions(appId: id)
                known = DeployPrep.known(versions: vers, local: info.marketingVersion)
                let ready = vers.first { $0.state == "READY_FOR_SALE" }
                st.liveVersion = (ready ?? vers.first)?.versionString
                st.liveState = (ready ?? vers.first)?.state
                // 심사/준비 등 진행 중인 버전(판매 중이 아닌)이 있으면 표시
                if let inflight = vers.first(where: { ASCState.isInflight($0.state) }) {
                    st.reviewState = inflight.state
                    st.reviewVersion = inflight.versionString
                }
                let upload = try await ASCClient.latestUpload(appId: id)
                st.ascBuild = upload?.build
                st.ascBuildVersion = upload?.version
                // 릴리즈노트가 비었는지는 **배포 전에** 알아야 한다.
                // 업로드 뒤에 알면 이미 빈 노트로 버전이 나간 뒤다.
                st.editableHasBuild = vers.first { ReleaseNotes.editableStates.contains($0.state) }?.hasBuild
                if let n = try await ReleaseNotes.notesState(versions: vers) {
                    st.notesVersion = n.version
                    st.notesFilled = n.filled
                    st.notesMissing = n.missing
                    st.notesFirstRelease = n.firstRelease
                    // deploy.env 에 적었지만 App Store 페이지에는 없는 언어.
                    // 이 언어의 릴리즈노트는 만들어도 올릴 자리가 없어 그냥 버려진다 —
                    // 아무 말도 안 하면 "영어 노트를 썼는데 왜 안 나오지" 를 알 길이 없다.
                    let listed = n.filled + n.missing
                    st.notesUnlistedLocales = r.locales.filter { want in
                        !listed.contains { Locales.sameLanguage($0, want) }
                    }
                } else {
                    st.notesUncheckable = true   // 편집 가능한 버전이 아직 없음 (첫 업로드 전)
                }
                // 아직 출시된 적 없는 앱만 — 스토어 페이지가 비어 있으면 제출 자체가 안 된다.
                // (업데이트 앱에는 묻지 않으므로 요청이 늘지 않는다)
                if !vers.contains(where: { $0.state == "READY_FOR_SALE" }) {
                    let store = await StorePublish.inspect(app, appId: id, versions: vers)
                    st.storeGaps = store.gaps
                    st.humanTodo = store.human
                }
            } else {
                st.ascError = "ASC 에서 앱을 찾지 못함 (bundleId 불일치)"
                st.ascReach = .missing
            }
        } catch let e as ASCClient.APIError {
            // 401·403 은 키가 잘못된 것 — altool 도 같은 키를 쓰므로 업로드까지 못 한다.
            // status 0 은 키·발급자가 아예 설정되지 않은 경우(jwt() 가 그렇게 던진다).
            // 나머지(429·5xx·그 밖)는 '우리가 못 물어본 것' 이지 앱의 문제가 아니다.
            let credential = [0, 401, 403].contains(e.status)
            st.ascError = e.status == 0 ? e.body : "ASC \(e.status)"
            st.ascReach = credential ? .unauthorized : .unreachable
        } catch {
            // URLError = 네트워크. 그 밖(.p8 키 파일을 못 읽는 등)은 자격증명 쪽으로 본다.
            st.ascError = error.localizedDescription
            st.ascReach = error is URLError ? .unreachable : .unauthorized
        }

        // 마지막 배포(deploy-*) 태그 이후 새 커밋이 있으면 같은 버전이라도 배포할 게 있는 것.
        // 배포 태그가 있어야만(=이 툴로 배포한 이력) 신호로 쓴다. 태그가 없으면 숫자 비교로만 판정.
        if GitInfo.isRepo(app.path), let tag = GitInfo.lastDeployTag(app.path) {
            st.commitsSinceDeploy = GitInfo.commitsSince(app.path, tag: tag, shippingOnly: true).count
        }

        // 판정
        let verAhead = st.liveVersion != nil ? cmpVer(st.localVersion, st.liveVersion) > 0 : true
        // 같은 버전에 빌드만 높다 — 그 버전이 아직 안 나갔을 때만 뜻이 있다. 이미 판매 중인 버전엔
        // 새 빌드를 붙일 수 없으니(배포가 번호를 올린다), 리젝 대응으로 올려 두고 남은 빌드 번호 하나로
        // 출시된 앱이 '배포 가능' 이 되면 안 된다 (징검돌 2.1.0: 로컬 9 > 스토어 8).
        let buildAhead = st.ascBuild != nil
            && st.liveState != "READY_FOR_SALE"
            && cmpVer(st.localVersion, st.liveVersion) == 0
            && (Int(st.localBuild ?? "0") ?? 0) > (Int(st.ascBuild ?? "0") ?? 0)
        let commitsAhead = st.commitsSinceDeploy > 0
        // 스토어에 새 버전을 만들어 두고(부제·키워드를 고치려고 등) 빌드를 기다리는 중이면,
        // 코드가 그대로여도 올릴 게 있는 것이다 — 배포가 번호를 그 버전에 맞춰 올린다.
        let storeWaiting = st.editableHasBuild == false
        // 심사에서 거부된 버전 — 고친 빌드를 다시 올리는 게 다음 일이다. 첫 출시 앱은 판매 중인 버전이 없어
        // 거부된 그 버전을 '스토어 버전' 으로 읽으므로, 이게 없으면 "로컬 v1.0 이 이미 스토어에 있음" 으로 잠겼다.
        let rejected = st.reviewState.map(ASCState.isRejected) ?? false
        if st.dirty { st.state = .dev }
        else if verAhead || buildAhead || commitsAhead || storeWaiting || rejected { st.state = .ready }
        else { st.state = .deployed }

        st.prepGaps = await DeployPrep.audit(app, known: known).gaps
        st.nextVersion = known.version

        // 상태가 정해진 뒤에 준비 체크리스트를 만든다 (판정 결과를 그대로 쓴다)
        st.readiness = Readiness.evaluate(app, status: st)
        return st
    }

    static func all(fresh: Bool = false, pull: Bool = false) async -> [AppStatus] {
        if fresh { AppRepo.clearCache() }
        let apps = AppRepo.registry()
        // UI 와 같은 순서: 원격을 먼저 다녀와야 ahead/behind 가 옛 값이 아니다
        let sync = await GitSync.run(apps, pull: pull)
        var out: [AppStatus] = []
        for app in apps {
            out.append(await of(app, fresh: fresh, sync: sync[app.path]))
        }
        return out
    }
}
