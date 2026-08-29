import Foundation

// "지금 이 앱을 배포하려면 뭐가 필요한가" 를 한 줄씩 답한다.
//
// Scaffold.doctor 가 "설정이 규칙에 맞나"(개발자 관점)라면,
// 이쪽은 "지금 배포 버튼을 누르면 되나, 안 되면 내가 뭘 해야 하나"(사용자 관점)다.
// 그래서 항목마다 ① 막는지 ② 자동으로 고칠 수 있는지 ③ 사람이 뭘 해야 하는지가 붙는다.
enum Fix: String, Codable {
    case configure   // deploy.env / predeploy.sh 자동 생성·정정
    case bumpPatch   // 마케팅 버전 +0.0.1
    case openNotes   // 릴리즈노트 창 열기

    var label: String {
        switch self {
        case .configure: return "자동 설정"
        case .bumpPatch: return "버전 올리기"
        case .openNotes: return "릴리즈노트"
        }
    }
}

struct ReadyItem: Codable, Identifiable, Hashable {
    enum Level: String, Codable { case ok, need, blocked }

    var key: String
    var level: Level
    var title: String
    var detail: String
    var fix: Fix? = nil          // 버튼 한 번으로 해결되는 것
    var todo: String? = nil      // 사람이 직접 해야 하는 것

    var id: String { key }
    var icon: String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .need: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }
}

struct Readiness: Codable, Hashable {
    var items: [ReadyItem] = []

    var blockers: [ReadyItem] { items.filter { $0.level == .blocked } }
    var needs: [ReadyItem] { items.filter { $0.level == .need } }
    var canDeploy: Bool { blockers.isEmpty }
    var autoFixable: Bool { items.contains { $0.fix == .configure } }

    /// 카드에 한 줄로 보여 줄 요약 — 지금 당장 할 일.
    var headline: String {
        if let b = blockers.first {
            return blockers.count > 1 ? "\(b.title) 외 \(blockers.count - 1)건 해결 필요" : "\(b.title) 해결 필요"
        }
        if needs.isEmpty { return "바로 배포 가능" }
        // 심사 대기 중 재업로드는 심사를 되돌리므로, 개수보다 이 사실을 먼저 말한다
        if let review = needs.first(where: { $0.key == "review" }) {
            return needs.count > 1 ? "\(review.title) · 권장 \(needs.count - 1)건 더" : review.title
        }
        return "배포 가능 · 권장 \(needs.count)건"
    }

    // ── 판정 ────────────────────────────────────────────────────────────
    static func evaluate(_ app: ManagedApp, status: AppStatus) -> Readiness {
        var out: [ReadyItem] = []
        let r = AppRepo.resolve(app)
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: app.path)

        // 1) 프로젝트 — 없으면 나머지를 볼 필요도 없다
        guard r.exists else {
            return Readiness(items: [ReadyItem(
                key: "project", level: .blocked, title: "Xcode 프로젝트 없음",
                detail: "앱 폴더 최상단에 .xcodeproj / .xcworkspace 가 있어야 합니다",
                todo: "프로젝트를 앱 폴더 최상단으로 옮기세요")])
        }
        if let e = status.error {
            out.append(ReadyItem(key: "settings", level: .blocked, title: "빌드 설정 조회 실패",
                                 detail: e,
                                 fix: fm.fileExists(atPath: dir.appendingPathComponent("deploy.env").path) ? nil : .configure,
                                 todo: "deploy.env 의 SCHEME 이 맞는지 확인하세요"))
            return Readiness(items: out)
        }

        // 2) App Store 등록 — 여기서 막히면 업로드 자체가 안 된다
        if let e = status.ascError {
            out.append(ReadyItem(
                key: "asc", level: .blocked, title: "App Store 앱 확인 실패",
                detail: "\(e)\(status.bundleId.map { " · \($0)" } ?? "")",
                todo: "App Store Connect 에 이 번들 ID 로 앱이 등록돼 있는지 확인하세요"))
        }

        // 3) 커밋 — 작업 중인 코드가 섞여 배포되는 사고를 막는다
        if status.dirty {
            out.append(ReadyItem(
                key: "git", level: .blocked, title: "커밋되지 않은 변경",
                detail: "브랜치 \(status.branch ?? "-") 에 저장 안 된 변경이 있습니다",
                todo: "변경사항을 커밋한 뒤 배포하세요"))
        }

