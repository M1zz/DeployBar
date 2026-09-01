import SwiftUI

// 상단 요약 칩이 곧 필터다 — 세는 기준과 거르는 기준이 갈라지지 않게 한 곳에 둔다.
enum AppFilter: String, CaseIterable, Identifiable {
    case ready, review, blocked, done, fixable
    var id: String { rawValue }

    var label: String {
        switch self {
        case .ready: return "배포 가능"
        case .review: return "심사 중"
        case .blocked: return "막힘"
        case .done: return "배포됨"
        case .fixable: return "설정 필요"
        }
    }
    var color: Color {
        switch self {
        // 상태 하나에 색 하나. 같은 뜻이 두 색으로 갈리면 화면을 못 믿게 된다.
        //   초록 = 지금 배포 가능 · 보라 = 심사 중 · 주황 = 잠김 · 회색 = 배포됨 · 파랑 = 설정하면 되는 것
        case .ready: return .green
        case .review: return .purple
        case .blocked: return .orange
        case .done: return .gray      // .secondary 는 반투명이라 '색이 없는' 것처럼 보였다
        case .fixable: return .blue
        }
    }
    /// 비었을 때 보여 줄 안내
    var emptyNote: String {
        switch self {
        case .ready: return "지금 바로 배포할 수 있는 앱이 없습니다."
        case .review: return "심사에 낸 앱이 없습니다."
        case .blocked: return "막힌 앱이 없습니다 — 다 풀렸습니다."
        case .done: return "스토어와 같은 버전인 앱이 없습니다."
        case .fixable: return "[자동 설정] 으로 정리할 앱이 없습니다."
        }
    }

    func matches(_ st: AppStatus) -> Bool {
        switch self {
        // 심사 중인 앱은 '배포 가능' 이 아니다 — 지금 올리면 그 심사가 취소된다
        case .ready:   return st.deployable
        case .review:  return st.inReview
        // 이미 스토어에 올라갔거나 심사 중인 앱은 '막힘' 이 아니다 — 할 일이 남은 앱만
        case .blocked: return st.state != .deployed && !st.inReview && !st.readiness.blockers.isEmpty
        case .done:    return st.state == .deployed
        case .fixable: return st.readiness.autoFixable
        }
    }
}
