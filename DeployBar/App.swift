import SwiftUI

@main
struct DeployBarApp: App {
    @StateObject private var store = Store()

    init() {
        CLI.runIfRequested()

        // 최초 실행 시 apps.json / 설정 파일이 존재하도록 시드
        _ = AppRepo.registry()
        // 배포 성공·실패 알림 권한 요청
        Notifier.requestAuth()
    }

    var body: some Scene {
        // 실행 시 뜨는 메인 창 (노치에 가린 메뉴바 아이콘을 못 찾아도 항상 보임).
        // WindowGroup 은 MenuBarExtra 가 있어도 실행 시 창을 자동으로 연다.
        WindowGroup("배포 콘솔", id: "dashboard") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 460, minHeight: 420)
        }
        .defaultSize(width: 460, height: 600)
        .windowResizability(.contentMinSize)

        // 메뉴바는 창의 복사본이 아니다 — "지금 뭐가 돌고 있고 내가 누를 게 있나" 만 답한다.
        // 고르고 읽고 고치는 일은 전부 창(ContentView)의 몫이다.
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            // 앱 아이콘과 같은 도형에서 뽑은 템플릿 이미지 (scripts/make_icon.swift).
            // 템플릿이라 밝은/어두운 메뉴바에 맞춰 macOS 가 알아서 칠한다.
            // 옆의 숫자가 상태다 — 배포 중이면 진행 칸, 아니면 지금 올릴 수 있는 앱 수.
            MenuBarLabel(store: store)
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

        Window("사용법", id: "guide") {
            GuideView().environmentObject(store)
        }
        .defaultSize(width: 560, height: 640)
    }
}
