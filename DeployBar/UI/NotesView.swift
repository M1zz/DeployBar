import SwiftUI
import Translation

struct NotesView: View {
    @EnvironmentObject var store: Store
    @State private var uploading = false

    private var emptyCount: Int {
        store.notesLocales.filter { (store.notesTexts[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("릴리즈노트 — \(store.notesAppName)").font(.headline)
                Spacer()
                if !store.notesLocales.isEmpty {
                    Text("\(store.notesLocales.count)개 언어\(emptyCount > 0 ? " · 빈 칸 \(emptyCount)" : "")")
                        .font(.caption).foregroundStyle(emptyCount > 0 ? .orange : .secondary)
                }
            }

            if store.notesLoading {
                HStack { ProgressView().controlSize(.small); Text("App Store 언어·커밋 분석 중…").foregroundStyle(.secondary) }
            }

            DisclosureGroup {
                ScrollView {
                    Text(store.notesCommits.isEmpty ? "새 커밋 없음" : store.notesCommits.map { "· \($0)" }.joined(separator: "\n"))
                        .font(.system(size: 11, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 84)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            } label: {
                Text("마지막 배포 이후 커밋 (\(store.notesCommits.count))")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // 언어별 편집 — App Store 가 요구하는 언어 그대로 한 칸씩
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(store.notesLocales, id: \.self) { loc in
                        LocaleEditor(locale: loc, text: binding(for: loc))
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(minHeight: 240)

            HStack {
                Button {
                    Task { await store.fillNotesGaps() }
                } label: {
                    if store.notesTranslating {
                        HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("번역 중…") }
                    } else {
                        Label("빈 언어 채우기 (온디바이스 번역)", systemImage: "character.book.closed")
                    }
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.notesTranslating || store.notesKorean.isEmpty || emptyCount == 0)
                .help("한국어 문구를 기준으로 비어 있는 언어를 Apple 온디바이스 번역으로 채웁니다")
                Spacer()
            }

            HStack(alignment: .top) {
                Text(store.notesMsg)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button {
                    uploading = true
                    Task { await store.uploadNotes(); uploading = false }
                } label: {
                    if uploading { ProgressView().controlSize(.small) }
                    else { Text("App Store 에 업로드") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploading || store.notesLocales.isEmpty)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 560)
        // 릴리즈노트 창만 열려 있어도 온디바이스 번역이 돌도록 (로그 창과 같은 브리지)
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

    private func binding(for locale: String) -> Binding<String> {
        Binding(get: { store.notesTexts[locale] ?? "" },
                set: { store.notesTexts[locale] = $0 })
    }
}

private struct LocaleEditor: View {
    let locale: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Locales.displayName(locale)).font(.caption.weight(.semibold))
                Text(locale).font(.caption2).foregroundStyle(.secondary)
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("비어 있음").font(.caption2).foregroundStyle(.orange)
                }
                Spacer()
                Text("\(text.count)/4000")
                    .font(.caption2)
                    .foregroundStyle(text.count > 4000 ? .red : .secondary)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 88)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }
}
