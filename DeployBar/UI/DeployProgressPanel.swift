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
    /// 도는 동안 흐른 시간이 실제로 움직이게 한다 — 숫자가 안 움직이면 멈춘 걸로 읽힌다
    @State private var expanded = true

    private var progress: DeployProgress? { job.progress }

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
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(bannerColor(p).opacity(0.10))
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
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(p.finishedCount)/\(p.steps.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(totalElapsed(p, now: now))
                    .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
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
        return "\(who)배포 완료 — 업로드까지 끝났습니다"
    }

    private func bannerIcon(_ p: DeployProgress) -> String {
        if p.failed != nil { return "exclamationmark.octagon.fill" }
        if job.running { return "arrow.triangle.2.circlepath" }
        return "checkmark.circle.fill"
    }
    private func bannerColor(_ p: DeployProgress) -> Color {
        if p.failed != nil { return .orange }
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
                        .frame(width: 96, alignment: .leading)
                    Text(step.note ?? (step.state == .running ? step.stage.hint : ""))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let e = step.elapsed(now: now), step.state != .pending, e >= 1 {
                        Text(e.stageClock)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(step.state == .running ? .secondary : .tertiary)
                    }
                }
            }
        }
    }

    @ViewBuilder private func mark(_ step: StageStep) -> some View {
        switch step.state {
        case .pending:
            Image(systemName: "circle").font(.system(size: 8)).foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
        case .skipped:
            // 건너뜀은 실패가 아니다 — 초록도 빨강도 아닌 자리를 준다
            Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
        case .failed:
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
        }
    }

    private func titleColor(_ step: StageStep) -> Color {
        switch step.state {
        case .pending, .skipped: return .secondary
        case .running:           return .primary
        case .done:              return .primary
        case .failed:            return .red
        }
    }
}
