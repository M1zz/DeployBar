import Foundation

/// Xcode 에서 ⌘R 로 띄운 DeployBar 는 /Applications 의 것에게 자리를 넘기고 물러난다.
///
/// 스킴의 빌드 후 단계가 방금 만든 빌드를 /Applications 에 설치하고 띄운다(project.yml).
/// 여기서 DerivedData 사본까지 남으면 같은 앱이 둘 떠서, 명령줄(--deploy)이 어느 쪽에 붙을지 알 수 없다.
/// 그래서 /Applications 사본이 이 빌드보다 새것이거나 같으면 그쪽을 띄우고 끝낸다.
/// 배포 중이라 설치를 건너뛰었으면(/Applications 가 더 옛것) 그대로 남는다 — 그때는 창 위 띠가 경고한다.
/// 디버거로 붙어 있어야 할 때는 스킴의 환경 변수에 DEPLOYBAR_STAY=1 을 넣는다.
enum DevHandoff {
    static func runIfNeeded() {
        guard RunLog.isDevBuild, ProcessInfo.processInfo.environment["DEPLOYBAR_STAY"] == nil else { return }
        let installed = "/Applications/DeployBar.app"
        func built(_ path: String?) -> Date? {
            guard let path else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        guard let mine = built(Bundle.main.executablePath),
              let theirs = built("\(installed)/Contents/MacOS/DeployBar"),
              theirs >= mine.addingTimeInterval(-1) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = [installed]
        try? p.run()
        p.waitUntilExit()
        exit(0)
    }
}
