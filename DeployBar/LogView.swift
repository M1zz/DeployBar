import SwiftUI

struct LogView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.job?.title ?? "배포 로그").font(.headline)
                Spacer()
                if store.job?.running == true {
                    ProgressView().controlSize(.small)
                    Text("진행 중").font(.caption).foregroundStyle(.secondary)
                } else if let job = store.job {
                    Image(systemName: job.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(job.error == nil ? .green : .red)
                }
            }
            .padding(12)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array((store.job?.lines ?? []).enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(size: 11.5, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                    }
                    .padding(12)
                }
                .background(Color.black.opacity(0.9))
                .onChange(of: store.job?.lines.count) { _ in
                    if let n = store.job?.lines.count, n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                }
            }
        }
        .foregroundStyle(Color(white: 0.85))
        .frame(minWidth: 480, minHeight: 320)
    }
}
