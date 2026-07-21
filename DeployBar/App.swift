import SwiftUI

@main
struct DeployBarApp: App {
    @StateObject private var store = Store()

    init() {
        // 헤드리스 상태 조회 (테스트/CLI 용): DeployBar --status
        if CommandLine.arguments.contains("--status") {
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                let all = await Status.all()
                for s in all {
                    let local = "v\(s.localVersion ?? "?")/\(s.localBuild ?? "?")"
                    let live = s.liveVersion.map { "v\($0)" } ?? "—"
                    print("\(s.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.state.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) local:\(local)  live:\(live)  \(s.error ?? s.ascError ?? "")")
                }
                sem.signal()
            }
            sem.wait()
            exit(0)
        }
        // 최초 실행 시 apps.json / 설정 파일이 존재하도록 시드
        _ = AppRepo.registry()
    }

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(store)
        } label: {
            Image(systemName: "arrow.up.circle.fill")
        }
        .menuBarExtraStyle(.window)

        Window("배포 로그", id: "log") {
            LogView().environmentObject(store)
        }
        .defaultSize(width: 660, height: 440)

        Window("릴리즈노트", id: "notes") {
            NotesView().environmentObject(store)
        }
        .defaultSize(width: 560, height: 560)
    }
}
