import Foundation

// 명령줄에서 배포 시키기 — `DeployBar --deploy <앱>` 이 떠 있는 DeployBar 에 일을 넘긴다.
//
// 폰에서 Claude Code(Remote Control)로 "달빛 배포해줘" 하면 그 세션이 이 Mac 에서 명령을 부른다.
// 배포를 명령줄 프로세스가 직접 돌리지 않는 이유: 배포 버튼은 릴리즈노트 미리 채우기 → 업로드 →
// 처리 대기 → 빌드 연결 → 심사 제출을 한 흐름(Store.runOneDeploy)으로 묶고, 진행판·알림·로그도 거기 붙어 있다.
// 그걸 둘로 만들면 언젠가 갈라진다. 그래서 요청만 넘기고, 돌리는 건 버튼과 **같은 코드**다.
//
// 통로는 DistributedNotificationCenter(같은 사용자 세션 안의 프로세스끼리). 주고받는 것:
//   요청  kind = ping | ready | deploy   (+ id, app, bump, lane)
//   답    kind = pong | list | accepted | rejected | done   (+ id, message, log)
enum RemoteDeploy {
    static let request = Notification.Name("com.leeo.deploybar.remote.request")
    static let reply = Notification.Name("com.leeo.deploybar.remote.reply")
}

extension Store {
    /// 앱이 뜰 때 한 번 — 명령줄의 요청을 듣기 시작한다.
    func listenForRemote() {
        DistributedNotificationCenter.default().addObserver(
            forName: RemoteDeploy.request, object: nil, queue: .main
        ) { [weak self] note in
            let info = note.userInfo as? [String: String] ?? [:]
            Task { @MainActor in await self?.handleRemote(info) }
        }
    }

    private func replyRemote(_ id: String, _ kind: String, _ message: String = "", log: String = "") {
        DistributedNotificationCenter.default().postNotificationName(
            RemoteDeploy.reply, object: nil,
            userInfo: ["id": id, "kind": kind, "message": message, "log": log],
            deliverImmediately: true)
    }

    private func handleRemote(_ info: [String: String]) async {
        let id = info["id"] ?? ""
        switch info["kind"] {
        case "ping":
            replyRemote(id, "pong", job?.running == true ? "배포 중: \(job!.title)" : "")
        case "ready":
            replyRemote(id, "list", readyList())
        case "deploy":
            await remoteDeploy(id, info)
        default:
            replyRemote(id, "rejected", "모르는 요청입니다: \(info["kind"] ?? "-")")
        }
    }

    /// 지금 배포할 수 있는 앱과, 막힌 앱의 이유 한 줄 — 폰에서 "뭐 배포할 수 있어?" 의 답.
    private func readyList() -> String {
        var ready: [String] = [], review: [String] = [], blocked: [String] = []
        for st in statuses {
            if st.deployable { ready.append("🟢 \(st.name) — \(st.readiness.headline)") }
            else if st.inReview { review.append("🟣 \(st.name) — \(st.reviewLabel ?? "심사 중") v\(st.reviewVersion ?? "?")") }
            else if st.state == .ready || st.state == .dev, !st.readiness.blockers.isEmpty {
                blocked.append("🟠 \(st.name) — \(st.readiness.headline)")
            }
        }
        var out = ready.isEmpty ? ["배포할 수 있는 앱이 없습니다"] : ["배포 가능 \(ready.count)개"] + ready
        if !review.isEmpty { out += ["", "심사 중 \(review.count)개"] + review }
        if !blocked.isEmpty { out += ["", "변경은 있지만 막힘 \(blocked.count)개"] + blocked }
        if job?.running == true { out += ["", "⏳ 지금 배포 중: \(job!.title)"] }
        return out.joined(separator: "\n")
    }

    private func remoteDeploy(_ id: String, _ info: [String: String]) async {
        let want = (info["app"] ?? "").precomposedStringWithCanonicalMapping
        // 이름이 정확히 같은 앱이 먼저 — '클립키보드' 가 '탭클립키보드' 에, 'StickyPresenter' 가 리모컨에 걸리지 않게
        let names = statuses.map { ($0, $0.name.precomposedStringWithCanonicalMapping) }
        let hits = names.filter { $0.1 == want }.map(\.0)
        let candidates = hits.isEmpty ? names.filter { $0.1.localizedCaseInsensitiveContains(want) }.map(\.0) : hits
        guard !want.isEmpty, candidates.count == 1, let found = candidates.first,
              let app = app(named: found.path) else {
            let msg = candidates.count > 1
                ? "'\(want)' 에 맞는 앱이 여럿입니다: \(candidates.map(\.name).joined(separator: ", ")) — 정확한 이름으로 다시"
                : "'\(want)' 앱을 찾지 못했습니다 — `--ready` 로 목록을 보세요"
            return replyRemote(id, "rejected", msg)
        }
        if job?.running == true {
            return replyRemote(id, "rejected", "다른 작업이 도는 중입니다: \(job!.title) — 끝난 뒤 다시")
        }
        let lane = Deployer.Lane(rawValue: info["lane"] ?? "") ?? .appstore
        let bump: Deployer.VersionBump? = switch info["bump"] {
            case "patch": .patch
            case "minor": .minor
            case "major": .major
            default: nil
        }

        // 카드에 남은 값은 몇 분 전 것일 수 있다 — 누르기 직전에 이 앱만 다시 본다 (pull 은 배포가 한다)
        await refreshApp(app.path, fresh: true, pull: false)
        guard let st = statuses.first(where: { $0.path == app.path }) else {
            return replyRemote(id, "rejected", "\(app.name) 상태를 읽지 못했습니다")
        }
        if lane == .appstore {
            if st.inReview {
                return replyRemote(id, "rejected",
                    "\(st.name) v\(st.reviewVersion ?? "?") 는 \(st.reviewLabel ?? "심사 중") 입니다 — 지금 올리면 그 심사가 취소됩니다. 급하면 창에서 [심사 취소하고 다시 배포]")
            }
            // 버튼과 같은 규칙: 막힌 게 있으면 안 된다. 단 '올릴 변경 없음' 하나뿐이고 버전을 올리라고 했으면
            // 그건 [버전 올리기] 를 누른 것과 같다 — 버전을 올리는 것 자체가 올릴 것이다.
            let blockers = st.readiness.blockers.filter { !(bump != nil && $0.key == "changes") }
            if !blockers.isEmpty {
                let why = blockers.map { "\($0.title)\($0.remedyShort.map { " → \($0)" } ?? "")" }
                return replyRemote(id, "rejected", "\(st.name) 배포가 막혀 있습니다:\n" + why.map { "  · \($0)" }.joined(separator: "\n"))
            }
            if !st.deployable && bump == nil {
                return replyRemote(id, "rejected", "\(st.name) — \(st.readiness.headline)")
            }
        }

        startDeploy(app, lane: lane, versionBump: bump) { [weak self] job in
            self?.replyRemote(id, "done", job.verdict?.line ?? "끝 — 판정 없음", log: job.logFile?.path ?? "")
        }
        replyRemote(id, "accepted", "\(app.name) \(laneLabel(lane)) 배포를 시작했습니다\(bump.map { " (버전 올리기: \($0))" } ?? "")",
                    log: job?.logFile?.path ?? "")
    }
}
