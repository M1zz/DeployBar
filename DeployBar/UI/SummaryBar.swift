import SwiftUI

// 상단 요약 = 필터. 세기만 하고 못 누르면 40개 목록에서 그 3개를 눈으로 찾아야 한다.
struct SummaryBar: View {
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
