import Foundation

// "지금 이 앱을 배포하려면 뭐가 필요한가" 를 한 줄씩 답한다.
//
// Scaffold.doctor 가 "설정이 규칙에 맞나"(개발자 관점)라면,
// 이쪽은 "지금 배포 버튼을 누르면 되나, 안 되면 내가 뭘 해야 하나"(사용자 관점)다.
// 그래서 항목마다 ① 막는지 ② 자동으로 고칠 수 있는지 ③ 사람이 뭘 해야 하는지가 붙는다.
//
// 중요: 통과한 항목도 **빠짐없이 ✅ 로 남긴다.**
// "뭐가 잘못됐나" 만 보여 주면 아무것도 안 뜰 때 준비가 된 건지 검사를 안 한 건지 알 수 없다.
// 목록이 늘 같은 순서로 다 있어야 "6/8 준비됨" 처럼 진행도로 읽힌다.
enum Fix: String, Codable {
    case configure   // deploy.env / predeploy.sh 자동 생성·정정
    case bumpPatch   // 마케팅 버전 +0.0.1
    case openNotes   // 릴리즈노트 창 열기
    case reveal      // Finder 에서 앱 폴더 열기 (커밋하러 갈 때)
    case ignoreNoise // Xcode 가 만든 파일을 .gitignore 에 넣고 추적 해제 후 커밋

