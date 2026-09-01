import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var editingOrder = false
    /// 지금 걸린 필터. nil 이면 전부 보여 준다.
    @State private var filter: AppFilter?

    private func count(_ f: AppFilter) -> Int { store.statuses.filter(f.matches).count }
    private var readyCount: Int { count(.ready) }
    private var fixableCount: Int { count(.fixable) }

    /// 목록에 실제로 그릴 앱들 (필터 반영). 순서·배포 대상 판단은 늘 전체 기준이다.
    private var visible: [AppStatus] {
        guard let f = filter else { return store.statuses }
        return store.statuses.filter(f.matches)
    }

    /// '전체 배포' 에서 몇 번째로 나가는지 (배포 가능한 앱만 번호를 받는다)
    private var deployOrder: [String: Int] {
        var out: [String: Int] = [:]
        var n = 0
        for st in store.statuses where st.deployable {
            n += 1; out[st.path] = n
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 헤더 한 줄 — 요약(=필터)과 도구를 같은 줄에.
            // 제목은 창 타이틀바가 이미 '배포 콘솔' 이라 두 번 쓰지 않는다.
            HStack(spacing: 8) {
                if editingOrder {
                    Text("드래그 또는 ▲▼ 로 순서 변경 — 즉시 저장됩니다")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                } else {
                    SummaryBar(count: count, filter: $filter,
                               total: store.statuses.count, shown: visible.count,
                               loading: store.loading)
                }
                if store.job?.running == true {
                    Button { openWindow(id: "log") } label: {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("로그").font(.caption) }
                    }
                    .buttonStyle(.borderless)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { editingOrder.toggle() }
                } label: {
                    Image(systemName: editingOrder ? "checkmark" : "arrow.up.arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(store.job?.running == true)
                .help("배포 순서 정하기 — '전체 배포'가 이 순서대로 진행됩니다")

                Button { openWindow(id: "guide") } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help("사용법 · 배포에 필요한 것")
                Button {
                    Task { await store.refresh(fresh: true) }
                } label: {
                    if store.loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }
                .buttonStyle(.borderless)
                .disabled(store.loading)
                .help("상태 다시 조회")
            }
            .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 9)

            Divider()

            if editingOrder {
                OrderEditor(deployOrder: deployOrder)
                    .frame(minHeight: 220, maxHeight: 460)
            } else {
                ScrollView {
                    // 32개를 한꺼번에 그리면 스크롤이 끊긴다 — 보이는 것만 그린다
                    LazyVStack(spacing: 8) {
                        if visible.isEmpty, let f = filter {
                            VStack(spacing: 8) {
                                Text(f.emptyNote).font(.callout).foregroundStyle(.secondary)
                                Button("전체 보기") { withAnimation { filter = nil } }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                        ForEach(visible) { st in
                            AppCard(status: st,
                                    openLog: { openWindow(id: "log") },
                                    openNotes: { openWindow(id: "notes") })
                        }
                    }
                    .padding(8)
                }
                .background(Color.primary.opacity(0.035))
                .frame(minHeight: 220, idealHeight: 460, maxHeight: .infinity)
            }

            // 루트에 있는데 목록에 없는 폴더 — "내 앱이 왜 안 보이지" 를 여기서 답한다
            if !store.skipped.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.skipped) { k in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: k.fixable ? "exclamationmark.triangle.fill" : "minus.circle")
                                    .font(.caption2)
                                    .foregroundStyle(k.fixable ? .orange : .secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(k.name).font(.caption.weight(.medium))
                                    Text(k.reason).font(.caption2).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Button {
                                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: k.path)
                                } label: { Image(systemName: "folder").font(.caption2) }
                                .buttonStyle(.borderless).controlSize(.small)
                            }
                        }
                        Text("루트 밖(\(AppRepo.root) 아래가 아닌) 앱은 자동 발견되지 않습니다.")
                            .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
                    }
                    .padding(.top, 4)
                } label: {
                    Text("목록에 없는 폴더 (\(store.skipped.count))")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            if !store.hidden.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(spacing: 2) {
                        ForEach(store.hidden) { app in
                            HStack(spacing: 8) {
                                Image(systemName: "eye.slash")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(app.name).font(.subheadline)
                                Spacer()
                                Button("되돌리기") { store.unhideApp(app.path) }
                                    .buttonStyle(.borderless)
                                    .controlSize(.small)
                                    .help("다시 관리 대상으로 되돌립니다")
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("관리 안 함 (\(store.hidden.count))")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14).padding(.vertical, 6)
            }

            Divider()
            HStack(spacing: 8) {
                if editingOrder {
                    Button {
                        withAnimation { store.resetOrder() }
                    } label: {
                        Label("이름순으로", systemImage: "textformat.abc").font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("폴더 이름 오름차순으로 되돌립니다")

                    Spacer()
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { editingOrder = false }
                    } label: {
                        Label("순서 저장 완료", systemImage: "checkmark").font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .help("순서는 바꾸는 즉시 저장됩니다")
                } else {
                Button {
                    openWindow(id: "log")
                    store.deployAll(lane: .appstore)
                } label: {
                    Label("전체 배포\(readyCount > 0 ? " (\(readyCount))" : "")", systemImage: "square.stack.3d.up.fill")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .controlSize(.small)
                .disabled(store.job?.running == true || readyCount == 0)
                .help("막힌 곳이 없는 앱만 위에서부터 차례로 App Store 에 배포합니다 (순서는 ↑↓ 버튼에서)")

                if fixableCount > 0 {
                    Button {
                        openWindow(id: "log")
                        store.autoConfigureAll()
                    } label: {
                        Label("전체 자동 설정 (\(fixableCount))", systemImage: "wand.and.stars")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.job?.running == true)
                    .help("deploy.env·배포 전 검사 스크립트를 앱마다 만들어 배포를 자동화합니다")
                }

                Spacer()
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("종료", systemImage: "power").font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.red)
                .keyboardShortcut("q", modifiers: .command)
                .help("배포 콘솔 종료 (⌘Q)")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: 520)
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear { store.loadIfNeeded() }
        .onChange(of: store.openNotesSignal) { _ in openWindow(id: "notes") }
    }
}
