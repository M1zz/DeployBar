import SwiftUI

// 배포가 지금 어디까지 왔는지 보여 주는 패널. 로그 창 맨 위에 붙는다.
//
// 답해야 하는 질문은 셋뿐이다.
//   1) 돌고 있나, 끝났나, 깨졌나?      → 맨 윗줄 한 문장 + 막대
//   2) 지금 뭘 하고 있나?              → 도는 칸의 이름 + 설명 + 흐른 시간
//   3) 얼마나 남았나?                  → 시작할 때부터 전체 칸이 다 보인다
//
// 특히 3번이 중요하다. 로그는 지나간 것만 보여 주기 때문에, 3분째 조용한 archive 앞에서
// "멈춘 건가" 를 묻게 만든다. 남은 칸이 회색으로 미리 서 있으면 그 질문 자체가 안 생긴다.
struct DeployProgressPanel: View {
    @ObservedObject var job: Job
    /// 메뉴바 팝오버처럼 좁은 자리에서는 칸 목록을 접고 시작한다 (필요하면 그 자리에서 펼친다)
    var compact = false
    /// 도는 동안 흐른 시간이 실제로 움직이게 한다 — 숫자가 안 움직이면 멈춘 걸로 읽힌다
    @State private var expanded: Bool

    init(job: Job, compact: Bool = false) {
        self.job = job
        self.compact = compact
        _expanded = State(initialValue: !compact)
    }

    private var progress: DeployProgress? { job.progress }

    // ── 대비 ─────────────────────────────────────────────────────────
    // .secondary(≈50%)·.tertiary(≈25%) 는 흰 바탕을 전제한 값이다. 이 패널은 그 위에
    // 색조 배경(bannerColor 10%)을 한 겹 더 깔기 때문에, 그 위의 회색 글씨는 남는 대비가
    // 거의 없다 — 설명도 흐른 시간도 남은 칸 이름도 화면에서 사라진다.
    // 배포 중에 제일 알고 싶은 것이 바로 그 글자들이라, 여기서는 반투명 등급 대신
    // 불투명도를 직접 정한다.
    private let noteInk = Color.primary.opacity(0.78)     // 칸 설명·힌트
    private let dimInk = Color.primary.opacity(0.62)      // 흐른 시간·개수
    private let pendingInk = Color.primary.opacity(0.55)  // 아직 시작 안 한 칸

    var body: some View {
        if let p = progress {
            // 1초마다 다시 그린다: 흐른 시간과 막대가 같이 움직여야 '살아 있음' 이 보인다
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let now = job.running ? ctx.date : (p.steps.compactMap(\.endedAt).max() ?? ctx.date)
                VStack(alignment: .leading, spacing: 9) {
                    headline(p, now: now)
                    bar(p, now: now)
                    if expanded { stageList(p, now: now) }
                }
                .padding(.horizontal, 12).padding(.vertical, compact ? 8 : 10)
                .background(bannerColor(p).opacity(0.07))
            }
        }
    }

    // ── 한 문장으로: 돌고 있나 / 끝났나 / 깨졌나 ─────────────────────────
    @ViewBuilder private func headline(_ p: DeployProgress, now: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: bannerIcon(p))
                .foregroundStyle(bannerColor(p))
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 2) {
                Text(headlineText(p))
                    .font(.callout.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let cur = p.current {
                    Text(cur.stage.hint)
                        .font(.caption).foregroundStyle(noteInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(p.finishedCount)/\(p.steps.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(dimInk)
                Text(totalElapsed(p, now: now))
                    .font(.caption2.monospacedDigit()).foregroundStyle(dimInk)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(dimInk)
            }
            .buttonStyle(.plain)
            .help(expanded ? "단계 접기" : "단계 펼치기")
        }
    }

    private func headlineText(_ p: DeployProgress) -> String {
        let who = job.batch.map { "[\($0.index)/\($0.total)] \($0.name) · " } ?? ""
        if let f = p.failed { return "\(who)\(f.stage.title) 에서 멈췄습니다" }
        if let c = p.current { return "\(who)\(c.stage.title) 진행 중" }
        if job.running { return "\(who)시작하는 중" }
        if case .incomplete? = job.verdict { return "\(who)미완 — 업로드는 됐지만 심사에 내지 못했습니다" }
        let step = { (s: DeployStage) in p.steps.first { $0.stage == s }?.state }
        if step(.submit) == .done { return "\(who)배포 완료 — 심사에 냈습니다" }
        if step(.attach) == .done { return "\(who)배포 완료 — 빌드 연결까지 (심사 제출은 \(p.steps.first { $0.stage == .submit }?.note ?? "안 함"))" }
        return "\(who)배포 완료 — 업로드까지 끝났습니다"
    }

    private func bannerIcon(_ p: DeployProgress) -> String {
        if p.failed != nil { return "exclamationmark.octagon.fill" }
        if job.running { return "arrow.triangle.2.circlepath" }
        if case .incomplete? = job.verdict { return "exclamationmark.triangle.fill" }
        return "checkmark.circle.fill"
    }
    private func bannerColor(_ p: DeployProgress) -> Color {
        if p.failed != nil { return .orange }
        if !job.running, case .incomplete? = job.verdict { return .orange }
        return job.running ? .blue : .green
    }

    private func totalElapsed(_ p: DeployProgress, now: Date) -> String {
        guard let start = p.steps.compactMap(\.startedAt).min() else { return "" }
        return now.timeIntervalSince(start).stageClock
    }

    // ── 막대 ─────────────────────────────────────────────────────────
    @ViewBuilder private func bar(_ p: DeployProgress, now: Date) -> some View {
        // 칸 수가 아니라 '대개 걸리는 시간' 으로 채운다 — archive 가 절반을 차지한다.
        // 그래야 막대가 반쯤에서 오래 머무는 게 고장이 아니라 사실이 된다.
        ProgressView(value: p.fraction(now: now))
            .progressViewStyle(.linear)
            .tint(bannerColor(p))
    }

    // ── 칸 목록 ──────────────────────────────────────────────────────
    @ViewBuilder private func stageList(_ p: DeployProgress, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(p.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    mark(step)
                        .frame(width: 13, alignment: .center)
                    Text(step.stage.title)
                        .font(.caption.weight(step.state == .running ? .semibold : .regular))
                        .foregroundStyle(titleColor(step))
                        .frame(width: compact ? 78 : 96, alignment: .leading)
                    Text(step.note ?? (step.state == .running ? step.stage.hint : ""))
                        .font(.caption)
                        .foregroundStyle(noteInk)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let e = step.elapsed(now: now), step.state != .pending, e >= 1 {
                        Text(e.stageClock)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(dimInk)
                    }
                }
            }
        }
    }

    @ViewBuilder private func mark(_ step: StageStep) -> some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(pendingInk)
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.8)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
        case .skipped:
            // 건너뜀은 실패가 아니다 — 초록도 빨강도 아닌 자리를 준다
            Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(pendingInk)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
        }
    }

    private func titleColor(_ step: StageStep) -> Color {
        switch step.state {
        case .pending, .skipped: return pendingInk
        case .running:           return .primary
        case .done:              return .primary
        case .failed:            return .red
        }
    }
}