    var label: String {
        switch self {
        case .configure: return "자동 설정"
        case .bumpPatch: return "버전 올리기"
        case .openNotes: return "릴리즈노트"
        case .reveal: return "폴더 열기"
        case .ignoreNoise: return "정리하고 커밋"
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
    /// 이 항목만의 에이전트 지시문. key 별 기본 문구(agentHint)가 이 상황엔 틀릴 때 쓴다.
    var agent: String? = nil

    var id: String { key }
    var icon: String {
        switch level {
        case .ok: return "checkmark.circle.fill"
        case .need: return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        }
    }
    /// 이 항목이 배포를 막는가 — 화면에서 ❌ 로 강조할지 판단
    var isBlocker: Bool { level == .blocked }

    /// "그래서 뭘 하면 풀리나" 를 접힌 카드 한 줄에 들어갈 길이로.
    /// 문제 이름만 보여 주면 펼쳐 봐야 할 일을 알 수 있어서, 다음 동작까지 같이 말한다.
    var remedyShort: String? {
        // [폴더 열기] 는 문제를 고쳐 주는 게 아니라 고치러 가는 지름길이라 여기서 제외한다
        if let fix, fix != .reveal, fix != .openNotes { return "[\(fix.label)]" }
        switch key {
        case "git": return "커밋하면 풀림"
        case "changes": return "새 커밋 또는 git pull"
        case "remote": return "원격 커밋 받아오기"
        case "i18n": return "번역 채우면 풀림"
        case "asc": return "App Store Connect 확인"
        case "version": return "xcconfig 경로 확인"
        case "project": return "scheme 이름 확인"
        default: return nil
        }
    }
}

struct Readiness: Codable, Hashable {
    var items: [ReadyItem] = []

    var blockers: [ReadyItem] { items.filter { $0.level == .blocked } }
    var needs: [ReadyItem] { items.filter { $0.level == .need } }
    var passed: [ReadyItem] { items.filter { $0.level == .ok } }
    var canDeploy: Bool { blockers.isEmpty }
    var autoFixable: Bool { items.contains { $0.fix == .configure } }

    /// 막는 것 → 권장 → 통과 순. 눈이 위에서부터 읽으면 할 일 순서가 된다.
    var sorted: [ReadyItem] {
        let rank: [ReadyItem.Level: Int] = [.blocked: 0, .need: 1, .ok: 2]
        return items.enumerated()
            .sorted { (rank[$0.element.level]!, $0.offset) < (rank[$1.element.level]!, $1.offset) }
            .map { $0.element }
    }

    /// "8개 중 6개 통과" — 준비가 어디까지 됐는지 숫자로.
    var passedCount: Int { passed.count }
    var total: Int { items.count }
    var progress: Double { total == 0 ? 0 : Double(passedCount) / Double(total) }

    /// 카드에 한 줄로 보여 줄 요약 — 지금 당장 할 일.
    var headline: String {
        if let b = blockers.first {
            let more = blockers.count > 1 ? " 외 \(blockers.count - 1)건" : ""
            // 문제 이름 + 다음에 누를 것. 펼치지 않아도 할 일이 보이게.
            return "\(b.title)\(more)\(b.remedyShort.map { " → \($0)" } ?? "")"
        }
        if needs.isEmpty { return "\(total)가지 모두 준비됨" }
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
        func has(_ rel: String) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(rel).path) }

        // 1) 프로젝트 — 없으면 나머지를 볼 필요도 없다
        guard r.exists else {
            return Readiness(items: [ReadyItem(
                key: "project", level: .blocked, title: "Xcode 프로젝트 없음",
                detail: "앱 폴더 최상단에 .xcodeproj / .xcworkspace 가 있어야 합니다",
                todo: "프로젝트를 앱 폴더 최상단으로 옮기세요")])
        }
        let container = (r.projContainer as NSString).lastPathComponent
        if let e = status.error {
            return Readiness(items: [
                ReadyItem(key: "project", level: .blocked, title: "빌드 설정 조회 실패",
                          detail: "\(container) · scheme \(r.scheme) — \(e)",
                          fix: has("deploy.env") ? nil : .configure,
                          todo: "deploy.env 의 SCHEME 이 실제 scheme 이름과 같은지 확인하세요")
            ])
        }
        let projects = AppRepo.ambiguousProjects(app.path)
        out.append(projects.count > 1
            ? ReadyItem(key: "project", level: .need, title: "Xcode 프로젝트가 \(projects.count)개",
                        detail: "\(projects.joined(separator: ", ")) — 지금은 \(container) 를 씁니다",
                        todo: "쓰지 않는 프로젝트를 하위 폴더로 옮기거나, deploy.env 의 SCHEME 으로 대상을 확실히 하세요")
            : ReadyItem(key: "project", level: .ok, title: "Xcode 프로젝트",
                        detail: "\(container) · scheme \(r.scheme)"))

        // 2) App Store 등록 — 여기서 막히면 업로드 자체가 안 된다
        if let e = status.ascError {
            out.append(ReadyItem(
                key: "asc", level: .blocked, title: "App Store 앱 확인 실패",
                detail: "\(e)\(status.bundleId.map { " · \($0)" } ?? "")",
                todo: "App Store Connect 에 이 번들 ID 로 앱이 등록돼 있는지 확인하세요"))
        } else {
            out.append(ReadyItem(
                key: "asc", level: .ok, title: "App Store 앱 확인됨",
                detail: "\(status.bundleId ?? "-") · \(status.liveVersion.map { "판매 중 v\($0)" } ?? "아직 출시 전")"))
        }

        // 3) 커밋 — 작업 중인 코드가 섞여 배포되는 사고를 막는다
        if !GitInfo.isRepo(app.path) {
            out.append(ReadyItem(
                key: "git", level: .need, title: "Git 저장소 아님",
                detail: "변경 이력이 없어 무엇이 배포되는지 확인할 수 없습니다",
                todo: "git init 후 커밋해 두면 배포 내역을 추적할 수 있습니다"))
        } else if status.dirty {
            let files = GitInfo.dirtyFiles(app.path)
            let noise = files.filter(GitInfo.isNoise)
            let real = files.filter { !GitInfo.isNoise($0) }
            let head = (real.isEmpty ? noise : real).prefix(3)
                .map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
            if real.isEmpty && !noise.isEmpty {
                // Xcode·macOS 가 만든 파일만 남아 막힌 경우 — 커밋할 게 아니라 무시해야 할 것들이다
                out.append(ReadyItem(
                    key: "git", level: .blocked, title: "Xcode 가 만든 파일 \(noise.count)개 때문에 막힘",
                    detail: "\(head)\(noise.count > 3 ? " 외" : "") — 사람이 고친 코드는 없습니다",
                    fix: .ignoreNoise,
                    todo: "[정리하고 커밋] 을 누르면 .gitignore 에 넣고 git 추적에서 빼 커밋합니다"))
            } else {
                out.append(ReadyItem(
                    key: "git", level: .blocked, title: "커밋되지 않은 변경 \(files.count)개",
                    detail: "\(head)\(real.count > 3 ? " 외" : "")"
                        + (noise.isEmpty ? "" : " · Xcode 가 만든 파일 \(noise.count)개 포함"),
                    fix: .reveal,
                    todo: "변경사항을 커밋한 뒤 배포하세요 (배포는 커밋된 코드만 올립니다)"))
            }
        } else {
            out.append(ReadyItem(
                key: "git", level: .ok, title: "커밋 완료",
                detail: "브랜치 \(status.branch ?? "-") · 저장 안 된 변경 없음"))
        }

        // 3.5) 원격과의 관계 — 갈라져 있으면 배포는 git pull 단계에서 반드시 실패한다.
        //      실패를 눌러 보고 알 이유가 없다. 여기서 미리 막는다.
        //
        //      새로고침이 먼저 fetch 를 하고, 앞당기기만 하면 되는 저장소는 받아온 뒤라,
        //      여기 남은 숫자는 "받아올 수 없어서 남은 것" 이다. 그래서 이유까지 같이 말한다.
        if let err = status.remoteError {
            out.append(ReadyItem(
                key: "remote", level: .need, title: "원격 확인 실패",
                detail: "\(err) — 아래 숫자는 마지막으로 성공한 조회 기준입니다",
                todo: "터미널에서 `git fetch` 를 한 번 실행해 자격증명·네트워크를 확인하세요"))
        } else if let ahead = status.ahead, let behind = status.behind {
            if ahead > 0 && behind > 0 {
                out.append(ReadyItem(
                    key: "remote", level: .blocked, title: "원격과 갈라짐",
                    detail: "내 커밋 \(ahead)개 · 원격 커밋 \(behind)개 — 배포 첫 단계(git pull)에서 멈춥니다",
                    todo: "터미널에서 `git pull --rebase` 로 합치거나, 내 커밋을 먼저 push 하세요"))
            } else if ahead > 0 {
                out.append(ReadyItem(
                    key: "remote", level: .need, title: "push 안 된 커밋 \(ahead)개",
                    detail: "배포는 되지만 이 Mac 에만 있는 코드가 나갑니다",
                    todo: "`git push` 로 원격에도 올려 두세요"))
            } else if behind > 0 {
                // 받아오기를 시도한 조회인데도 남아 있다면 = 못 받은 것 (저장 안 된 변경이 있는 경우).
                // 시도조차 안 한 자동 조회라면 아직 문제가 아니다 — 누르면 받아온다고만 말한다.
                if let why = status.pullSkipped {
                    out.append(ReadyItem(
                        key: "remote", level: .need, title: "원격에 새 커밋 \(behind)개 — 못 받음",
                        detail: why, fix: .reveal,
                        todo: "변경을 커밋하거나 치워 두고 다시 새로고침하면 자동으로 받아옵니다"))
                } else {
                    out.append(ReadyItem(
                        key: "remote", level: .ok, title: "원격에 새 커밋 \(behind)개",
                        detail: "[새로고침] 을 누르면 받아옵니다 · 배포를 시작할 때도 자동으로 받습니다"))
                }
            } else if status.pulledCommits > 0 {
                out.append(ReadyItem(
                    key: "remote", level: .ok, title: "최신 코드 받음 — 커밋 \(status.pulledCommits)개",
                    detail: "\(status.branch ?? "-") 를 방금 원격에 맞췄습니다"))
            } else {
                out.append(ReadyItem(
                    key: "remote", level: .ok, title: "원격과 동기화됨",
                    detail: "\(status.branch ?? "-") 가 원격과 같습니다"))
            }
        }

        // 4) 올릴 것이 있는가
        if !status.dirty && status.state == .deployed {
            let behind = Status.cmpVer(status.localVersion, status.liveVersion) < 0
            // 새로고침이 이미 받아올 수 있는 건 받아온 뒤다 — 그래도 낮다면 이유가 따로 있다.
            let pullBlocked = status.pullSkipped ?? status.remoteError
            out.append(behind
                ? ReadyItem(
                    key: "changes", level: .blocked, title: "로컬이 스토어보다 낮음",
                    detail: "로컬 v\(status.localVersion ?? "?") · 스토어 v\(status.liveVersion ?? "?")"
                        + (pullBlocked.map { " — \($0)" } ?? " (다른 곳에서 배포된 버전일 수 있습니다)"),
                    todo: pullBlocked == nil
                        ? "[새로고침] 을 누르면 원격의 최신 코드를 받아옵니다"
                        : "원격 코드를 받을 수 없는 상태입니다 — 위 [원격] 항목부터 푸세요")
                : ReadyItem(
                    key: "changes", level: .blocked, title: "올릴 변경 없음",
                    detail: "로컬 v\(status.localVersion ?? "?") 이 이미 스토어에 있습니다",
                    fix: .bumpPatch, todo: "새 커밋을 하거나 버전을 올리세요"))
        } else if status.commitsSinceDeploy > 0 {
            out.append(ReadyItem(
                key: "changes", level: .ok, title: "올릴 변경 있음",
                detail: "마지막 배포 이후 커밋 \(status.commitsSinceDeploy)개"))
        } else {
            out.append(ReadyItem(
                key: "changes", level: .ok, title: "올릴 변경 있음",
                detail: "로컬 v\(status.localVersion ?? "?")(\(status.localBuild ?? "?")) · 스토어 \(status.liveVersion.map { "v\($0)" } ?? "미등록")"))
        }

        // 5) 버전 소스 — 여기가 틀리면 배포가 '빌드번호 설정' 단계에서 죽는다
        let realXcconfig = Scaffold.findVersionXcconfig(app.path)
        if let xc = r.versionXcconfig {
            if has(xc) {
                out.append(ReadyItem(
                    key: "version", level: .ok, title: "버전 파일 확인됨",
                    detail: "\(xc) 에서 버전·빌드번호를 읽고 씁니다"))
            } else {
                out.append(ReadyItem(
                    key: "version", level: .blocked, title: "버전 파일 경로 오류",
                    detail: "VERSION_XCCONFIG=\(xc) 가 없습니다\(realXcconfig.map { " (실제: \($0))" } ?? "")",
                    fix: realXcconfig != nil ? .configure : nil,
                    todo: realXcconfig == nil ? "Version.xcconfig 위치를 deploy.env 에 맞게 고치세요" : nil))
            }
        } else {
            out.append(ReadyItem(
                key: "version", level: .need, title: "버전 파일 미지정",
                detail: realXcconfig.map { "\($0) 이 있는데 deploy.env 에 안 적혀 있습니다" }
                    ?? "project.pbxproj 를 직접 고쳐 버전을 올립니다 (타겟이 여러 개면 위험)",
                fix: .configure))
        }

        // 6) 다국어 — 게이트가 strict 면 배포를 막고, 아니면 권장 사항
        let gate = Localization.Mode(r.localizationGate)
        let report = Localization.scan(app.path, expected: r.locales)
        if gate == .off {
            out.append(ReadyItem(
                key: "i18n", level: .ok, title: "다국어 검사 꺼짐",
                detail: "LOCALIZATION_GATE=off — 번역 상태를 검사하지 않습니다"))
        } else if report.scanned {
            if report.ok {
                out.append(ReadyItem(
                    key: "i18n", level: .ok, title: "다국어 준비됨",
                    detail: "\(report.locales.count)개 언어 · 번역 구멍 없음"))
            } else {
                let head = report.byLocale.prefix(3).map { "\(Locales.displayName($0.locale)) \($0.count)" }.joined(separator: ", ")
                out.append(ReadyItem(
                    key: "i18n", level: gate == .strict ? .blocked : .need,
                    title: "번역 구멍 \(report.issues.count)건",
                    detail: head + (report.byLocale.count > 3 ? " 외" : "")
                        + (gate == .strict ? " — LOCALIZATION_GATE=strict 라 배포가 막힙니다" : " — 배포는 되지만 외국 사용자에게 한국어가 보입니다"),
                    todo: "Xcode 에서 String Catalog 를 열어 빈 번역을 채우세요"))
            }
        } else {
            out.append(ReadyItem(
                key: "i18n", level: .ok, title: "단일 언어 앱",
                detail: ".xcstrings 가 없어 다국어 검사를 건너뜁니다"))
        }

        // 7) 배포 설정 — 없어도 배포는 되지만, 있으면 사고가 줄어든다
        let envFile = has("deploy.env") ? "deploy.env" : (has("fastlane/.env") ? "fastlane/.env" : nil)
        if let f = envFile {
            out.append(ReadyItem(
                key: "env", level: .ok, title: "배포 설정 있음",
                detail: "\(f) · scheme \(r.scheme)"))
        } else {
            out.append(ReadyItem(
                key: "env", level: .need, title: "배포 설정 없음",
                detail: "deploy.env 가 없어 scheme 을 폴더 이름(\(r.scheme))으로 추정하고 있습니다",
                fix: .configure))
        }

        // 8) 배포 전 검사 — 테스트 없이 나가는 걸 막아 준다
        if let p = r.predeploy, has(p) {
            out.append(ReadyItem(
                key: "gate", level: .ok, title: "배포 전 검사 있음",
                detail: "\(p) 가 통과해야 아카이브를 만듭니다"))
        } else {
            out.append(ReadyItem(
                key: "gate", level: .need, title: "배포 전 검사 없음",
                detail: r.predeploy == nil ? "테스트를 돌리지 않고 배포합니다"
                                           : "PREDEPLOY_SCRIPT=\(r.predeploy!) 파일이 없습니다",
                fix: .configure))
        }

        // 9) 다국어 앱인데 LOCALES 를 안 적었으면 릴리즈노트 언어를 짐작하게 된다
        if !r.locales.isEmpty {
            out.append(ReadyItem(
                key: "locales", level: .ok, title: "언어 목록 선언됨",
                detail: "\(Locales.sorted(r.locales).map { Locales.displayName($0) }.joined(separator: ", ")) — 릴리즈노트를 이 언어로 만듭니다"))
        } else if report.locales.count > 1 {
            out.append(ReadyItem(
                key: "locales", level: .need, title: "언어 목록 미선언",
                detail: "\(report.locales.joined(separator: ", ")) 를 자동 인식 중 — deploy.env 에 적어 두면 확실합니다",
                fix: .configure))
        }

        // 10) 릴리즈노트 — 빈 채로 나간 버전은 되돌릴 수 없다
        //
        // 배포가 실제로 읽을 원고를 여기서도 같은 기준으로 찾는다.
        // ReleaseNotes.draft 가 **로컬 버전**으로 RepoNotes 를 찾으므로 여기도 로컬 버전이다 —
        // 기준이 갈라지면 체크리스트와 배포가 서로 다른 말을 하게 된다.
        let repoNotes = status.localVersion.flatMap { RepoNotes.read(app.path, version: $0) }
        let notesGate = Localization.Mode(r.releaseNotesGate)
        if notesGate == .off {
            out.append(ReadyItem(
                key: "notes", level: .ok, title: "릴리즈노트 검사 꺼짐",
                detail: "RELEASE_NOTES_GATE=off — 비어 있어도 배포합니다"))
        } else if status.notesUncheckable {
            // 예전엔 여기서 "업로드 뒤 자동으로 채웁니다" 라고 했다. 사실이 아니다.
            // altool 은 빌드만 올릴 뿐 App Store 버전을 만들지 않고, DeployBar 에도
            // 버전을 만드는 코드가 없다. 그래서 업로드 뒤 다시 도는 채우기도
            // "편집 가능한 버전 없음" 으로 또 보류된다 — 기다리면 된다고 믿게 두면
            // 빈 '이 버전의 새로운 기능' 으로 심사에 나간다. 누가 무엇을 해야 하는지 말한다.
            let v = status.localVersion ?? "다음 버전"
            out.append(ReadyItem(
                key: "notes", level: .need, title: "릴리즈노트 확인 불가",
                detail: "App Store Connect 에 편집 가능한 버전이 없어 확인할 수 없습니다"
                    + (repoNotes != nil ? " · 원고(\(repoNotes!.source))는 준비돼 있습니다" : ""),
                fix: .openNotes,
                todo: "App Store Connect 에서 v\(v) 버전을 먼저 만드세요 — DeployBar 는 버전을 만들지 않습니다. "
                    + "만들고 나면 배포가 시작할 때 릴리즈노트를 채웁니다",
                agent: "이건 네가 할 수 있는 일이 아니다. App Store Connect 웹에서 사람이 새 버전을 만드는 절차라 코드에 고칠 게 없어. 손대지 말고 알려만 줘."))
        } else if !status.notesMissing.isEmpty {
            let head = status.notesMissing.prefix(4).map { Locales.displayName($0) }.joined(separator: ", ")
            let v = status.notesVersion ?? status.localVersion ?? "버전"

            // App Store 칸이 비어 있다는 사실만으로 막지 않는다.
            //
            // 레포에 이번 버전 원고가 있으면 배포는 게이트 **앞에서** 그 글로 칸을 채운다
            // (Store+Deploy 의 .notesPrefill). 그런데도 여기서 ❌ 를 띄우면 배포 버튼이 잠기고,
            // 잠긴 걸 푸는 방법이라며 내미는 안내가 "RELEASE_NOTES.md 에 원고를 써라" —
            // **이미 써 둔 바로 그 파일**이다. 시키는 대로 다시 써도 App Store 칸은 그대로라
            // 영원히 안 풀린다. 복사한 프롬프트를 몇 번을 돌려도 13/15 에서 멈춰 있던 이유가 이거다.
            //
            // 여기서 답할 질문은 "App Store 칸이 찼나" 가 아니라 **"배포를 누르면 채울 글이 있나"** 다.
            // 채운 뒤에도 비면 그때는 Deployer 의 게이트가 archive 앞에서 진짜로 막는다 —
            // 안전장치는 거기 하나로 충분하고, 여기까지 막으면 그 게이트에 닿지도 못한다.
            let uncovered = status.notesMissing.filter { loc in
                !(repoNotes?.texts.keys.contains { Locales.sameLanguage($0, loc) } ?? false)
            }
            let repoBase = repoNotes?.texts.first { Locales.isKorean($0.key) }?.value ?? ""

            if let repo = repoNotes, uncovered.isEmpty {
                out.append(ReadyItem(
                    key: "notes", level: .ok, title: "릴리즈노트 준비됨 — 배포할 때 올라감",
                    detail: "v\(v) 의 App Store 칸(\(head))은 아직 비어 있지만 \(repo.source) 의 글로 배포 시작 때 채웁니다",
                    fix: .openNotes))
            } else if let repo = repoNotes, !repoBase.isEmpty {
                // 한국어 원고는 있고 그 언어 절만 없다 — 온디바이스 번역이 메운다.
                // 번역이 실패하면 archive 앞 게이트가 막으므로, 여기서는 알리기만 한다.
                let rest = uncovered.map { Locales.displayName($0) }.joined(separator: ", ")
                out.append(ReadyItem(
                    key: "notes", level: .need, title: "릴리즈노트 \(uncovered.count)개 언어는 번역으로 채움",
                    detail: "\(repo.source) 의 한국어 글을 \(rest) 로 옮겨 채웁니다 — 온디바이스 번역이 없으면 빈 채로 막힙니다",
                    fix: .openNotes,
                    todo: "확실히 하려면 RELEASE_NOTES.md 의 `## \(v)` 절에 \(rest) 문구를 직접 써 두세요",
                    agent: "RELEASE_NOTES.md 의 `## \(v)` 절에 \(rest) 문구만 추가해줘. 한국어 절은 이미 있으니 건드리지 마. "
                        + "기계번역하지 말고 그 언어권에서 자연스럽게 다시 쓰되 항목 수와 순서는 한국어 절과 맞춰줘. "
                        + "글머리표·번호·이모지·마크다운 강조 없이 한 줄에 한 문장씩, 한 줄 40자 이내."))
            } else {
                // 원고가 아예 없거나, 있어도 번역의 출발점인 한국어가 없다.
                // [빈 언어 채우기] 는 한국어를 원문으로 삼으므로, 출발점이 없을 땐
                // 그 버튼을 누르라고 해 봐야 "한국어 문구를 먼저 채워 주세요" 로 되돌아온다.
                let baseMissing = repoBase.isEmpty
                out.append(ReadyItem(
                    key: "notes", level: notesGate == .strict ? .blocked : .need,
                    title: "릴리즈노트 비어 있음 — \(status.notesMissing.count)개 언어",
                    detail: "v\(status.notesVersion ?? "?") 의 '이 버전의 새로운 기능' 이 \(head)"
                        + (status.notesMissing.count > 4 ? " 외" : "") + " 에서 비어 있습니다"
                        + (repoNotes == nil ? " · 레포에도 v\(status.localVersion ?? "?") 원고가 없습니다" : ""),
                    fix: .openNotes,
                    todo: baseMissing
                        ? "RELEASE_NOTES.md 에 `## \(v)` ▸ `### 앱스토어` 절로 한국어 문구를 써 두거나 [릴리즈노트] 창에서 한국어 칸을 직접 채우세요 — 나머지 언어는 [빈 언어 채우기] 가 그 글에서 옮깁니다"
                        : "[릴리즈노트] 창에서 [빈 언어 채우기] 를 누른 뒤 적용하세요"))
            }
        } else if !status.notesFilled.isEmpty {
            out.append(ReadyItem(
                key: "notes", level: .ok, title: "릴리즈노트 준비됨",
                detail: "v\(status.notesVersion ?? "?") · \(status.notesFilled.count)개 언어 모두 채워짐"))
        }

        // 10.4) deploy.env 에 적었지만 App Store 페이지에 없는 언어.
        //       이 언어의 노트는 만들어도 올릴 자리가 없어 조용히 버려진다.
        //       "영어 노트를 분명히 썼는데 왜 스토어엔 한국어뿐이지" 의 답이 여기 있다.
        if !status.notesUnlistedLocales.isEmpty {
            let names = status.notesUnlistedLocales.map { Locales.displayName($0) }.joined(separator: ", ")
            out.append(ReadyItem(
                key: "asclocale", level: .need, title: "App Store 에 없는 언어 — \(status.notesUnlistedLocales.count)개",
                detail: "deploy.env 의 \(names) 는 App Store 페이지에 없어 릴리즈노트가 올라가지 않습니다",
                todo: "App Store Connect ▸ 앱 정보 ▸ 현지화에서 언어를 추가하거나, deploy.env 의 LOCALES 에서 빼세요"))
        }

        // 10.5) 업로드한 빌드를 버전에 붙였는가 — 이걸 안 하면 심사 제출 자체가 안 된다.
        //       "업로드 완료" 와 "App Store 에 올라감" 사이의 빈칸이라 놓치기 쉽다.
        //
        // 다만 **지금 사람이 할 수 있는 일일 때만** 경고한다.
        // 그 버전의 빌드가 아직 올라가지도 않았으면 App Store Connect 에 고를 빌드가 없다 —
        // 그 상태에서 "빌드를 고르세요" 라고 하면 아무리 해도 안 없어지는 경고가 되고,
        // 그런 경고가 하나 있으면 나머지 열세 줄까지 같이 못 믿게 된다.
        if let hasBuild = status.editableHasBuild {
            let v = status.notesVersion ?? status.reviewVersion ?? "?"
            if hasBuild {
                out.append(ReadyItem(key: "asbuild", level: .ok, title: "버전에 빌드 연결됨",
                                     detail: "v\(v) 에 빌드가 선택돼 있습니다"))
            } else if status.ascBuildVersion == v {
                // 올려는 놨는데 버전에 안 붙였다 — 여기서만 사람이 할 일이 있다
                out.append(ReadyItem(
                    key: "asbuild", level: .need, title: "버전에 빌드 미연결",
                    detail: "v\(v) 빌드는 올라갔는데 버전에 선택돼 있지 않아 심사 제출이 안 됩니다",
                    todo: "App Store Connect ▸ v\(v) ▸ '빌드' 에서 업로드한 빌드를 고르세요"))
            } else {
                out.append(ReadyItem(
                    key: "asbuild", level: .ok, title: "빌드 업로드 전",
                    detail: "v\(v) 빌드가 아직 없습니다 — 배포하면 올리면서 이 버전에 붙입니다"))
            }
        }

        // 10.6) 이번 버전 문구가 어디서 오는가.
        //
        // 예전엔 여기서 'AI 키 없음' 을 ⚠️ 로 띄웠다. 그런데 그건 앱의 문제가 아니라
        // 도구 설정이고, 키를 사지 않는 한 31개 앱 전부에서 영원히 안 지워지는 항목이었다.
        // 체크리스트가 답해야 할 질문은 "키가 있나" 가 아니라
        // **"이번 버전에 올릴 문구가 준비돼 있나"** 다. 그 답만 말한다.
        if let repo = repoNotes {
            out.append(ReadyItem(
                key: "notesrc", level: .ok, title: "릴리즈노트 원고 있음",
                detail: "\(repo.source) — 배포할 때 이 글을 씁니다"))
        } else if status.notesFilled.isEmpty && !status.notesUncheckable {
            out.append(ReadyItem(
                key: "notesrc", level: .need, title: "릴리즈노트 원고 없음",
                detail: "커밋 제목에서 초안을 만듭니다 — 사용자용 문구가 아닐 수 있습니다",
                todo: "RELEASE_NOTES.md 에 `## \(status.localVersion ?? "버전")` 절을 만들고 그 아래 "
                    + "`### 앱스토어` 절에 스토어용 문구를 써 두면 배포가 그걸 그대로 씁니다"))
        }

        // 11) 심사 진행 중 — 배포는 되지만 알고 눌러야 한다
        if let label = status.reviewLabel, let v = status.reviewVersion {
            if status.inReview {
                // 내가 이미 낸 것 — '배포 가능' 과 섞이면 심사를 실수로 취소하게 된다
                out.append(ReadyItem(
                    key: "review", level: .ok, title: "제출함 · \(label)",
                    detail: "v\(v) 를 이미 제출했고 애플이 보고 있습니다 — 지금 새로 올리면 이 심사가 취소되고 처음부터 다시 시작합니다",
                    todo: "결과를 기다리세요. 급히 고쳐야 하면 ⋯ 의 [심사 취소하고 다시 배포] 를 쓰세요"))
            } else {
                // 제출 준비·거부됨 — 아직 안 낸 것이므로 배포해도 잃을 심사가 없다
                out.append(ReadyItem(
                    key: "review", level: .ok, title: "App Store \(label)",
                    detail: "v\(v) 는 아직 제출 전입니다 — 배포해도 잃을 심사가 없습니다",
                    fix: .openNotes))
            }
        }

        return Readiness(items: out)
    }
}

