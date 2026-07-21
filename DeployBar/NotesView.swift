import SwiftUI
import Translation

struct NotesView: View {
    @EnvironmentObject var store: Store
    @State private var uploading = false

    // 온디바이스 번역 (Apple Translation, macOS 15+). API 키 없이 한국어→영어.
    @State private var translateConfig: TranslationSession.Configuration?
    @State private var translating = false
    @State private var lastAutoTranslatedApp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("릴리즈노트 — \(store.notesAppName)").font(.headline)

            if store.notesLoading {
                HStack { ProgressView().controlSize(.small); Text("커밋 분석 중…").foregroundStyle(.secondary) }
            }

            Text("마지막 배포 이후 커밋").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                Text(store.notesCommits.isEmpty ? "새 커밋 없음" : store.notesCommits.map { "· \($0)" }.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 90)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))

            Text("한국어 (ko)").font(.caption.weight(.semibold))
            TextEditor(text: $store.notesKo).font(.body).frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Text("English (en)").font(.caption.weight(.semibold))
                Spacer()
                Button {
                    startTranslation()
                } label: {
                    if translating {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("번역 중…") }
                    } else {
                        Label("한국어→영어 번역", systemImage: "character.book.closed")
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(translating || store.notesKo.isEmpty)
            }
            TextEditor(text: $store.notesEn).font(.body).frame(height: 100)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            HStack {
                Text(store.notesMsg).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    uploading = true
                    Task { await store.uploadNotes(); uploading = false }
                } label: {
                    if uploading { ProgressView().controlSize(.small) }
                    else { Text("App Store 에 업로드") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploading)
            }
        }
        .padding(16)
        .frame(minWidth: 460, minHeight: 500)
        // 새 앱의 노트가 로드되고 ko 는 있는데 en 이 비면 자동으로 한 번 번역
        .onChange(of: store.notesKo) { autoTranslateIfNeeded() }
        .translationTask(translateConfig) { session in
            translating = true
            defer { translating = false }
            do {
                let response = try await session.translate(store.notesKo)
                store.notesEn = response.targetText
            } catch {
                store.notesMsg = "번역 실패: \(error.localizedDescription) (설정 › 일반 › 언어에서 한국어·영어 번역 다운로드 필요할 수 있음)"
            }
        }
    }

    private func startTranslation() {
        guard !store.notesKo.isEmpty else { return }
        if translateConfig == nil {
            translateConfig = TranslationSession.Configuration(
                source: Locale.Language(identifier: "ko"),
                target: Locale.Language(identifier: "en")
            )
        } else {
            translateConfig?.invalidate()   // 같은 설정이라도 다시 번역 실행
        }
    }

    private func autoTranslateIfNeeded() {
        guard !store.notesKo.isEmpty, store.notesEn.isEmpty,
              store.notesAppName != lastAutoTranslatedApp else { return }
        lastAutoTranslatedApp = store.notesAppName
        startTranslation()
    }
}
