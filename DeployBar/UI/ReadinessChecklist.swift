import SwiftUI

// 카드를 펼쳤을 때 나오는 "배포에 필요한 것들".
//
// 손볼 것부터 위에, 통과한 것은 한 줄로 접어 둔다 —
// 다 됐는지는 N/M 숫자로 확인되므로 ✅ 를 여덟 줄 늘어놓을 이유가 없다.
struct ReadinessChecklist: View {
    let status: AppStatus
    @EnvironmentObject var store: Store
    /// 통과한 항목까지 펼칠지 (기본은 접어 둠)
    @State private var showPassed = false
    /// 방금 어떤 프롬프트를 복사했는지 ("*" = 남은 것 전부)
    @State private var copiedKey: String?

    private var readiness: Readiness { status.readiness }
    private var pending: [ReadyItem] { readiness.sorted.filter { $0.level != .ok } }

    // 잠긴 이유를 손으로 옮겨 적지 않게 — 체크리스트를 그대로 지시문으로 만든다
    private func copyPrompt(_ item: ReadyItem?) {
        let key = item?.key ?? "*"
        Clipboard.copy(readiness.promptText(for: status, only: item))
        copiedKey = key
        Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if copiedKey == key { copiedKey = nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.bottom, 2)
            progressRow
            ForEach(pending) { row($0) }
            if readiness.passedCount > 0 { passedSection }
        }
        .padding(.horizontal, 14).padding(.bottom, 13)
    }

    private var progressRow: some View {
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
                    Text(copiedKey == "*" ? "복사됨" : "해결 프롬프트").font(.caption2)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("남은 항목을 그대로 지시문으로 만들어 복사합니다 — Claude Code 등에 붙여넣으면 됩니다")
            }
        }
    }

    /// 통과한 것은 '다 됐다' 만 확인되면 되므로 한 줄로 접어 둔다
    private var passedSection: some View {
        Group {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { showPassed.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text("통과한 \(readiness.passedCount)가지").font(.caption)
                    Image(systemName: showPassed ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(.green)
            }
            .buttonStyle(.plain)
            .padding(.top, pending.isEmpty ? 0 : 2)

            if showPassed {
                ForEach(readiness.passed) { row($0) }
            }
        }
    }

    private func row(_ item: ReadyItem) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: item.icon)
                .font(.caption)
                .foregroundStyle(color(item))
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
            trailing(item)
        }
        .padding(.vertical, item.isBlocker ? 5 : 0)
        .padding(.horizontal, item.isBlocker ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(item.isBlocker ? Color.orange.opacity(0.10) : .clear)
        )
    }

    /// 버튼 한 번으로 되면 그 버튼을, 아니면 그 항목만 복사하는 아이콘을.
    /// (자동으로 되는 항목에까지 프롬프트를 붙이면 버튼이 두 개씩 늘어선다)
    @ViewBuilder private func trailing(_ item: ReadyItem) -> some View {
        if let fix = item.fix, fix != .reveal, let app = store.app(named: status.path) {
            Button { store.apply(fix, to: app) } label: {
                if store.isApplying(fix, status.path) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(fix.label).font(.caption2)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(store.job?.running == true || store.fixing.contains(status.path))
        } else if item.level != .ok {
            Button { copyPrompt(item) } label: {
                Image(systemName: copiedKey == item.key ? "checkmark" : "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("이 항목만 지시문으로 복사")
        }
    }

    private func color(_ item: ReadyItem) -> Color {
        switch item.level {
        case .ok: return .green
        case .need: return .blue
        case .blocked: return .orange
        }
    }
}