        // 4) 올릴 것이 있는가
        if !status.dirty && status.state == .deployed {
            let behind = Status.cmpVer(status.localVersion, status.liveVersion) < 0
            out.append(behind
                ? ReadyItem(
                    key: "changes", level: .blocked, title: "로컬이 스토어보다 낮음",
                    detail: "로컬 v\(status.localVersion ?? "?") · 스토어 v\(status.liveVersion ?? "?")",
                    todo: "git pull 로 최신 코드를 받으세요 (다른 곳에서 배포된 버전일 수 있습니다)")
                : ReadyItem(
                    key: "changes", level: .blocked, title: "올릴 변경 없음",
                    detail: "로컬 v\(status.localVersion ?? "?") 이 이미 스토어에 있습니다",
                    fix: .bumpPatch, todo: "새 커밋을 하거나 버전을 올리세요"))
        } else if status.commitsSinceDeploy > 0 {
            out.append(ReadyItem(
                key: "changes", level: .ok, title: "올릴 변경 있음",
                detail: "마지막 배포 이후 커밋 \(status.commitsSinceDeploy)개"))
        } else if status.state == .ready {
            out.append(ReadyItem(
                key: "changes", level: .ok, title: "올릴 변경 있음",
                detail: "로컬 v\(status.localVersion ?? "?") · 스토어 \(status.liveVersion.map { "v\($0)" } ?? "미등록")"))
        }

        // 5) 버전 소스 — 여기가 틀리면 배포가 '빌드번호 설정' 단계에서 죽는다
        if let xc = r.versionXcconfig, !fm.fileExists(atPath: dir.appendingPathComponent(xc).path) {
            let real = Scaffold.findVersionXcconfig(app.path)
            out.append(ReadyItem(
                key: "version", level: .blocked, title: "버전 파일 경로 오류",
                detail: "VERSION_XCCONFIG=\(xc) 가 없습니다\(real.map { " (실제: \($0))" } ?? "")",
                fix: real != nil ? .configure : nil,
                todo: real == nil ? "Version.xcconfig 위치를 deploy.env 에 맞게 고치세요" : nil))
        }

        // 6) 다국어 — 게이트가 strict 면 배포를 막고, 아니면 권장 사항
        let gate = Localization.Mode(r.localizationGate)
        if gate != .off {
            let report = Localization.scan(app.path, expected: r.locales)
            if report.scanned {
                if report.ok {
                    out.append(ReadyItem(
                        key: "i18n", level: .ok, title: "다국어 준비됨",
                        detail: "\(report.locales.count)개 언어 · 번역 구멍 없음"))
                } else {
                    let head = report.byLocale.prefix(3).map { "\(Locales.displayName($0.locale)) \($0.count)" }.joined(separator: ", ")
                    out.append(ReadyItem(
                        key: "i18n", level: gate == .strict ? .blocked : .need,
                        title: "번역 구멍 \(report.issues.count)건",
                        detail: head + (report.byLocale.count > 3 ? " 외" : ""),
                        todo: "Xcode 에서 String Catalog 를 열어 빈 번역을 채우세요"))
                }
            }
        }

        // 7) 배포 설정 — 없어도 배포는 되지만, 있으면 사고가 줄어든다
        let hasEnv = fm.fileExists(atPath: dir.appendingPathComponent("deploy.env").path)
            || fm.fileExists(atPath: dir.appendingPathComponent("fastlane/.env").path)
        if !hasEnv {
            out.append(ReadyItem(
                key: "env", level: .need, title: "배포 설정 없음",
                detail: "scheme 을 폴더 이름(\(r.scheme))으로 추정하고 있습니다",
                fix: .configure))
        }
        let hasGate = r.predeploy.map { fm.fileExists(atPath: dir.appendingPathComponent($0).path) } ?? false
        if !hasGate {
            out.append(ReadyItem(
                key: "gate", level: .need, title: "배포 전 검사 없음",
                detail: r.predeploy == nil ? "테스트를 돌리지 않고 배포합니다"
                                           : "PREDEPLOY_SCRIPT=\(r.predeploy!) 파일이 없습니다",
                fix: .configure))
        }

        // 8) 다국어 앱인데 LOCALES 를 안 적었으면 릴리즈노트 언어를 짐작하게 된다
        if r.locales.isEmpty {
            let found = Localization.scan(app.path).locales
            if found.count > 1 {
                out.append(ReadyItem(
                    key: "locales", level: .need, title: "언어 목록 미선언",
                    detail: "\(found.joined(separator: ", ")) 를 자동 인식 중 — deploy.env 에 적어 두면 확실합니다",
                    fix: .configure))
            }
        }

        // 9) 심사 진행 중 — 배포는 되지만 알고 눌러야 한다
        if let label = status.reviewLabel, let v = status.reviewVersion {
            let waiting = ["WAITING_FOR_REVIEW", "IN_REVIEW"].contains(status.reviewState ?? "")
            out.append(ReadyItem(
                key: "review", level: waiting ? .need : .ok, title: "App Store \(label)",
                detail: "v\(v)\(waiting ? " — 지금 올리면 심사가 취소되고 새 빌드로 다시 시작합니다" : "")"))
        }

        return Readiness(items: out)
    }
}
