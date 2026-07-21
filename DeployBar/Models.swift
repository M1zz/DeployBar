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
    case dev, ready, deployed, error
    var label: String {
        switch self {
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
}
