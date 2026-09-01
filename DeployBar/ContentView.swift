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

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var editingOrder = false
    /// 지금 걸린 필터. nil 이면 전부 보여 준다.
    @State private var filter: AppFilter?

    private func count(_ f: AppFilter) -> Int { store.statuses.filter(f.matches).count }
    private var readyCount: Int { count(.ready) }
    private var fixableCount: Int { count(.fixable) }

    /// 목록에 실제로 그릴 앱들 (필터 반영). 순서·배포 대상 판단은 늘 전체 기준이다.
    private var visible: [AppStatus] {
        guard let f = filter else { return store.statuses }
        return store.statuses.filter(f.matches)
    }

    /// '전체 배포' 에서 몇 번째로 나가는지 (배포 가능한 앱만 번호를 받는다)
    private var deployOrder: [String: Int] {
        var out: [String: Int] = [:]
        var n = 0
        for st in store.statuses where st.deployable {
            n += 1; out[st.path] = n
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 헤더 한 줄 — 요약(=필터)과 도구를 같은 줄에.
            // 제목은 창 타이틀바가 이미 '배포 콘솔' 이라 두 번 쓰지 않는다.
            HStack(spacing: 8) {
                if editingOrder {
                    Text("드래그 또는 ▲▼ 로 순서 변경 — 즉시 저장됩니다")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                } else {
                    SummaryBar(count: count, filter: $filter,
                               total: store.statuses.count, shown: visible.count,
                               loading: store.loading)
                }
                if store.job?.running == true {
                    Button { openWindow(id: "log") } label: {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("로그").font(.caption) }
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { editingOrder.toggle() }
                } label: {
                    Image(systemName: editingOrder ? "checkmark" : "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(store.job?.running == true)
                .help("배포 순서 정하기 — '전체 배포'가 이 순서대로 진행됩니다")

                Button { openWindow(id: "guide") } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help("사용법 · 배포에 필요한 것")
                Button {
                    Task { await store.refresh(fresh: true) }
                } label: {
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(store.loading)
                .help("상태 다시 조회")
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 9)

            Divider()

            if editingOrder {
                OrderEditor(deployOrder: deployOrder)
                    .frame(minHeight: 220, maxHeight: 460)
            } else {
                ScrollView {
                    // 32개를 한꺼번에 그리면 스크롤이 끊긴다 — 보이는 것만 그린다
                    LazyVStack(spacing: 8) {
                        if visible.isEmpty, let f = filter {
                            VStack(spacing: 8) {
                                Text(f.emptyNote).font(.callout).foregroundStyle(.secondary)
                                Button("전체 보기") { withAnimation { filter = nil } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                        ForEach(visible) { st in
                            AppCard(status: st,
                                    openLog: { openWindow(id: "log") },
                                    openNotes: { openWindow(id: "notes") })
                        }
                    }
                    .padding(8)
                }
                .background(Color.primary.opacity(0.035))
                .frame(minHeight: 220, idealHeight: 460, maxHeight: .infinity)
            }

            // 루트에 있는데 목록에 없는 폴더 — "내 앱이 왜 안 보이지" 를 여기서 답한다
            if !store.skipped.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.skipped) { k in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: k.fixable ? "exclamationmark.triangle.fill" : "minus.circle")
                                    .font(.caption2)
                                    .foregroundStyle(k.fixable ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(k.name).font(.caption.weight(.medium))
                                    Text(k.reason).font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Button {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: k.path)
                                } label: { Image(systemName: "folder").font(.caption2) }
                                .buttonStyle(.borderless).controlSize(.small)
                            }
                        }
                        Text("루트 밖(\(AppRepo.root) 아래가 아닌) 앱은 자동 발견되지 않습니다.")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("목록에 없는 폴더 (\(store.skipped.count))")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            if !store.hidden.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(spacing: 2) {
                        ForEach(store.hidden) { app in
                            HStack(spacing: 8) {
                                Image(systemName: "eye.slash")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(app.name).font(.subheadline)
                                Spacer()
                                Button("되돌리기") { store.unhideApp(app.path) }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .help("다시 관리 대상으로 되돌립니다")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("관리 안 함 (\(store.hidden.count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            Divider()
            HStack(spacing: 8) {
                if editingOrder {
                    Button {
                        withAnimation { store.resetOrder() }
                    } label: {
                        Label("이름순으로", systemImage: "textformat.abc").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("폴더 이름 오름차순으로 되돌립니다")

                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { editingOrder = false }
                    } label: {
                        Label("순서 저장 완료", systemImage: "checkmark").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("순서는 바꾸는 즉시 저장됩니다")
                } else {
                Button {
                    openWindow(id: "log")
                    store.deployAll(lane: .appstore)
                } label: {
                    Label("전체 배포\(readyCount > 0 ? " (\(readyCount))" : "")", systemImage: "square.stack.3d.up.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(store.job?.running == true || readyCount == 0)
                .help("막힌 곳이 없는 앱만 위에서부터 차례로 App Store 에 배포합니다 (순서는 ↑↓ 버튼에서)")

                if fixableCount > 0 {
                    Button {
                        openWindow(id: "log")
                        store.autoConfigureAll()
                    } label: {
                        Label("전체 자동 설정 (\(fixableCount))", systemImage: "wand.and.stars")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.job?.running == true)
                    .help("deploy.env·배포 전 검사 스크립트를 앱마다 만들어 배포를 자동화합니다")
                }

                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("종료", systemImage: "power").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .keyboardShortcut("q", modifiers: .command)
                .help("배포 콘솔 종료 (⌘Q)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { store.loadIfNeeded() }
        .onChange(of: store.openNotesSignal) { _ in openWindow(id: "notes") }
    }
}

// 배포 순서 편집 — 드래그(List 의 onMove)와 ▲▼ 버튼을 함께 둔다.
// 드래그가 안 잡히는 상황에서도 순서를 바꿀 수 있어야 하므로 버튼을 없애지 않는다.
private struct OrderEditor: View {
    @EnvironmentObject var store: Store
    let deployOrder: [String: Int]

    var body: some View {
        List {
            ForEach(Array(store.statuses.enumerated()), id: \.element.id) { i, st in
                HStack(spacing: 8) {
                    Image(systemName: "line.3.horizontal")
                        .font(.caption).foregroundStyle(.tertiary)

                    // 이번 '전체 배포' 에서 몇 번째로 나가는지. 대상이 아니면 회색 순번.
                    if let n = deployOrder[st.path] {
                        Text("\(n)")
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.green))
                    } else {
                        Text("\(i + 1)")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.secondary.opacity(0.12)))
                    }

                    Text(st.name).font(.subheadline.weight(.medium))
                    if deployOrder[st.path] == nil {
                        Text(st.readiness.blockers.first?.title ?? st.state.label)
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button { withAnimation { store.moveApp(st.path, by: -1) } } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(i == 0)
                    .help("위로")

                    Button { withAnimation { store.moveApp(st.path, by: 1) } } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless).controlSize(.small)
                    .disabled(i == store.statuses.count - 1)
                    .help("아래로")
                }
                .padding(.vertical, 2)
            }
            .onMove { source, dest in
                withAnimation { store.moveApps(from: source, to: dest) }
            }
        }
        .listStyle(.plain)
    }
}

// 상단 요약 = 필터. 세기만 하고 못 누르면 40개 목록에서 그 3개를 눈으로 찾아야 한다.
private struct SummaryBar: View {
    let count: (AppFilter) -> Int
    @Binding var filter: AppFilter?
    let total: Int, shown: Int
    let loading: Bool

    var body: some View {
        HStack(spacing: 6) {
            if loading && total == 0 {
                ProgressView().controlSize(.small)
                Text("앱을 찾는 중…").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(AppFilter.allCases) { f in
                    let n = count(f)
                    // 0개인 분류는 눌러도 빈 화면이라 숨긴다 (걸려 있는 필터는 남겨 둔다)
                    if n > 0 || filter == f {
                        Chip(n: n, f: f, on: filter == f) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                filter = (filter == f) ? nil : f
                            }
                        }
                    }
                }
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.mini) }
                if filter != nil {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { filter = nil }
                    } label: {
                        Text("\(shown)/\(total)개").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help("필터 해제 — 전체 \(total)개 보기")
                } else {
                    Text("\(total)개 앱").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private struct Chip: View {
        let n: Int
        let f: AppFilter
        let on: Bool
        let tap: () -> Void

        var body: some View {
            Button(action: tap) {
                HStack(spacing: 4) {
                    Text("\(n)").font(.caption.weight(.bold).monospacedDigit())
                    Text(f.label).font(.caption)
                }
                .foregroundStyle(on ? .white : (n > 0 ? f.color : f.color.opacity(0.35)))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(on ? f.color : .clear))
            }
            .buttonStyle(.plain)
            .help(on ? "필터 해제" : "\(f.label) 앱 \(n)개만 보기")
        }
    }
}

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
    /// 펼친 체크리스트에서 '통과한 것' 까지 볼지 — 기본은 접어 둔다 (대개 6~8줄이라 소음이 크다)
    @State private var showPassed = false
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

    // 잠긴 이유를 손으로 옮겨 적지 않게 — 체크리스트를 그대로 지시문으로 만들어 클립보드에 넣는다
    private func copyPrompt(_ item: ReadyItem?) {
        let key = item?.key ?? "*"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(readiness.promptText(for: status, only: item), forType: .string)
        copiedKey = key
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if copiedKey == key { copiedKey = nil }
        }
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
            if expanded { checklist }
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
                Button { copyPrompt(nil) } label: {
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

    // ── 펼쳤을 때: 손볼 것부터. 통과한 것은 접어 둔다 ────────────────────
    private var pending: [ReadyItem] { readiness.sorted.filter { $0.level != .ok } }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.bottom, 2)

            HStack(spacing: 8) {
                Text("배포 준비 \(readiness.passedCount)/\(readiness.total)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                ProgressView(value: readiness.progress)
                    .progressViewStyle(.linear)
                    .tint(readiness.canDeploy ? .green : .orange)
                    .frame(maxWidth: 90)
                Spacer(minLength: 4)
                if !pending.isEmpty {
                    Button { copyPrompt(nil) } label: {
                        Label(copiedKey == "*" ? "복사됨" : "해결 프롬프트",
                              systemImage: copiedKey == "*" ? "checkmark" : "doc.on.doc")
                            .font(.caption2)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("남은 항목을 그대로 지시문으로 만들어 복사합니다 — Claude Code 등에 붙여넣으면 됩니다")
                }
            }

            ForEach(pending) { item in row(item) }

            // 통과한 것은 '다 됐다' 만 확인되면 되므로 한 줄로 접어 둔다
            if readiness.passedCount > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showPassed.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").font(.caption2)
                        Text("통과한 \(readiness.passedCount)가지").font(.caption)
                        Image(systemName: showPassed ? "chevron.up" : "chevron.down").font(.system(size: 8))
                    }
                    .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .padding(.top, pending.isEmpty ? 0 : 2)

                if showPassed {
                    ForEach(readiness.passed) { item in row(item) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
    }

    private func row(_ item: ReadyItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.icon)
                .font(.caption)
                .foregroundStyle(itemColor(item))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(item.level == .ok ? .secondary : .primary)
                Text(item.detail)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let todo = item.todo {
                    Text("→ \(todo)")
                        .font(.caption2).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            if let fix = item.fix, fix != .reveal {
                fixButton(fix)
            } else if item.level != .ok {
                // 버튼 한 번으로 안 되는 것만 프롬프트가 쓸모 있다
                Button { copyPrompt(item) } label: {
                    Image(systemName: copiedKey == item.key ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("이 항목만 지시문으로 복사")
            }
        }
        .padding(.vertical, item.isBlocker ? 5 : 0)
        .padding(.horizontal, item.isBlocker ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(item.isBlocker ? Color.orange.opacity(0.10) : .clear)
        )
    }

    private func itemColor(_ item: ReadyItem) -> Color {
        switch item.level {
        case .ok: return .green
        case .need: return .blue
        case .blocked: return .orange
        }
    }

    @ViewBuilder private func fixButton(_ fix: Fix) -> some View {
        if let app = store.app(named: status.path) {
            Button {
                switch fix {
                case .configure: Task { await store.autoConfigure(app) }
                case .bumpPatch: Task { await store.bumpVersion(app, .patch) }
                case .openNotes: openNotes(); Task { await store.loadNotes(app) }
                case .reveal: NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.path)
                case .ignoreNoise: Task { await store.ignoreXcodeNoise(app) }
                }
            } label: {
                if store.fixing.contains(status.path) && (fix == .configure || fix == .ignoreNoise) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(fix.label).font(.caption2)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.job?.running == true || store.fixing.contains(status.path))
        }
    }
}
