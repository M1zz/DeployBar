import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

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
                    Task { await store.refresh(fresh: true) }
                } label: {
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(store.loading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    ForEach(store.statuses) { st in
                        CompactRow(status: st,
                                   openLog: { openWindow(id: "log") },
                                   openNotes: { openWindow(id: "notes") })
                    }
                }
                .padding(8)
            }
            // 팝오버에서 ScrollView 높이가 0으로 찌부러지지 않도록 명시적 높이 지정
            .frame(height: min(CGFloat(max(store.statuses.count, 1)) * 72 + 16, 480))

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
            HStack(spacing: 10) {
                let readyCount = store.statuses.filter { $0.state == .ready }.count
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
                .help("배포 준비완료(🟡) 앱을 순차로 App Store 에 배포")

                Spacer()
                Text("\(store.statuses.count)개 앱").font(.caption).foregroundStyle(.secondary)
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
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 460)
        .onAppear { store.loadIfNeeded() }
        .onChange(of: store.openNotesSignal) { _ in openWindow(id: "notes") }
    }
}

struct CompactRow: View {
    let status: AppStatus
    let openLog: () -> Void
    let openNotes: () -> Void
    @EnvironmentObject var store: Store

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

    // 배포 버튼은 '준비완료'일 때만 활성화 — 이미 배포됨/개발 중 앱의 실수 방지
    private var deployHelp: String {
        switch status.state {
        case .ready:
            return status.commitsSinceDeploy > 0
                ? "마지막 배포 후 커밋 \(status.commitsSinceDeploy)개 — 같은 버전에 새 빌드로 배포"
                : "App Store 에 배포 (게이트→빌드→업로드)"
        case .deployed: return "이미 최신 버전입니다. 새로 배포하려면 # 로 버전을 올리세요."
        case .dev: return "커밋되지 않은 변경이 있습니다. 커밋 후 배포하세요."
        default: return ""
        }
    }

    private var detail: String {
        if status.state == .loading { return "조회 중…" }
        if status.state == .error { return status.error ?? "오류" }
        let local = "v\(status.localVersion ?? "?")(\(status.localBuild ?? "?"))"
        let live = status.liveVersion.map { "스토어 v\($0)" } ?? "미등록"
        let dirty = status.dirty ? " ✎" : ""
        let commits = (!status.dirty && status.commitsSinceDeploy > 0) ? " · 배포 후 \(status.commitsSinceDeploy)커밋" : ""
        return "\(local) · \(live)\(dirty)\(commits)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(displayColor).frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(status.name).font(.system(size: 15, weight: .semibold))
                    Text(displayLabel).font(.caption.weight(.semibold)).foregroundStyle(displayColor)
                    if status.reviewLabel != nil, let v = status.reviewVersion {
                        Text("v\(v)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(status.state == .error ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if status.state == .loading {
                ProgressView().controlSize(.small)
            } else if status.state != .error {
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
                }
                if let cur = status.localVersion, let app = store.app(named: status.path) {
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
                        // 기본 클릭 = 빌드만 올리기 (가장 흔한 경우)
                        openLog(); store.startDeploy(app, lane: .appstore, versionBump: nil)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .fixedSize()
                    .disabled(store.job?.running == true || status.state != .ready)
                    .help(deployHelp)
                }

                Button {
                    if let app = store.app(named: status.path) {
                        openNotes()
                        Task { await store.loadNotes(app) }
                    }
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .help("릴리즈노트")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .contextMenu {
            Button {
                store.hideApp(status.path)
            } label: {
                Label("관리에서 빼기", systemImage: "eye.slash")
            }
            .help("폴더는 그대로 두고 목록·배포 대상에서만 잠시 제외합니다")
        }
    }
}
