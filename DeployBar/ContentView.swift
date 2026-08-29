import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var editingOrder = false

    private var readyCount: Int { store.statuses.filter { $0.state == .ready && $0.readiness.canDeploy }.count }
    private var blockedCount: Int { store.statuses.filter { !$0.readiness.blockers.isEmpty }.count }
    private var fixableCount: Int { store.statuses.filter { $0.readiness.autoFixable }.count }

    /// '전체 배포' 에서 몇 번째로 나가는지 (배포 가능한 앱만 번호를 받는다)
    private var deployOrder: [String: Int] {
        var out: [String: Int] = [:]
        var n = 0
        for st in store.statuses where st.state == .ready && st.readiness.canDeploy {
            n += 1; out[st.path] = n
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 헤더
            HStack(spacing: 8) {
                Text("배포 콘솔").font(.headline)
                Spacer()
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
            .padding(.horizontal, 14).padding(.vertical, 10)

            if editingOrder {
                Text("드래그하거나 ▲▼ 로 순서를 바꾸세요 — [전체 배포]가 위에서부터 차례로 진행합니다.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            } else {
                // 지금 상황 한 줄 — 앱을 열자마자 뭘 해야 하는지 보이게
                SummaryBar(ready: readyCount, blocked: blockedCount, fixable: fixableCount,
                           total: store.statuses.count, loading: store.loading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }

            Divider()

            if editingOrder {
                OrderEditor(deployOrder: deployOrder)
                    .frame(minHeight: 220, maxHeight: 460)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(store.statuses) { st in
                            AppCard(status: st,
                                    deployPosition: deployOrder[st.path],
                                    openLog: { openWindow(id: "log") },
                                    openNotes: { openWindow(id: "notes") })
                        }
                    }
                    .padding(8)
                }
                .frame(minHeight: 220, maxHeight: 460)
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
        .frame(width: 480)
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
                            .background(Circle().fill(Color.accentColor))
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

// 상단 요약 — "지금 배포할 수 있는 앱 / 막힌 앱 / 정리하면 되는 앱"
private struct SummaryBar: View {
    let ready: Int, blocked: Int, fixable: Int, total: Int
    let loading: Bool

    var body: some View {
        HStack(spacing: 10) {
            if loading && total == 0 {
                ProgressView().controlSize(.small)
                Text("앱을 찾는 중…").font(.caption).foregroundStyle(.secondary)
            } else {
                Chip(count: ready, label: "배포 가능", color: .green, icon: "checkmark.circle.fill")
                Chip(count: blocked, label: "막힘", color: .orange, icon: "exclamationmark.triangle.fill")
                if fixable > 0 {
                    Chip(count: fixable, label: "설정 필요", color: .blue, icon: "wand.and.stars")
                }
                Spacer()
                if loading { ProgressView().controlSize(.mini) }
                Text("\(total)개 앱").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private struct Chip: View {
        let count: Int, label: String
        let color: Color, icon: String
        var body: some View {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2)
                Text("\(count)").font(.caption.weight(.bold))
                Text(label).font(.caption)
            }
            .foregroundStyle(count > 0 ? color : Color.secondary)
        }
    }
}

struct AppCard: View {
    let status: AppStatus
    /// '전체 배포' 에서 몇 번째로 나가는지. 대상이 아니면 nil.
    var deployPosition: Int?
    let openLog: () -> Void
    let openNotes: () -> Void
    @EnvironmentObject var store: Store
    @State private var expanded = false

    private var color: Color {
        switch status.state {
        case .loading: return .secondary
        case .dev: return .gray
        case .ready: return .orange
        case .deployed: return .green
        case .error: return .red
        }
    }

    private var reviewColor: Color {
        guard let s = status.reviewState else { return .blue }
        return (s.contains("REJECT") || s == "INVALID_BINARY") ? .red : .blue
    }

    // 진행 중 심사 상태가 있으면 그걸 메인 뱃지로, 없으면 로컬 상태
    private var displayLabel: String { status.reviewLabel ?? status.state.label }
    private var displayColor: Color { status.reviewLabel != nil ? reviewColor : color }

    private var readiness: Readiness { status.readiness }
    private var canDeploy: Bool { status.state == .ready && readiness.canDeploy }

    // 배포 버튼을 못 누르는 이유를 그대로 말해 준다 — 눌러보고 나서 알게 하지 않는다
    private var deployHelp: String {
        if let b = readiness.blockers.first { return "\(b.title) — \(b.todo ?? b.detail)" }
        if status.state == .deployed { return "이미 최신 버전입니다. # 로 버전을 올리세요." }
        if status.state == .dev { return "커밋되지 않은 변경이 있습니다." }
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
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(displayColor).frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(status.name).font(.system(size: 15, weight: .semibold))
                    // 전체 배포에서 몇 번째인지 — 순서를 바꾸면 여기 숫자가 따라 움직인다
                    if let n = deployPosition {
                        Text("전체 배포 \(n)번째")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                            .help("[전체 배포] 를 누르면 \(n)번째로 나갑니다. 순서는 헤더의 ↑↓ 버튼에서 바꿉니다.")
                    }
                    Text(displayLabel).font(.caption.weight(.semibold)).foregroundStyle(displayColor)
                    if status.reviewLabel != nil, let v = status.reviewVersion {
                        Text("v\(v)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(versions)
                    .font(.subheadline)
                    .foregroundStyle(status.state == .error ? .red : .secondary)
                    .lineLimit(1)
                // 지금 할 일 한 줄 — 펼치지 않아도 보이게
                if status.state != .loading && !readiness.items.isEmpty {
                    Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                        HStack(spacing: 4) {
                            Image(systemName: headlineIcon).font(.caption2)
                            Text(readiness.headline).font(.caption)
                            Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8))
                        }
                        .foregroundStyle(headlineColor)
                    }
                    .buttonStyle(.plain)
                    .help("눌러서 자세히 보기")
                }
            }

            Spacer(minLength: 8)

            if status.state == .loading {
                ProgressView().controlSize(.small)
            } else if status.state != .error {
                actions
            }
            overflowMenu
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
    }

    private var headlineIcon: String {
        if !readiness.blockers.isEmpty { return "exclamationmark.triangle.fill" }
        return readiness.needs.isEmpty ? "checkmark.circle.fill" : "wrench.adjustable"
    }
    private var headlineColor: Color {
        if !readiness.blockers.isEmpty { return .orange }
        return readiness.needs.isEmpty ? .green : .blue
    }

    @ViewBuilder private var actions: some View {
        if let cur = status.localVersion, let app = store.app(named: status.path) {
            Menu {
                Button("패치 +0.0.1  →  \(Deployer.bumpVersion(cur, .patch))") { Task { await store.bumpVersion(app, .patch) } }
                Button("마이너 +0.1.0  →  \(Deployer.bumpVersion(cur, .minor))") { Task { await store.bumpVersion(app, .minor) } }
                Button("메이저 +1.0.0  →  \(Deployer.bumpVersion(cur, .major))") { Task { await store.bumpVersion(app, .major) } }
            } label: {
                Image(systemName: "number")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.regular)
            .fixedSize()
            .help("앱 버전 올리기 (현재 v\(cur))")
            .disabled(store.job?.running == true)

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
            } label: {
                Text("배포").frame(minWidth: 40)
            } primaryAction: {
                openLog(); store.startDeploy(app, lane: .appstore, versionBump: nil)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fixedSize()
            .disabled(store.job?.running == true || !canDeploy)
            .help(deployHelp)

            Button {
                openNotes()
                Task { await store.loadNotes(app) }
            } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .help("언어별 릴리즈노트 보기·수정")
        }
    }

    private var overflowMenu: some View {
        Menu {
            if let app = store.app(named: status.path) {
                Button {
                    Task { await store.autoConfigure(app) }
                } label: {
                    Label("배포 설정 자동 정리", systemImage: "wand.and.stars")
                }
                Button {
                    openLog(); store.runDoctor(app)
                } label: {
                    Label("설정 자세히 점검", systemImage: "stethoscope")
                }
                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: status.path)
                } label: {
                    Label("Finder 에서 열기", systemImage: "folder")
                }
                Divider()
            }
            Button {
                store.hideApp(status.path)
            } label: {
                Label("관리에서 빼기", systemImage: "eye.slash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .controlSize(.regular)
        .fixedSize()
        .menuIndicator(.hidden)
        .help("자동 설정 · 점검 · 관리에서 빼기")
    }

    // 펼쳤을 때: 배포에 필요한 것들을 항목별로
    private var checklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.bottom, 2)
            ForEach(readiness.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: item.icon)
                        .font(.caption)
                        .foregroundStyle(itemColor(item))
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.caption.weight(.semibold))
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
                    if let fix = item.fix { fixButton(fix) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 12)
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
                }
            } label: {
                if store.fixing.contains(status.path) && fix == .configure {
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