// ── 복사용 프롬프트 ────────────────────────────────────────────────────
// 잠긴 이유를 사람이 다시 옮겨 적지 않아도 되게, 코딩 에이전트에 그대로 붙여넣을
// 지시문을 체크리스트에서 기계적으로 만들어 낸다.
// 항목이 이미 (무엇이 / 왜 막고 / 뭘 해야 하는지) 로 쪼개져 있으므로 조립만 하면 된다.
extension ReadyItem {
    /// 이 항목을 에이전트가 처리할 때 필요한 구체적 지시.
    ///
    /// `todo` 와는 다른 글이다. `todo` 는 **사람이 창을 열고 누를 일**이고
    /// 이건 **에이전트가 파일을 고쳐서 끝낼 일**이다. 둘을 섞으면 안 된다 —
    /// "[빈 언어 채우기] 를 누르세요" 가 그대로 프롬프트에 실려 나가면
    /// 코딩 에이전트에겐 손댈 게 하나도 없는 지시가 된다. 붙여넣은 사람 눈엔
    /// "프롬프트를 복사해 줬는데 아무 일도 안 일어난다" 로 보이고, 그게 실제로 있었던 일이다.
    ///
    /// 그래서 **막는 항목엔 빠짐없이 답을 준다.** 에이전트가 할 수 있으면 그 일을,
    /// 사람만 할 수 있으면 "이건 네 몫이 아니다" 를 명시한다. nil 로 두면
    /// 프롬프트에서 '할 일' 줄이 조용히 사라질 뿐, 문제는 그대로 남는다.
    func agentHint(for status: AppStatus) -> String? {
        // 같은 key 라도 상황이 다르면 할 일이 다르다 (원고가 아예 없는 것과 한 언어만 빈 것)
        if let agent { return agent }
        // 노트를 써 넣을 절 제목에 쓴다 — 스토어에 올라갈 버전은 로컬 쪽이다
        let version = status.localVersion ?? status.notesVersion ?? "버전"
        switch key {
        case "git":
            return "바뀐 내용을 확인하고 의미 단위로 나눠 커밋해줘. 커밋 메시지는 한국어로, 무엇을 왜 바꿨는지 한 줄로."
        case "remote":
            return "원격과의 관계를 정리해줘. 저장 안 된 변경이 있으면 의미 단위로 커밋하고, 원격과 갈라져 있으면 `git pull --rebase` 로 원격 커밋 위에 내 커밋을 얹어줘. 충돌이 나면 임의로 고르지 말고 무엇이 충돌했는지 알려줘."
        case "changes":
            return "올릴 변경이 없는 상태다. 이번에 낼 만한 변경이 정말 없으면 그렇다고 알려주고 멈춰줘. 있다면 마무리해서 커밋해줘."
        case "version":
            return "deploy.env 의 VERSION_XCCONFIG 를 실제 xcconfig 위치로 고쳐줘. 그런 파일이 아예 없으면 MARKETING_VERSION 과 CURRENT_PROJECT_VERSION 을 담은 xcconfig 를 만들고 타겟 빌드 설정에 연결해줘."
        case "i18n":
            return ".xcstrings 에서 값이 비었거나 state 가 new/stale/needs_review 인 항목을 채워줘. 한국어 원문 기준으로 각 언어에 자연스럽게 옮기고(직역 금지), 한국어가 아닌 언어 값에 한글이 남지 않게 해줘. 복수형·기기별 variations 안까지 봐야 한다."
        case "env":
            return "앱 폴더 최상단에 deploy.env 를 만들어줘. SCHEME 은 실제 scheme 이름, PLATFORM 은 ios/macos, VERSION_XCCONFIG·PREDEPLOY_SCRIPT·LOCALES 도 이 앱에 맞게 채워줘. fastlane/.env 가 있으면 그 값을 옮겨 오고."
        case "gate":
            return "scripts/predeploy.sh 를 만들어줘. 이 앱의 테스트를 돌리고 실패하면 0이 아닌 값으로 끝나야 한다. 테스트 타겟이 없으면 빌드만 확인하는 수준으로 두고 그렇다고 알려줘."
        case "locales":
            return "deploy.env 의 LOCALES 에 이 앱이 App Store 에 등록한 언어를 쉼표로 적어줘. 릴리즈노트를 만들 언어이자 번역 검사 기준이 된다."
        case "asc":
            return "번들 ID 가 App Store Connect 의 앱과 맞는지 확인해줘. 프로젝트 쪽 PRODUCT_BUNDLE_IDENTIFIER 가 잘못됐으면 고치고, 스토어에 앱이 없는 거라면 그렇다고 알려줘 (앱 등록은 내가 직접 한다)."
        case "project":
            return "deploy.env 의 SCHEME 이 실제 scheme 이름과 같은지 확인하고 다르면 고쳐줘. `xcodebuild -list` 로 확인할 수 있다."
        case "notes", "notesrc":
            // 스토어 문구는 앱 안이 아니라 App Store Connect 에 있다. 에이전트는 거기에 못 쓴다.
            // 대신 RepoNotes 가 레포의 원고를 1순위로 읽으므로, 원고를 쓰는 것이 곧 해결이다.
            return "레포 최상단 RELEASE_NOTES.md 에 `## \(version)` 절을 만들고, 그 아래 `### 앱스토어 (한국어)` 와 `### App Store (English)` 절에 각 언어 문구를 써서 커밋해줘. DeployBar 가 배포할 때 이 글을 그대로 스토어에 올린다. "
                + "지킬 것: 글머리표(·, -, *)·번호·이모지·마크다운 강조를 쓰지 말고 한 줄에 한 문장씩, 3~5줄, 한 줄 40자 이내. "
                + "내부 리팩터링·빌드 설정·의존성 얘기는 빼고 사용자가 무엇이 좋아졌는지만 쓴다. 영어는 한국어를 기계번역하지 말고 그 언어권에서 자연스럽게 다시 쓰되 항목 수와 순서는 맞춰줘. "
                + "무엇을 냈는지는 직전 릴리즈 태그 이후의 커밋을 읽어서 판단해."
        case "asclocale":
            return "deploy.env 의 LOCALES 를 확인해줘. 스토어 페이지에 없는 언어를 지금 추가할 생각이 없다면 그 언어를 LOCALES 에서 빼고(주석과 키 순서는 그대로), 스토어에 언어를 추가할 생각이면 빼지 말고 그렇다고 알려줘 — 언어 추가는 App Store Connect 에서 사람이 한다."
        case "asbuild":
            return "이건 네가 할 수 있는 일이 아니다. App Store Connect 웹에서 사람이 빌드를 고르는 절차라 코드에 고칠 게 없어. 손대지 말고 남겨 둔 채로 알려줘."
        default:
            return nil
        }
    }
}

