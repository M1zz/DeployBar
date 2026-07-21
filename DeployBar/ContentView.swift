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

            if store.loading && store.statuses.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("상태 조회 중… 첫 조회는 수십 초").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            } else {
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
                .frame(maxHeight: 460)
            }

            Divider()
            HStack {
                Button("종료") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption)
                Spacer()
                Text("\(store.statuses.count)개 앱").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .frame(width: 460)
        .task { if store.statuses.isEmpty { await store.refresh(fresh: false) } }
    }
}

struct CompactRow: View {
    let status: AppStatus
    let openLog: () -> Void
    let openNotes: () -> Void
    @EnvironmentObject var store: Store

    private var color: Color {
        switch status.state {
        case .dev: return .gray
        case .ready: return .orange
        case .deployed: return .green
        case .error: return .red
        }
    }

    private var detail: String {
        if status.state == .error { return status.error ?? "오류" }
        let local = "v\(status.localVersion ?? "?")(\(status.localBuild ?? "?"))"
        let live = status.liveVersion.map { "스토어 v\($0)" } ?? "미등록"
        let dirty = status.dirty ? " ✎" : ""
        return "\(local) · \(live)\(dirty)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(status.name).font(.system(size: 13, weight: .semibold))
                    Text(status.state.label).font(.caption2.weight(.medium)).foregroundStyle(color)
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(status.state == .error ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if status.state != .error {
                Button {
                    openLog()
                    if let app = store.app(named: status.path) { store.startDeploy(app, lane: .beta) }
                } label: {
                    Text("배포").frame(minWidth: 34)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(store.job?.running == true)

                Button {
                    if let app = store.app(named: status.path) {
                        openNotes()
                        Task { await store.loadNotes(app) }
                    }
                } label: {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("릴리즈노트")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
