import SwiftUI

// 콘솔 맨 위에 쌓이는 변화 알림.
//
// 시스템 알림은 권한이 꺼져 있으면 아예 안 뜨고, 떠도 몇 초 뒤 사라진다.
// 기다리던 소식(심사 통과·거부·출시)일수록 그렇게 지나가면 안 되므로,
// 여기서는 **사람이 닫을 때까지** 남는다. 시스템 알림은 앱이 뒤에 있을 때를 위한 보조다.
struct ChangeBanner: View {
    @EnvironmentObject var store: Store
    /// 셋보다 많으면 접어 둔다 — 목록을 밀어내면 그것대로 방해가 된다
    @State private var expanded = false

    private var shown: [StatusChange.Event] {
        expanded ? store.notices : Array(store.notices.prefix(3))
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(shown) { notice in
                row(notice)
                Divider().opacity(0.5)
            }
            if store.notices.count > 3 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "접기" : "이전 \(store.notices.count - 3)건 더 보기")
                        .font(.caption2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Divider().opacity(0.5)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private func row(_ n: StatusChange.Event) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(n.kind))
                .frame(width: 3)
                .padding(.vertical, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(n.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(color(n.kind))
                    Text(ago(n.at))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text(n.body)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if store.notices.count > 1 {
                Button("모두 지우기") { withAnimation { store.dismissAll() } }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .opacity(n.id == store.notices.first?.id ? 1 : 0)
                    .disabled(n.id != store.notices.first?.id)
            }
            Button {
                withAnimation { store.dismiss(n.id) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("이 알림 닫기")
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(n.kind).opacity(0.10))
    }

    private func color(_ kind: StatusChange.Kind) -> Color {
        switch kind {
        case .good: return .green
        case .warn: return .orange
        case .info: return .blue
        }
    }

    /// "방금 · 3분 전 · 2시간 전" — 언제 온 소식인지가 판단에 필요하다
    private func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "방금" }
        if s < 3600 { return "\(s / 60)분 전" }
        if s < 86400 { return "\(s / 3600)시간 전" }
        return "\(s / 86400)일 전"
    }
}
