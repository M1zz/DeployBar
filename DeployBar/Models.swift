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
    // 이 앱이 지원하는 App Store 언어 (deploy.env 의 LOCALES). 비면 .xcstrings/ASC 에서 자동 판단.
    var locales: [String] = []
    // 다국어 게이트 강도 (deploy.env 의 LOCALIZATION_GATE): strict 는 번역 구멍이 있으면 배포 중단
    var localizationGate: String = "warn"
    // 플랫폼 강제 지정 (deploy.env 의 PLATFORM=ios|macos). 자동 판별이 틀릴 때만 쓴다.
    var platformOverride: String?
}

// 배포 대상 플랫폼 — archive destination·altool 타입·export 산출물이 다르다.
enum Platform: String {
    case iOS, macOS
    var destination: String { self == .macOS ? "generic/platform=macOS" : "generic/platform=iOS" }
    var altoolType: String { self == .macOS ? "macos" : "ios" }   // xcrun altool -t
    var exportExt: String { self == .macOS ? "pkg" : "ipa" }      // export 산출물 확장자
}

struct BuildInfo {
    var bundleId: String
    var marketingVersion: String
    var buildNumber: String
    var team: String?
    var platform: Platform = .iOS
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
    // "지금 배포하려면 뭐가 필요한가" — 카드에서 바로 보여 주는 체크리스트
    var readiness: Readiness = Readiness()

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
