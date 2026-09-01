import SwiftUI
import Translation

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
                    let bad = job.error != nil || job.failure != nil
                    Image(systemName: bad ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(bad ? .red : .green)
                }
            }
            .padding(12)
            Divider()

            // 실패했으면 로그를 뒤지기 전에 '무엇이 / 왜 / 그래서 뭘 하면 되는지' 부터 보여 준다
            if let f = store.job?.failure, store.job?.running != true {
                FailurePanel(failure: f)
                Divider()
            }

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
        // 배포 자동 릴리즈노트의 온디바이스 번역 실행 지점
        .translationTask(store.pendingTranslation.map {
            TranslationSession.Configuration(
                source: Locale.Language(identifier: $0.source),
                target: Locale.Language(identifier: $0.target))
        }) { session in
            guard let req = store.pendingTranslation else { return }
            let out = try? await session.translate(req.text).targetText
            store.fulfillTranslation(out)
        }
    }
}


// 실패했을 때 뜨는 패널. 로그 수백 줄에서 첫 error: 를 찾아내는 건 사람이 할 일이 아니다.
private struct FailurePanel: View {
    let failure: DeployError
    @EnvironmentObject var store: Store
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failure.stage) 단계에서 멈췄습니다")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(failure.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let fix = failure.fix, let app = store.app(named: failure.path) {
                    Button(fix.label) {
                        switch fix {
                        case .configure: Task { await store.autoConfigure(app) }
                        case .bumpPatch: Task { await store.bumpVersion(app, .patch) }
                        case .openNotes:
                            store.openNotesSignal += 1
                            Task { await store.loadNotes(app) }
                        case .reveal: NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: app.path)
                        case .ignoreNoise: Task { await store.ignoreXcodeNoise(app) }
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(failure.promptText, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
                } label: {
                    Label(copied ? "복사됨" : "해결 프롬프트",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("실패 내용과 도구 출력을 그대로 지시문으로 만들어 복사합니다 — Claude Code 등에 붙여넣으면 됩니다")

                Button {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: failure.path)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("앱 폴더 열기")
            }

            if !failure.todo.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("지금 할 일").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(Array(failure.todo.enumerated()), id: \.offset) { i, t in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Text(t).font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !failure.detail.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("도구가 한 말").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(failure.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
    }
}
