import SwiftUI

// 앱 카드.
//
// 40개가 세로로 늘어서는 화면이라, **같은 말을 두 번 하지 않는 것**이 곧 디자인이다.
// 예전엔 '잠김' 이 이름 옆 배지 · 요약 줄 · 오른쪽 버튼 세 곳에서 반복됐다.
// 지금은 한 번씩만 말한다:
//   점 = 상태(색)  /  버튼 = 지금 할 수 있는 일  /  요약 줄 = 무엇이 왜 막는지
struct AppCard: View {
    let status: AppStatus
    let openLog: () -> Void
    let openNotes: () -> Void
    @EnvironmentObject var store: Store
    @State private var expanded = false
    /// 방금 어떤 프롬프트를 복사했는지 ("*" = 카드 전체). 잠깐 '복사됨' 을 보여 주고 지운다.
    @State private var copiedKey: String?

    private var readiness: Readiness { status.readiness }
    private var canDeploy: Bool { status.deployable }
    private var isDone: Bool { status.state == .deployed }
    /// 내가 제출해서 애플이 보고 있는 중 — '배포 가능' 과 반드시 구분해야 한다
    private var inReview: Bool { status.inReview }

    /// 폴더 이름이 바뀌어도 그대로인 신원. "이거 그 앱 맞나" 를 이름 위에서 확인할 수 있게.
    private var identity: String {
        var parts = ["폴더 \(status.name)"]
        if let key = status.projectFile { parts.append("프로젝트 \(key)") }
        if let b = status.bundleId { parts.append(b) }
        return parts.joined(separator: " · ")
    }

    // 점 하나가 상태를 말한다 — 같은 뜻의 글자 배지를 옆에 또 두지 않는다
    private var dotColor: Color {
        if inReview { return .purple }
        switch status.state {
        case .loading: return .secondary
        case .error: return .red
        case .deployed: return .gray    // 할 일이 없는 상태. 초록은 '지금 배포 가능' 에만 쓴다.
        default:
            // 권장(⚠️)이 남았다고 색을 바꾸지 않는다 — 점이 답하는 질문은 "지금 배포되나" 하나다
            return readiness.blockers.isEmpty ? .green : .orange
        }
    }
    private var dotHelp: String {
        if inReview { return "\(status.reviewLabel ?? "심사 중") — 내가 제출했고 애플이 보고 있습니다" }
        switch status.state {
        case .loading: return "조회 중"
        case .error: return "오류"
        case .deployed: return "배포됨 — 로컬이 스토어와 같습니다"
        default:
            if !readiness.blockers.isEmpty { return "배포 잠김 — \(readiness.blockers.count)건" }
            return readiness.needs.isEmpty ? "배포 가능" : "배포 가능 · 권장 \(readiness.needs.count)건"
        }
    }

    // 버전 줄의 스토어 상태 색도 점·버튼과 같은 뜻이어야 한다.
    //   보라 = 내가 냈고 심사 중 · 빨강 = 거부됨 · 파랑 = 아직 안 낸 상태(제출 준비)
    private var reviewColor: Color {
        guard let s = status.reviewState else { return .blue }
        if s.contains("REJECT") || s == "INVALID_BINARY" { return .red }
        return ASCState.isSubmitted(s) ? .purple : .blue
    }

    // 배포 버튼을 못 누르는 이유를 그대로 말해 준다 — 눌러보고 나서 알게 하지 않는다
    private var deployHelp: String {
        if let b = readiness.blockers.first { return "\(b.title) — \(b.todo ?? b.detail)" }
        if isDone { return "이미 최신 버전입니다. ⋯ 에서 버전을 올리세요." }
        return status.commitsSinceDeploy > 0
            ? "마지막 배포 후 커밋 \(status.commitsSinceDeploy)개 — 같은 버전에 새 빌드로 배포"
            : "App Store 에 배포 (검사→빌드→업로드→언어별 릴리즈노트)"
    }

