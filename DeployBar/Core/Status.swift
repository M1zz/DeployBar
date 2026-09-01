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

    static func of(_ app: ManagedApp, fresh: Bool = false) async -> AppStatus {
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
        st.dirty = GitInfo.isRepo(app.path) ? GitInfo.isDirty(app.path) : false
        st.branch = GitInfo.isRepo(app.path) ? GitInfo.branch(app.path) : nil
        if GitInfo.isRepo(app.path), let ab = GitInfo.aheadBehind(app.path) {
            st.ahead = ab.ahead; st.behind = ab.behind
        }

        do {
            if let id = try await ASCClient.appId(bundleId: info.bundleId) {
                let vers = try await ASCClient.appStoreVersions(appId: id)
                let ready = vers.first { $0.state == "READY_FOR_SALE" }
                st.liveVersion = (ready ?? vers.first)?.versionString
                st.liveState = (ready ?? vers.first)?.state
                // 심사/준비 등 진행 중인 버전(판매 중이 아닌)이 있으면 표시
                if let inflight = vers.first(where: { ASCState.isInflight($0.state) }) {
                    st.reviewState = inflight.state
                    st.reviewVersion = inflight.versionString
                }
                st.ascBuild = try await ASCClient.latestBuild(appId: id)
                // 릴리즈노트가 비었는지는 **배포 전에** 알아야 한다.
                // 업로드 뒤에 알면 이미 빈 노트로 버전이 나간 뒤다.
                st.editableHasBuild = vers.first { ReleaseNotes.editableStates.contains($0.state) }?.hasBuild
                if let n = try await ReleaseNotes.notesState(versions: vers) {
                    st.notesVersion = n.version
                    st.notesFilled = n.filled
                    st.notesMissing = n.missing
                } else {
                    st.notesUncheckable = true   // 편집 가능한 버전이 아직 없음 (첫 업로드 전)
                }
            } else {
                st.ascError = "ASC 에서 앱을 찾지 못함 (bundleId 불일치)"
            }
        } catch let e as ASCClient.APIError {
            st.ascError = "ASC \(e.status)"
        } catch {
            st.ascError = error.localizedDescription
        }

        // 마지막 배포(deploy-*) 태그 이후 새 커밋이 있으면 같은 버전이라도 배포할 게 있는 것.
        // 배포 태그가 있어야만(=이 툴로 배포한 이력) 신호로 쓴다. 태그가 없으면 숫자 비교로만 판정.
        if GitInfo.isRepo(app.path), let tag = GitInfo.lastDeployTag(app.path) {
            st.commitsSinceDeploy = GitInfo.commitsSince(app.path, tag: tag).count
        }

        // 판정
        let verAhead = st.liveVersion != nil ? cmpVer(st.localVersion, st.liveVersion) > 0 : true
        let buildAhead = st.ascBuild != nil
            && cmpVer(st.localVersion, st.liveVersion) == 0
            && (Int(st.localBuild ?? "0") ?? 0) > (Int(st.ascBuild ?? "0") ?? 0)
        let commitsAhead = st.commitsSinceDeploy > 0
        if st.dirty { st.state = .dev }
        else if verAhead || buildAhead || commitsAhead { st.state = .ready }
        else { st.state = .deployed }

        // 상태가 정해진 뒤에 준비 체크리스트를 만든다 (판정 결과를 그대로 쓴다)
        st.readiness = Readiness.evaluate(app, status: st)
        return st
    }

    static func all(fresh: Bool = false) async -> [AppStatus] {
        if fresh { AppRepo.clearCache() }
        var out: [AppStatus] = []
        for app in AppRepo.registry() {
            out.append(await of(app, fresh: fresh))
        }
        return out
    }
}
