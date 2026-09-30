import SwiftUI
import Translation
import AppKit

struct LogView: View {
    @EnvironmentObject var store: Store
    @State private var copied: CopyKind?
    private enum CopyKind { case log, prompt }

    private func copy(_ text: String, as kind: CopyKind) {
        Clipboard.copy(text)
        copied = kind
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); if copied == kind { copied = nil } }
    }

    /// 끝났는데 성공이 아니다 — 그런데 실패 패널(구조화된 실패)이 없어 거기서 프롬프트를 못 복사하는 경우.
    /// 예: 업로드는 됐지만 심사 제출에서 멈춘 '미완'.
    private var needsHelpButton: Bool {
        guard let job = store.job, !job.running, job.failure == nil else { return false }
        switch job.verdict {
        case .success?: return false
        case .failed?, .incomplete?: return true
        case nil: return job.error != nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(store.job?.title ?? "배포 로그").font(.headline)
                Spacer()
                if store.job?.running == true {
                    ProgressView().controlSize(.small)
                    Text("진행 중").font(.caption).foregroundStyle(.secondary)
                } else if let job = store.job {
                    // 최종 판정이 있으면 그것을 따른다 — 업로드만 되고 심사에 못 낸 배포는 '완료' 가 아니다
                    let bad = job.error != nil || job.failure != nil
                    let (icon, color, label): (String, Color, String) = {
                        switch job.verdict {
                        case .failed?: return ("xmark.circle.fill", .red, "실패")
                        case .incomplete?: return ("exclamationmark.triangle.fill", .orange, "미완")
                        case .success?: return ("checkmark.circle.fill", .green, "성공")
                        case nil: return bad ? ("xmark.circle.fill", .red, "실패") : ("checkmark.circle.fill", .green, "완료")
                        }
                    }()
                    Image(systemName: icon).foregroundStyle(color)
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                if needsHelpButton, let job = store.job {
                    Button {
                        copy(job.claudePrompt, as: .prompt)
                    } label: {
                        Label(copied == .prompt ? "복사됨" : "해결 프롬프트",
                              systemImage: copied == .prompt ? "checkmark" : "sparkles")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("결과와 로그를 지시문으로 만들어 복사합니다 — Claude Code 에 붙여넣으면 됩니다")
                }
                // 줄마다 따로 된 Text 라 드래그로는 여러 줄을 못 고른다 — 통째로 복사한다
                if let job = store.job, !job.lines.isEmpty {
                    Button {
                        copy(job.plainLog, as: .log)
                    } label: {
                        Image(systemName: copied == .log ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("로그 전체를 복사합니다")
                }
                // 이 창을 닫아도 남는다 — 그 자리를 여기서 알려 준다
                if let file = store.job?.logFile {
                    Button {
                        NSWorkspace.shared.selectFile(file.path, inFileViewerRootedAtPath: RunLog.dir.path)
                    } label: {
                        Image(systemName: "doc.text")
                    }
                    .buttonStyle(.borderless)
                    .help("이 실행의 로그 파일을 Finder 에서 엽니다\n\(file.path)")
                }
            }
            .padding(12)
            Divider()

            // 지금 어디까지 왔나 — 로그를 읽기 전에 이것부터 답한다
            if let job = store.job, job.progress != nil {
                DeployProgressPanel(job: job)
                Divider()
            }

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

    // 색조 배경(주황 10%) 위에서 .secondary 는 남는 대비가 거의 없다.
    // 하필 이 패널이 "무엇이 왜 멈췄나" 를 말하는 자리라, 안 보이면 실패가 통째로 사라진다.
    private let inkStrong = Color.primary.opacity(0.82)
    private let inkDim = Color.primary.opacity(0.66)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failure.stage) 단계에서 멈췄습니다")
                        .font(.caption.weight(.semibold)).foregroundStyle(inkDim)
                    Text(failure.title)
                        .font(.callout.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if let fix = failure.fix, let app = store.app(named: failure.path) {
                    Button(fix.label) { store.apply(fix, to: app) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button {
                    // 도구 출력 몇 줄만으로는 모자랄 때가 많다 — 로그 꼬리까지 함께 싣는다
                    Clipboard.copy(store.job?.claudePrompt ?? failure.promptText)
                    copied = true
                    Task { try? await Task.sleep(nanoseconds: 1_800_000_000); copied = false }
                } label: {
                    Label(copied ? "복사됨" : "해결 프롬프트",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("실패 내용·도구 출력·배포 로그를 지시문으로 만들어 복사합니다 — Claude Code 등에 붙여넣으면 됩니다")

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
                    Text("지금 할 일").font(.caption.weight(.semibold)).foregroundStyle(inkDim)
                    ForEach(Array(failure.todo.enumerated()), id: \.offset) { i, t in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("\(i + 1).").font(.caption.monospacedDigit()).foregroundStyle(inkDim)
                            Text(t).font(.caption)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            if !failure.detail.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("도구가 한 말").font(.caption.weight(.semibold)).foregroundStyle(inkDim)
                    Text(failure.detail)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(inkStrong)
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
