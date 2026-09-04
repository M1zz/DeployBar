import SwiftUI
import AppKit

// 메뉴바는 창의 축소판이 아니다.
//
// 예전엔 MenuBarExtra 안에 ContentView 를 그대로 넣었다. 그래서 메뉴바를 눌러도
// 창에 있는 것과 글자 하나까지 같은 화면이 나왔고, 31개 카드가 좁은 팝오버에
// 그대로 들어가 스크롤만 길어졌다. 창이 이미 열려 있으면 메뉴바를 누를 이유가 없었다.
//
// 두 표면은 답해야 할 질문이 다르다.
//   창    — "무엇을 어떻게 고치나" (체크리스트·순서·릴리즈노트·로그 전문)
//   메뉴바 — "지금 뭐가 돌고 있고, 내가 지금 누를 게 있나"
//
// 그래서 여기엔 **지금 당장 할 수 있는 것과 지금 돌아가는 것**만 둔다.
// 고르고 읽고 편집하는 일은 전부 창으로 보낸다.
struct MenuBarPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    /// 메뉴바에서 배포까지 눌러 볼 앱은 몇 개면 충분하다 — 그 이상은 고르는 화면이라 창의 몫이다
    private static let maxRows = 5

    private var ready: [AppStatus] { store.statuses.filter { $0.deployable } }
    private var blocked: [AppStatus] { store.statuses.filter(AppFilter.blocked.matches) }
    private var reviewing: [AppStatus] { store.statuses.filter(\.inReview) }
    private var fixable: [AppStatus] { store.statuses.filter(AppFilter.fixable.matches) }
    private var busy: Bool { store.job?.running == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            // 도는 동안에만 진행 화면을 보여 준다.
            // job 은 끝나도 남아 있어서, progress 유무로 가르면 지난 배포의 진행 막대가
            // 다음 배포까지 메뉴바에 눌러앉는다 — 오래된 화면은 틀린 화면이다.
            if let job = store.job, job.running {
                runningSection(job)
            } else {
                if let failed = store.job, let err = failed.failure { failureBanner(err) }
                idleSection
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // ── 맨 윗줄: 지금 상태 한 문장 ────────────────────────────────────
    private var header: some View {
        HStack(spacing: 8) {
            Text(headline)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button {
                Task { await store.refresh(fresh: true, pull: true) }
            } label: {
                if store.loading { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.borderless)
            .disabled(store.loading)
            .help("상태 다시 조회")
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private var headline: String {
        if busy { return "배포 중" }
        if store.statuses.isEmpty { return store.loading ? "앱을 찾는 중…" : "관리 중인 앱 없음" }
        if ready.isEmpty { return "지금 배포할 앱 없음" }
        return "\(ready.count)개 배포 가능"
    }

    // ── 배포 중: 이 화면이 존재하는 첫 번째 이유 ──────────────────────
    // 창을 닫아 놓고도 "지금 어디쯤인가" 를 알 수 있어야 메뉴바가 쓸모를 갖는다.
    @ViewBuilder private func runningSection(_ job: Job) -> some View {
        DeployProgressPanel(job: job, compact: true)
        HStack(spacing: 6) {
            Button {
                open("log")
            } label: {
                Label("로그 보기", systemImage: "text.alignleft").font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            Button("콘솔 열기") { open("dashboard") }
                .buttonStyle(.bordered).controlSize(.small)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    // 마지막 배포가 깨진 채로 끝났으면 그건 알고 있어야 한다.
    // 진행 화면은 사라져도 실패 사실은 남긴다 — 다음에 열었을 때 아무 일 없었던 듯하면 안 된다.
    @ViewBuilder private func failureBanner(_ err: DeployError) -> some View {
        Button { open("log") } label: {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.caption).foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(err.app) · \(err.stage) 에서 멈췄습니다")
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Text(err.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10))
        }
        .buttonStyle(.plain)
        .help("로그에서 무엇이 멈췄는지 봅니다")
    }

    // ── 대기 중: 지금 누를 수 있는 것만 ───────────────────────────────
    @ViewBuilder private var idleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !ready.isEmpty {
                ForEach(ready.prefix(Self.maxRows)) { st in
                    readyRow(st)
                    Divider().padding(.leading, 12)
                }
                if ready.count > Self.maxRows {
                    Button {
                        focus(.ready)
                    } label: {
                        Text("외 \(ready.count - Self.maxRows)개 더 — 콘솔에서 보기")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                Button {
                    open("log")
                    store.deployAll(lane: .appstore)
                } label: {
                    Label("전체 배포 (\(ready.count))", systemImage: "square.stack.3d.up.fill")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.green).controlSize(.small)
                .padding(.horizontal, 12).padding(.vertical, 8)
            } else {
                Text(emptyNote)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }

            // 심사 중인 앱 — 여기서 새 빌드를 올리면 그 심사가 취소된다.
            // 배포 목록에는 안 나오지만 "지금 애플이 보고 있는 것" 은 늘 알고 있어야 한다.
            if !reviewing.isEmpty {
                Divider()
                ForEach(reviewing.prefix(3)) { st in
                    HStack(spacing: 7) {
                        Circle().fill(AppFilter.review.color).frame(width: 6, height: 6)
                        Text(st.name).font(.caption.weight(.medium)).lineLimit(1)
                        Text("v\(st.reviewVersion ?? st.localVersion ?? "?")")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(st.reviewLabel ?? "심사 중")
                            .font(.caption2).foregroundStyle(AppFilter.review.color)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
            }

            // 나머지는 세어서 보여 주기만 하고, 누르면 창에서 그 분류만 걸어 준다.
            // 메뉴바에서 고치게 하면 결국 창을 그대로 옮겨 놓게 된다.
            if !blocked.isEmpty || !fixable.isEmpty {
                Divider()
                HStack(spacing: 6) {
                    if !blocked.isEmpty { countChip(.blocked, blocked.count) }
                    if !fixable.isEmpty { countChip(.fixable, fixable.count) }
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
            }
        }
    }

    private var emptyNote: String {
        if !blocked.isEmpty { return "막힌 앱 \(blocked.count)개가 있습니다 — 콘솔에서 이유를 볼 수 있습니다." }
        if !reviewing.isEmpty { return "심사 중인 앱만 있습니다. 지금 올리면 심사가 취소됩니다." }
        return "스토어와 같은 버전입니다 — 올릴 변경이 없습니다."
    }

    // ── 배포 가능한 앱 한 줄: 이름 · 버전 변화 · [배포] ────────────────
    @ViewBuilder private func readyRow(_ st: AppStatus) -> some View {
        HStack(spacing: 8) {
            Circle().fill(AppFilter.ready.color).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(st.name).font(.caption.weight(.semibold)).lineLimit(1)
                Text(versionLine(st))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("배포") {
                guard let app = store.app(named: st.path) else { return }
                open("log")
                store.startDeploy(app, lane: .appstore, versionBump: nil)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(busy)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func versionLine(_ st: AppStatus) -> String {
        let local = st.localVersion ?? "?"
        guard let live = st.liveVersion else { return "v\(local) · 스토어 미등록" }
        if live == local {
            // 같은 버전을 다시 올리는 경우 — 달라지는 건 빌드번호다
            return "v\(local) · 빌드 \(st.localBuild ?? "?") 재업로드"
        }
        return "v\(live) → v\(local)"
    }

    @ViewBuilder private func countChip(_ f: AppFilter, _ n: Int) -> some View {
        Button { focus(f) } label: {
            HStack(spacing: 4) {
                Text("\(n)").font(.caption.weight(.bold).monospacedDigit())
                Text(f.label).font(.caption)
            }
            .foregroundStyle(f.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(f.color.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("콘솔에서 \(f.label) 앱만 보기")
    }

    // ── 맨 아랫줄: 창으로 가는 문 ─────────────────────────────────────
    private var footer: some View {
        HStack(spacing: 10) {
            Button { open("dashboard") } label: {
                Label("배포 콘솔", systemImage: "macwindow").font(.caption)
            }
            .buttonStyle(.plain)
            Button { open("guide") } label: {
                Label("사용법", systemImage: "questionmark.circle").font(.caption)
            }
            .buttonStyle(.plain)
            Spacer()
            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // 메뉴바에서 연 창은 다른 앱 뒤에 숨어 열린다 — 눌렀는데 아무 일도 안 일어난 것처럼 보인다
    private func open(_ id: String) {
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func focus(_ f: AppFilter) {
        store.focusFilter = f
        open("dashboard")
    }
}

// 메뉴바 아이콘 자체가 상태를 말한다.
//
// 아이콘만 있으면 눌러 보기 전에는 아무것도 알 수 없다. 메뉴바에 상주하는 이유는
// **누르지 않고도 아는 것**이라, 배포 중이면 몇 칸까지 왔는지, 아니면 지금 올릴 게
// 몇 개인지를 아이콘 옆에 붙인다. 올릴 게 없으면 숫자도 없다 — 늘 켜져 있는 배지는
// 곧 배경이 되어 아무도 안 본다.
struct MenuBarLabel: View {
    @ObservedObject var store: Store

    var body: some View {
        HStack(spacing: 3) {
            Image("MenuBarIcon").renderingMode(.template)
            if let p = store.job?.progress, store.job?.running == true {
                Text("\(p.finishedCount)/\(p.steps.count)")
                    .font(.caption2.monospacedDigit())
            } else {
                let n = store.statuses.filter { $0.deployable }.count
                if n > 0 { Text("\(n)").font(.caption2.monospacedDigit()) }
            }
        }
    }
}
