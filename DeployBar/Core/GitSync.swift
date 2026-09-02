import Foundation

// 새로고침 때 원격을 한 번 훑는 단계.
//
// 왜 필요한가: 지금까지 DeployBar 는 fetch 를 한 번도 하지 않았다.
// ahead/behind 는 `@{u}` — 마지막으로 fetch 한 시점의 원격 — 를 기준으로 세므로,
// 다른 Mac 이나 동료가 올린 커밋이 아무리 쌓여도 화면은 "원격과 동기화됨" 이라고 말했다.
// 그 사이 다른 곳에서 배포가 나갔으면 '로컬이 스토어보다 낮음' 으로 막힌 채,
// 사람이 터미널에 가서 git pull 을 해 봐야만 풀리는 문제가 된다.
//
// 그래서 조회할 때마다 fetch 는 하고(작업 파일을 건드리지 않는 읽기), pull 은 골라서 한다.
// pull 대상은 **되감기가 없는 경우뿐**이다: 저장 안 된 변경이 없고, 원격보다 뒤처지기만 한 저장소.
// 갈라졌거나 더러운 저장소는 손대지 않고 체크리스트에 할 일로 남긴다 —
// 사람이 편집 중인 파일을 새로고침 한 번이 바꿔 놓는 일은 없어야 한다.
enum GitSync {
    struct Result {
        var fetchError: String?
        var attemptedPull = false  // 받아오기를 시도한 조회인가 (수동 새로고침만 true)
        var pulled: Int = 0        // 이번에 받아온 커밋 수 (0 이면 받을 게 없었거나 pull 을 안 함)
        var pullError: String?
        var skipped: String?       // 시도했지만 건너뛴 이유
    }

    /// 한 번에 붙잡을 저장소 수. 하나가 응답이 없어도 20초 뒤 끊기지만,
    /// 앱이 열 개면 그동안 조회가 멈춰 보이지 않도록 몇 개씩 겹쳐 돈다.
    private static let batchSize = 4

    static func run(_ apps: [ManagedApp], pull: Bool) async -> [String: Result] {
        let repos = apps.filter { GitInfo.isRepo($0.path) && GitInfo.upstream($0.path) != nil }
        guard !repos.isEmpty else { return [:] }

        var out: [String: Result] = [:]
        for chunk in stride(from: 0, to: repos.count, by: batchSize).map({
            Array(repos[$0..<min($0 + batchSize, repos.count)])
        }) {
            await withTaskGroup(of: (String, Result).self) { group in
                for app in chunk {
                    let path = app.path
                    group.addTask(priority: .utility) { (path, sync(path, pull: pull)) }
                }
                for await (path, r) in group { out[path] = r }
            }
        }
        return out
    }

    private static func sync(_ path: String, pull: Bool) -> Result {
        var r = Result()
        r.attemptedPull = pull
        if let e = GitInfo.fetch(path) { r.fetchError = e; return r }
        guard pull else { return r }
        // fetch 뒤라야 뒤처진 커밋 수가 진짜 값이다
        guard let ab = GitInfo.aheadBehind(path), ab.behind > 0 else { return r }
        if GitInfo.isDirty(path) { r.skipped = "저장 안 된 변경이 있어 받아오지 않았습니다"; return r }
        if ab.ahead > 0 { r.skipped = "원격과 갈라져 있어 받아오지 않았습니다"; return r }
        if let e = GitInfo.pullFFOnly(path) { r.pullError = e; return r }
        r.pulled = ab.behind
        return r
    }
}
