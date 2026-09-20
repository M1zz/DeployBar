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
        case .attachBuild:
            Task { await attachBuild(app) }
        case .publishStore:
            publishStore(app)
        case .shotPrompt:
            // 지시문을 만들려면 시뮬레이터 목록·git 로그를 훑어야 한다.
            // 누른 자리에서 그러면 창이 잠깐 얼어붙으므로 밖에서 만들어 온다.
            let status = statuses.first { $0.path == app.path }
            fixing.insert(app.path)
            Task.detached {
                let text = ShotPrompt.text(for: app, status: status, kind: .shots)
                await MainActor.run {
                    Clipboard.copy(text)
                    self.fixing.remove(app.path)
                    self.fixResult[app.path] = "스크린샷 지시문을 복사했습니다 — Claude Code 에 붙여넣으세요"
                }
            }
        }
    }

    /// 이 고치기가 진행 중이라 스피너를 보여 줄지
    func isApplying(_ fix: Fix, _ path: String) -> Bool {
        [.configure, .ignoreNoise, .shotPrompt, .attachBuild].contains(fix) && fixing.contains(path)
    }
}
