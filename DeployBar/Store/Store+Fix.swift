import AppKit

// 체크리스트·실패 패널의 [자동 설정]·[버전 올리기] 같은 '한 번에 되는 것' 을 실행한다.
// 예전엔 이 switch 가 카드와 로그 창에 하나씩 있었다. 새 Fix 를 더할 때
// 한쪽만 고치면 다른 쪽에서 조용히 아무 일도 안 일어나므로 한곳으로 모은다.
extension Store {
    func apply(_ fix: Fix, to app: ManagedApp) {
        switch fix {
        case .configure:
            Task { await autoConfigure(app) }
        case .bumpPatch:
            Task { await bumpVersion(app, .patch) }
        case .ignoreNoise:
            Task { await ignoreXcodeNoise(app) }
        case .openNotes:
            openNotesSignal += 1
            Task { await loadNotes(app) }
        case .reveal:
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.path)
        }
    }

    /// 이 고치기가 진행 중이라 스피너를 보여 줄지
    func isApplying(_ fix: Fix, _ path: String) -> Bool {
        (fix == .configure || fix == .ignoreNoise) && fixing.contains(path)
    }
}