    private var versions: String {
        if status.state == .loading { return "조회 중…" }
        if status.state == .error { return status.error ?? "오류" }
        let local = "v\(status.localVersion ?? "?")(\(status.localBuild ?? "?"))"
        let live = status.liveVersion.map { "스토어 v\($0)" } ?? "스토어 미등록"
        return "\(local) · \(live)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded { ReadinessChecklist(status: status) }
            if let msg = store.fixResult[status.path] {
                Text(msg)
                    .font(.caption).foregroundStyle(.green)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.13), lineWidth: 1)
        )
    }

    // ── 접힌 카드 ────────────────────────────────────────────────────
    // 31개가 세로로 늘어서므로, 한 카드가 답해야 할 질문은 셋뿐이다.
    //   1) 지금 사람들이 쓰는 버전은?   2) 내가 올리려는 버전은?   3) 지금 상태는?
    // 아이콘은 그 셋을 말해 주지 않으면서 자리만 먹으므로 뺐다.
    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(status.name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .help(identity)
                Spacer(minLength: 8)
                statusBadge
            }

            versionRow

            HStack(alignment: .center, spacing: 8) {
                if status.state != .loading && !readiness.items.isEmpty { summaryLine }
                Spacer(minLength: 8)
                if status.state == .loading {
                    ProgressView().controlSize(.small)
                } else if status.state != .error {
                    deployControl
                    notesButton
                }
                overflowMenu
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
    }

    /// 상태를 낱말 하나로. 색은 필터 칩과 같은 규칙을 쓴다.
    private var statusText: String {
        switch status.state {
        case .loading: return "조회 중"
        case .error: return "오류"
        case .deployed: return "배포됨"
        default:
            if inReview { return status.reviewLabel ?? "심사 중" }
            if !readiness.blockers.isEmpty { return "잠김 \(readiness.blockers.count)" }
            return "배포 가능"
        }
    }
    private var statusBadge: some View {
        Text(statusText)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(dotColor))
            .help(dotHelp)
    }

    /// 스토어에 나가 있는 버전과, 이번에 올릴 버전. 어느 쪽이 뭔지 글자로 붙인다.
    @ViewBuilder private var versionRow: some View {
        if status.state == .loading {
            Text("조회 중…").font(.subheadline).foregroundStyle(.secondary)
        } else if status.state == .error {
            Text(status.error ?? "오류").font(.subheadline).foregroundStyle(.red).lineLimit(2)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                labeled("스토어", status.liveVersion.map { "v\($0)" } ?? "아직 없음",
                        weight: .regular, color: .secondary)
                if isDone {
                    // 라벨 줄 높이를 맞춰 값끼리 같은 줄에 놓이게 한다
                    VStack(alignment: .leading, spacing: 1) {
                        Text(" ").font(.caption2).opacity(0)
                        Text("올릴 것 없음").font(.subheadline).foregroundStyle(.secondary)
                    }
                } else {
                    Text("→").font(.subheadline).foregroundStyle(.tertiary)
                    labeled("올릴 버전",
                            "v\(status.localVersion ?? "?")  빌드 \(status.localBuild ?? "?")",
                            weight: .semibold, color: .primary)
                }
                Spacer(minLength: 0)
            }
        }
    }
    private func labeled(_ label: String, _ value: String,
                         weight: Font.Weight, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.subheadline.weight(weight)).foregroundStyle(color).lineLimit(1)
        }
    }

    /// 지금 할 일 한 줄. 아이콘 없이 색과 글자로만.
    private var summaryLine: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text(inReview ? "결과 기다리는 중" : readiness.headline)
                    .font(.caption)
                    .lineLimit(1)
                Text("\(readiness.passedCount)/\(readiness.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(summaryColor)
        }
        .buttonStyle(.plain)
        .help("배포에 필요한 \(readiness.total)가지 중 \(readiness.passedCount)가지 준비됨 — 눌러서 항목별로 보기")
    }

    private var summaryColor: Color {
        if inReview { return .purple }
        if isDone { return .gray }
        if !readiness.blockers.isEmpty { return .orange }
        // 권장이 남아도 '배포 가능' 이므로 초록. 몇 건인지는 글자가 말한다.
        return .green
    }

    // ── 버튼: 지금 할 수 있는 일 하나 ──────────────────────────────────
    @ViewBuilder private var deployControl: some View {
        if let cur = status.localVersion, let app = store.app(named: status.path) {
            if inReview {
                // 한 번 눌러 배포되면 심사가 취소된다. 그래서 기본 동작이 없는 버튼으로 둔다.
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
                } label: {
                    Text(status.reviewLabel ?? "심사 중").frame(minWidth: 48)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
                .tint(.purple)
                .help("v\(status.reviewVersion ?? "?") 를 이미 제출했고 애플이 보고 있습니다. 지금 새로 올리면 이 심사가 취소되고 처음부터 다시 시작합니다. 그래도 올리려면 ⋯ 메뉴에서.")
            } else if isDone {
                // 이미 올라간 앱을 '잠김' 이라 부르지 않는다 — 할 일이 없는 것뿐이다
                Button {
                    Task { await store.bumpVersion(app, .patch) }
                } label: {
                    Text("버전 올리기").font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(store.job?.running == true)
                .help("v\(cur) → v\(Deployer.bumpVersion(cur, .patch)) 로 올려 다시 배포할 수 있게 합니다")
            } else if !canDeploy {
                // 못 누르는 버튼은 이유를 말하지 않는다 — '왜 잠겼는지' 를 여는 버튼으로 바꾼다
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded = true }
                } label: {
                    Text("왜 잠겼나").frame(minWidth: 52)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .fixedSize()
                .tint(.orange)
                .help("눌러서 이유 보기 — \(deployHelp)")
            } else {
                HStack(spacing: 2) {
                    Button {
                        openLog(); store.startDeploy(app, lane: .appstore, versionBump: nil)
                    } label: {
                        Text("배포").frame(minWidth: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .help(deployHelp)

                    Menu {
                        Button("빌드만 올리기  ·  v\(cur) 유지") {
                            openLog(); store.startDeploy(app, lane: .appstore, versionBump: nil)
                        }
                        Divider()
                        Button("패치 올려 배포  →  v\(Deployer.bumpVersion(cur, .patch))") {
                            openLog(); store.startDeploy(app, lane: .appstore, versionBump: .patch)
                        }
                        Button("마이너 올려 배포  →  v\(Deployer.bumpVersion(cur, .minor))") {
                            openLog(); store.startDeploy(app, lane: .appstore, versionBump: .minor)
                        }
                        Button("메이저 올려 배포  →  v\(Deployer.bumpVersion(cur, .major))") {
                            openLog(); store.startDeploy(app, lane: .appstore, versionBump: .major)
                        }
                    } label: { EmptyView() }
                    .menuStyle(.borderlessButton)
                    .frame(width: 16)
                    .help("버전을 올려서 배포하기")
                }
                .controlSize(.regular)
                .fixedSize()
                .disabled(store.job?.running == true)
            }
        }
    }

    @ViewBuilder private var notesButton: some View {
        if let app = store.app(named: status.path) {
            Button {
                openNotes()
                Task { await store.loadNotes(app) }
            } label: {
                Text("노트").font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("언어별 릴리즈노트 보기·수정")
        }
    }

    // 자주 안 쓰는 것은 전부 여기로 — 카드에 상시로 떠 있을 이유가 없다
    private var overflowMenu: some View {
        Menu {
            if inReview, let app = store.app(named: status.path) {
                Menu("심사 취소하고 다시 배포") {
                    Text("v\(status.reviewVersion ?? "?") 심사가 취소되고 새 빌드로 다시 시작합니다")
                    Divider()
                    Button("그래도 지금 배포") {
                        openLog(); store.startDeploy(app, lane: .appstore, versionBump: nil)
                    }
                }
                .disabled(store.job?.running == true)
                Divider()
            }
            if let app = store.app(named: status.path), let cur = status.localVersion {
                Menu("버전 올리기 (현재 v\(cur))") {
                    Button("패치 +0.0.1  →  \(Deployer.bumpVersion(cur, .patch))") { Task { await store.bumpVersion(app, .patch) } }
                    Button("마이너 +0.1.0  →  \(Deployer.bumpVersion(cur, .minor))") { Task { await store.bumpVersion(app, .minor) } }
                    Button("메이저 +1.0.0  →  \(Deployer.bumpVersion(cur, .major))") { Task { await store.bumpVersion(app, .major) } }
                }
                .disabled(store.job?.running == true)
                Divider()
            }
            if let app = store.app(named: status.path) {
                Button { Task { await store.autoConfigure(app) } } label: {
                    Label("배포 설정 자동 정리", systemImage: "wand.and.stars")
                }
                Button { openLog(); store.runDoctor(app) } label: {
                    Label("설정 자세히 점검", systemImage: "stethoscope")
                }
                Button {
                    Clipboard.copy(readiness.promptText(for: status))
                } label: {
                    Label("해결 프롬프트 복사", systemImage: "doc.on.doc")
                }
                .disabled(readiness.passedCount == readiness.total)
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: status.path)
                } label: {
                    Label("Finder 에서 열기", systemImage: "folder")
                }
                Divider()
            }
            Button { store.hideApp(status.path) } label: {
                Label("관리에서 빼기", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.regular)
        .fixedSize()
        .menuIndicator(.hidden)
        .help("버전 올리기 · 자동 설정 · 점검 · 관리에서 빼기")
    }
}
