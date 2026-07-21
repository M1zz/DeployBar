import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("배포 콘솔").font(.headline)
                    Text("fastlane 없이 · App Store Connect").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refresh(fresh: true) }
                } label: {
                    if store.loading {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.loading)
            }
            .padding(14)
            Divider()

            if store.loading && store.statuses.isEmpty {
                loadingRow
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(store.statuses) { st in
                            AppRow(status: st, openLog: { openWindow(id: "log") }, openNotes: { openWindow(id: "notes") })
                        }
                    }
                    .padding(12)
                }
            }

            Divider()
            HStack {
                Button("종료") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).font(.caption)
                Spacer()
                if store.job?.running == true {
                    Button("로그 보기") { openWindow(id: "log") }
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .frame(width: 380)
        .task { if store.statuses.isEmpty { await store.refresh(fresh: false) } }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("상태 조회 중… (첫 조회는 빌드 설정 해석으로 수십 초)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

struct AppRow: View {
    let status: AppStatus
    let openLog: () -> Void
    let openNotes: () -> Void
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.name).font(.system(size: 14, weight: .semibold))
                    Text(status.bundleId ?? status.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Badge(state: status.state)
            }

            if status.state == .error {
                Text(status.error ?? "오류").font(.caption).foregroundStyle(.red)
            } else {
                HStack(spacing: 14) {
                    infoCol("로컬", "v\(status.localVersion ?? "?")·\(status.localBuild ?? "?")")
                    infoCol("App Store", status.liveVersion.map { "v\($0)" } ?? "—")
                    infoCol("브랜치", (status.branch ?? "—") + (status.dirty ? " ✎" : ""))
                }
                if let e = status.ascError {
                    Text(e).font(.caption2).foregroundStyle(.orange)
                }
                HStack(spacing: 8) {
                    Button {
                        openLog()
                        if let app = store.app(named: status.path) { store.startDeploy(app, lane: .beta) }
                    } label: {
                        Text("배포하기").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.job?.running == true)

                    Button("릴리즈노트") {
                        if let app = store.app(named: status.path) {
                            openNotes()
                            Task { await store.loadNotes(app) }
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private func infoCol(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).fontWeight(.medium).monospacedDigit()
        }
    }
}

struct Badge: View {
    let state: DeployState
    var color: Color {
        switch state {
        case .dev: return .gray
        case .ready: return .orange
        case .deployed: return .green
        case .error: return .red
        }
    }
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(state.label).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}
