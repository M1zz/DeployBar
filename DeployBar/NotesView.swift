import SwiftUI

struct NotesView: View {
    @EnvironmentObject var store: Store
    @State private var uploading = false

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
            TextEditor(text: $store.notesKo).font(.body).frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))

            Text("English (en)").font(.caption.weight(.semibold))
            TextEditor(text: $store.notesEn).font(.body).frame(height: 110)
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
        .frame(minWidth: 460, minHeight: 480)
    }
}
