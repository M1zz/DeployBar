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

    /// 심사 현황은 몇 줄이면 충분하다 — 그 이상은 창의 몫이다
    private static let maxRows = 6

    private var ready: [AppStatus] { store.statuses.filter { $0.deployable } }
    private var blocked: [AppStatus] { store.statuses.filter(AppFilter.blocked.matches) }
    private var reviewing: [AppStatus] { store.statuses.filter(\.inReview) }
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
        DeployQueueView(job: job, compact: true)
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

    // ── 대기 중: 현황 ────────────────────────────────────────────────
    // 예전엔 배포 가능한 앱마다 [배포] 버튼을 늘어놨지만, 한 앱씩 고르는 일은 창에서 했다.
    // 메뉴바를 여는 이유는 "애플이 지금 무엇을 보고 있고, 그사이 무슨 일이 있었나" 다.
    // 그래서 분류별 개수 → 심사 현황 → 최근 소식 순서로 보이고, 누르는 일은 [전체 배포] 하나만 둔다.
    @ViewBuilder private var idleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                tile(.ready, ready.count)
                tile(.review, reviewing.count)
                tile(.blocked, blocked.count)
                tile(.done, store.statuses.filter(AppFilter.done.matches).count)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

            if !reviewRows.isEmpty {
                Divider()
                sectionTitle("심사")
                ForEach(reviewRows.prefix(Self.maxRows)) { r in
                    HStack(spacing: 7) {
                        Circle().fill(r.color).frame(width: 6, height: 6)
                        Text(r.name).font(.caption.weight(.medium)).lineLimit(1)
                        if let p = r.platform {
                            Text(p).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Text("v\(r.version)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(r.label).font(.caption2.weight(.semibold)).foregroundStyle(r.color)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
                if reviewRows.count > Self.maxRows {
                    Button { focus(.review) } label: {
                        Text("외 \(reviewRows.count - Self.maxRows)개 — 콘솔에서 보기")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
                Spacer().frame(height: 6)
            }

            if !store.notices.isEmpty {
                Divider()
                sectionTitle("최근 소식")
                ForEach(store.notices.prefix(3)) { n in
                    HStack(spacing: 7) {
                        Circle().fill(noticeColor(n.kind)).frame(width: 6, height: 6)
                        Text(n.title).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(ago(n.at)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 3)
                }
                Spacer().frame(height: 6)
            }

            if !ready.isEmpty {
                Divider()
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
            }
        }
    }

    /// 분류 하나 — 큰 숫자와 이름. 누르면 콘솔에서 그 분류만 걸어 준다.
    private func tile(_ f: AppFilter, _ n: Int) -> some View {
        Button { focus(f) } label: {
            VStack(spacing: 1) {
                Text("\(n)").font(.title3.weight(.semibold).monospacedDigit())
                Text(f.label).font(.caption2)
            }
            .foregroundStyle(n > 0 ? f.color : Color.secondary.opacity(0.5))
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill((n > 0 ? f.color : .secondary).opacity(0.09)))
        }
        .buttonStyle(.plain)
        .help("콘솔에서 \(f.label) 앱만 보기")
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 3)
    }

    /// 심사 현황 한 줄 — 플랫폼이 둘 이상인 앱은 플랫폼마다. 거부된 것이 맨 위다(할 일이 생긴 것).
    private struct ReviewRow: Identifiable {
        let name: String, platform: String?, version: String, state: String
        var id: String { "\(name)-\(platform ?? "")" }
        var label: String { ASCState.label(state) ?? state }
        var rejected: Bool { ASCState.isRejected(state) }
        var color: Color { rejected ? .red : AppFilter.review.color }
    }
    private var reviewRows: [ReviewRow] {
        var out: [ReviewRow] = []
        for st in store.statuses {
            let watch = { (s: String) in ASCState.isSubmitted(s) || ASCState.isRejected(s) }
            if let rows = st.platformRows, rows.count > 1 {
                for r in rows {
                    if let s = r.reviewState, watch(s) {
                        out.append(.init(name: st.name, platform: r.platform, version: r.reviewVersion ?? "?", state: s))
                    }
                }
            } else if let s = st.reviewState, watch(s) {
                out.append(.init(name: st.name, platform: nil, version: st.reviewVersion ?? "?", state: s))
            }
        }
        return out.sorted { $0.rejected && !$1.rejected }
    }

    private func noticeColor(_ k: StatusChange.Kind) -> Color {
        switch k { case .good: return .green; case .warn: return .orange; case .info: return .blue }
    }
    private func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
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
