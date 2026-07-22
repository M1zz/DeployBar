import Foundation

// apps.json 의 레지스트리 항목 (이름/경로만; 나머지는 자동 해석)
struct ManagedApp: Codable, Identifiable, Hashable {
    var name: String
    var path: String
    var id: String { path }
}

// 프로젝트에서 해석한 배포 설정
struct ResolvedApp {
    var name: String
    var path: String
    var projFlag: String        // "-project" | "-workspace"
    var projContainer: String   // .xcodeproj/.xcworkspace 전체 경로
    var scheme: String
    var versionXcconfig: String?
    var predeploy: String?
    var exists: Bool
}

struct BuildInfo {
    var bundleId: String
    var marketingVersion: String
    var buildNumber: String
    var team: String?
}

enum DeployState: String, Codable {
    case loading, dev, ready, deployed, error
    var label: String {
        switch self {
        case .loading: return "조회 중…"
        case .dev: return "개발 중"
        case .ready: return "배포 준비완료"
        case .deployed: return "배포 완료"
        case .error: return "오류"
        }
    }
}

struct AppStatus: Identifiable, Codable {
    var name: String
    var path: String
    var id: String { path }
    var state: DeployState
    var bundleId: String?
    var team: String?
    var localVersion: String?
    var localBuild: String?
    var liveVersion: String?
    var liveState: String?
    var ascBuild: String?
    var ascError: String?
    var dirty: Bool = false
    var branch: String?
    var error: String?
    // 마지막 배포 태그(deploy-*) 이후 HEAD 까지의 새 커밋 수 (같은 버전 재배포 신호)
    var commitsSinceDeploy: Int = 0
    // 심사 파이프라인 상태 (READY_FOR_SALE 이 아닌 진행 중 버전)
    var reviewState: String?
    var reviewVersion: String?

    var reviewLabel: String? {
        guard let s = reviewState else { return nil }
        return ASCState.label(s)
    }
}

// App Store Connect appStoreState → 한국어 라벨
enum ASCState {
    static func label(_ state: String) -> String? {
        switch state {
        case "PREPARE_FOR_SUBMISSION": return "제출 준비"
        case "WAITING_FOR_REVIEW": return "심사 대기"
        case "IN_REVIEW": return "심사 중"
        case "PENDING_DEVELOPER_RELEASE": return "출시 대기"
        case "PENDING_APPLE_RELEASE": return "출시 대기"
        case "PROCESSING_FOR_APP_STORE": return "처리 중"
        case "REJECTED", "METADATA_REJECTED": return "거부됨"
        case "DEVELOPER_REJECTED": return "개발자 취소"
        case "INVALID_BINARY": return "바이너리 오류"
        case "READY_FOR_SALE": return "판매 중"
        default: return nil
        }
    }
    // 진행 중(파이프라인) 상태인지
    static func isInflight(_ state: String) -> Bool {
        ["PREPARE_FOR_SUBMISSION", "WAITING_FOR_REVIEW", "IN_REVIEW",
         "PENDING_DEVELOPER_RELEASE", "PENDING_APPLE_RELEASE", "PROCESSING_FOR_APP_STORE",
         "REJECTED", "METADATA_REJECTED", "DEVELOPER_REJECTED", "INVALID_BINARY"].contains(state)
    }
}