extension Readiness {
    /// 붙여넣기용 지시문. `only` 를 주면 그 항목 하나만 다룬다.
    func promptText(for status: AppStatus, only: ReadyItem? = nil) -> String {
        let targets = only.map { [$0] } ?? items.filter { $0.level != .ok }
        let blocked = targets.filter { $0.level == .blocked }
        let advised = targets.filter { $0.level == .need }

        var s = "\(status.path) 에서 App Store 배포를 막고 있는 문제를 해결해줘.\n\n"
        s += "## 지금 상태\n"
        s += "- 앱: \(status.name)"
        if let p = items.first(where: { $0.key == "project" }) { s += " (\(p.detail))" }
        s += "\n"
        s += "- 버전: 로컬 v\(status.localVersion ?? "?")(\(status.localBuild ?? "?")) · 스토어 \(status.liveVersion.map { "v\($0)" } ?? "미등록")\n"
        if let b = status.branch { s += "- 브랜치: \(b)\n" }
        s += "- 배포 준비: \(passedCount)/\(total)\n"

        func section(_ title: String, _ list: [ReadyItem]) {
            guard !list.isEmpty else { return }
            s += "\n## \(title)\n"
            for (i, item) in list.enumerated() {
                s += "\(i + 1). \(item.title)\n"
                s += "   - 상황: \(item.detail)\n"
                if let t = item.todo { s += "   - 필요한 것: \(t)\n" }
                if let h = item.agentHint(for: status) { s += "   - 할 일: \(h)\n" }
            }
        }
        section("❌ 배포를 막는 것 — 이것부터", blocked)
        section("⚠️ 권장 — 배포는 되지만 해 두면 좋은 것", advised)

        s += """

        ## 지켜야 할 것
        - 빌드·아카이브·업로드는 하지 마. 배포는 DeployBar 가 한다.
        - deploy.env 를 고칠 땐 주석과 키 순서를 그대로 두고 필요한 값만 바꿔.
        - 다 끝나면 커밋까지 해줘. 커밋되지 않은 변경이 남으면 배포가 다시 막힌다.
        - 못 고치는 게 있으면 억지로 넘기지 말고 무엇이 왜 막혔는지 알려줘.
        """
        return s
    }
}
