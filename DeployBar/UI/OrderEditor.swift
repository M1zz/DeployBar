import SwiftUI

// 배포 순서 편집 — 드래그(List 의 onMove)와 ▲▼ 버튼을 함께 둔다.
// 드래그가 안 잡히는 상황에서도 순서를 바꿀 수 있어야 하므로 버튼을 없애지 않는다.
struct OrderEditor: View {
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
