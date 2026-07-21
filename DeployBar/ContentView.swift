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

            Divider()
            HStack {
                Text("\(store.statuses.count)개 앱").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("종료", systemImage: "power")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .keyboardShortcut("q", modifiers: .command)
                .help("배포 콘솔 종료 (⌘Q)")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 460)
        .onAppear { store.loadIfNeeded() }
    }
}

struct CompactRow: View {
    let status: AppStatus
    let openLog: () -> Void
    let openNotes: () -> Void
    @EnvironmentObject var store: Store

    private var color: Color {
        switch status.state {
        case .loading: return .secondary
        case .dev: return .gray
        case .ready: return .orange
        case .deployed: return .green
        case .error: return .red
        }
    }

    private var detail: String {
        if status.state == .loading { return "조회 중…" }
        if status.state == .error { return status.error ?? "오류" }
        let local = "v\(status.localVersion ?? "?")(\(status.localBuild ?? "?"))"
        let live = status.liveVersion.map { "스토어 v\($0)" } ?? "미등록"
        let dirty = status.dirty ? " ✎" : ""
        return "\(local) · \(live)\(dirty)"
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(color).frame(width: 11, height: 11)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(status.name).font(.system(size: 15, weight: .semibold))
                    Text(status.state.label).font(.caption.weight(.semibold)).foregroundStyle(color)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(status.state == .error ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if status.state == .loading {
                ProgressView().controlSize(.small)
            } else if status.state != .error {
                Button {
                    openLog()
                    if let app = store.app(named: status.path) { store.startDeploy(app, lane: .beta) }
                } label: {
                    Text("배포").frame(minWidth: 40)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
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
                .controlSize(.regular)
                .help("릴리즈노트")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}