// 배포 대기열. 전체 배포나 플랫폼이 둘 이상인 배포에서 진행 패널 위에 붙는다.
//
// 진행 패널이 "이 바퀴가 어디까지 왔나" 를 말한다면, 이쪽은 "줄 전체가 어떻게 섰나" 를 말한다.
// 로그의 "배포 순서: A → B → C" 한 줄로는 지금 몇 번째이고 뒤에 무엇이 밀려 있는지 보이지 않았다.
//   지금   — 도는 바퀴 (굵게)
//   다음   — 아직 안 돈 바퀴, 그 뒤에 심사 제출 차례를 기다리는 바퀴 (실제로 도는 순서)
//   끝남   — 결과 표시만 한 줄로 (실패 · 미완은 빨강 · 주황으로 눈에 띄게)
struct DeployQueueView: View {
    @ObservedObject var job: Job
    var compact = false
    @State private var showAllNext = false

    private typealias Item = Job.QueueItem
    private let ink = Color.primary.opacity(0.78)
    private let dim = Color.primary.opacity(0.55)

    private var now: [Item] { job.queue.filter { $0.state == .running } }
    /// 실제로 돌 순서: 업로드 차례 → 심사 제출 차례
    private var next: [Item] { job.queue.filter { $0.state == .waiting } + job.queue.filter { $0.state == .uploaded } }
    private var finished: [Item] { job.queue.filter { [.done, .incomplete, .failed, .skipped].contains($0.state) } }

    var body: some View {
        if !job.queue.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                header
                ForEach(now) { row($0, emphasis: true) }
                nextList
                if !finished.isEmpty { finishedLine }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.number").font(.system(size: 11, weight: .semibold)).foregroundStyle(ink)
            Text("배포 대기열").font(.caption.weight(.semibold))
            Text("끝 \(finished.count) · 지금 \(now.count) · 남음 \(next.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(ink)
            Spacer(minLength: 4)
            if !job.queueExcluded.isEmpty {
                Text("빠진 앱 \(job.queueExcluded.count)")
                    .font(.caption).foregroundStyle(dim)
                    .help(job.queueExcluded.joined(separator: "\n"))
            }
        }
    }

    @ViewBuilder private var nextList: some View {
        let limit = compact ? 3 : 6
        let shown = showAllNext ? next : Array(next.prefix(limit))
        ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("\(i + 1)").font(.caption2.monospacedDigit()).foregroundStyle(dim)
                    .frame(width: 13, alignment: .trailing)
                Text(item.label).font(.caption).foregroundStyle(ink).lineLimit(1)
                if item.state == .uploaded {
                    Text("업로드 끝 · 심사 제출 차례").font(.caption2).foregroundStyle(.blue)
                }
                Spacer(minLength: 0)
            }
        }
        if next.count > limit {
            Button(showAllNext ? "접기" : "외 \(next.count - limit)개 더 보기") { showAllNext.toggle() }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
                .padding(.leading, 20)
        }
    }

    private func row(_ item: Item, emphasis: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            ProgressView().controlSize(.mini).scaleEffect(0.8).frame(width: 13)
            Text(item.label).font(.caption.weight(.semibold)).lineLimit(1)
            if let n = item.note { Text(n).font(.caption).foregroundStyle(ink).lineLimit(1) }
            Spacer(minLength: 0)
        }
    }

    /// 끝난 바퀴는 결과 표시만 — 길게 늘어놓으면 '다음' 이 화면 밖으로 밀려난다
    private var finishedLine: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(finished) { item in
                    HStack(spacing: 3) {
                        Image(systemName: icon(item.state)).font(.system(size: 9, weight: .bold))
                            .foregroundStyle(color(item.state))
                        Text(item.label).font(.caption2)
                            .foregroundStyle(item.state == .done || item.state == .skipped ? dim : color(item.state))
                    }
                    .help(item.note ?? "")
                }
            }
        }
    }

    private func icon(_ s: Item.State) -> String {
        switch s {
        case .done: return "checkmark"
        case .incomplete: return "exclamationmark.triangle.fill"
        case .failed: return "xmark"
        default: return "minus"
        }
    }
    private func color(_ s: Item.State) -> Color {
        switch s {
        case .done: return .green
        case .incomplete: return .orange
        case .failed: return .red
        default: return dim
        }
    }
}
