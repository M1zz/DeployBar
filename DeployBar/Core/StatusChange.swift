import Foundation

// 지난번 조회와 이번 조회를 견줘 "알릴 만한 변화" 를 뽑는다.
//
// 배포를 눌렀을 때만 알림이 오면, 정작 기다리는 소식 — 심사가 끝났는지, 거부됐는지,
// 드디어 스토어에 올라갔는지 — 은 사람이 앱을 열어 봐야 안다.
// 그건 앱이 이미 알고 있는 사실이므로, 알아낸 순간에 말해 준다.
enum StatusChange {
    /// 변화의 성격 — 배너 색을 여기서만 정한다
    enum Kind: String, Codable { case good, warn, info }

    struct Event: Identifiable, Codable {
        var id = UUID()
        var title: String
        var body: String
        var kind: Kind = .info
        /// 놓치면 곤란한 것 (거부됨 등)
        var important: Bool = false
        var at = Date()
    }

    /// 변화 하나를 알림 문구로. 알릴 게 없으면 nil.
    static func event(from old: AppStatus, to new: AppStatus) -> Event? {
        // 처음 보는 앱이거나 아직 조회 전이면 비교할 과거가 없다 — 첫 실행에 알림이 쏟아지지 않게.
        guard old.state != .loading, old.bundleId != nil else { return nil }

        // 1) 스토어에 새 버전이 나갔다 — 가장 반가운 소식
        if let live = new.liveVersion, live != old.liveVersion, old.liveVersion != nil,
           Status.cmpVer(live, old.liveVersion) > 0 {
            return Event(title: "\(new.name) v\(live) 출시됨",
                         body: "App Store 에서 판매 중입니다", kind: .good, important: true)
        }

        // 2) 심사 상태가 바뀌었다
        if new.reviewState != old.reviewState {
            let was = old.reviewLabel
            switch new.reviewState {
            case "IN_REVIEW":
                return Event(title: "\(new.name) 심사 시작",
                             body: "v\(new.reviewVersion ?? "?") 를 애플이 보기 시작했습니다", kind: .info)
            case "PENDING_DEVELOPER_RELEASE":
                return Event(title: "\(new.name) 심사 통과",
                             body: "v\(new.reviewVersion ?? "?") — App Store Connect 에서 '출시' 를 누르면 나갑니다",
                             kind: .good, important: true)
            case "REJECTED", "METADATA_REJECTED", "INVALID_BINARY":
                return Event(title: "\(new.name) 거부됨",
                             body: "v\(new.reviewVersion ?? "?") — App Store Connect 에서 사유를 확인하세요",
                             kind: .warn, important: true)
            case "WAITING_FOR_REVIEW":
                return Event(title: "\(new.name) 심사 대기",
                             body: "v\(new.reviewVersion ?? "?") 제출됨 — 결과를 기다립니다", kind: .info)
            case nil where was != nil:
                return nil   // 진행 중 버전이 사라진 것 — 1) 의 출시 알림이 이미 말했다
            default:
                return nil
            }
        }

        // 3) 막혀 있던 앱이 풀렸다 — 고치라고 알려 준 쪽에서 다 됐다고도 말해야 한다
        if new.deployable && !old.deployable && !old.readiness.blockers.isEmpty {
            return Event(title: "\(new.name) 배포 가능",
                         body: "\(old.readiness.blockers.first?.title ?? "막힌 것")이 해결됐습니다", kind: .good)
        }

        return nil
    }

    /// 목록 전체를 견준다. 경로가 같은 앱끼리만 비교한다(폴더 이름은 바뀔 수 있다).
    static func events(from old: [AppStatus], to new: [AppStatus]) -> [Event] {
        let byPath = Dictionary(old.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        return new.compactMap { n in byPath[n.path].flatMap { event(from: $0, to: n) } }
    }
}
