import Foundation

// 스토어 문구 자동 작성 — ⋯ 메뉴의 [스토어 문구 자동 작성]. 같은 Job 창에 진행을 흘린다.
extension Store {

    func autoWriteStore(_ app: ManagedApp) {
        let job = Job(title: "스토어 문구 자동 작성 · \(app.name)")
        self.job = job
        Task {
            job.lines.append("빈 칸(이름·부제·키워드·프로모션 텍스트·설명)과 이번 버전 릴리즈노트를 모든 언어로 씁니다")
            job.lines.append("레포·App Store Connect 에 이미 있는 글은 건드리지 않습니다")
            job.lines.append("")
            do {
                let res = try await StoreWriter.run(app) { line in
                    Task { @MainActor in job.lines.append(line) }
                }
                for l in Store.describe(res, dryRun: false) { job.lines.append(l) }
                job.verdict = .success(res.didWrite
                    ? "\(Set(Array(res.store.keys) + Array(res.notes.keys)).count)개 언어 작성\(res.committed ? " · 커밋함" : "")"
                    : "쓸 것이 없었습니다")
                fixResult[app.path] = res.didWrite
                    ? "✍️ 스토어 문구를 채웠습니다 — 다음 배포(또는 [스토어 올리기])가 올립니다"
                    : "스토어 문구가 이미 다 채워져 있습니다"
            } catch {
                job.error = error.localizedDescription
                job.verdict = .failed(error.localizedDescription)
                job.lines.append("❌ \(error.localizedDescription)")
            }
            job.running = false
            await refresh(fresh: false)
        }
    }

    /// 결과를 사람이 읽을 줄로. CLI(`--autowrite`)와 창이 같은 글을 쓴다.
    nonisolated static func describe(_ res: StoreWriter.Result, dryRun: Bool) -> [String] {
        var out = ["", "── v\(res.version) \(dryRun ? "(미리보기 — 파일에 쓰지 않았습니다)" : "")"]
        for loc in Locales.sorted(Array(Set(Array(res.store.keys) + Array(res.notes.keys)))) {
            out.append("")
            out.append("[\(Locales.displayName(loc)) · \(loc)]")
            for f in StoreWriter.fields {
                guard let v = res.store[loc]?[f] else { continue }
                let shown = f == .description ? String(v.prefix(80)).replacingOccurrences(of: "\n", with: " ") + "… (\(v.count)자)" : v
                out.append("   \(StoreWriter.label(f)): \(shown)")
            }
            if let n = res.notes[loc] {
                out.append("   릴리즈노트:")
                for line in n.components(separatedBy: "\n") { out.append("      \(line)") }
            }
        }
        if res.kept > 0 { out.append(""); out.append("이미 있어서 그대로 둔 칸: \(res.kept)개") }
        if !res.files.isEmpty {
            out.append("")
            for f in res.files { out.append("📝 \(f)") }
            out.append(res.committed ? "✅ 커밋했습니다 — 다음 배포가 이 글을 올립니다" : "⚠️ 커밋하지 않았습니다 — 커밋해야 배포가 잠기지 않습니다")
        }
        if !res.warnings.isEmpty {
            out.append("")
            out.append("⚠️  하려다 못 한 것 \(res.warnings.count)건")
            for w in res.warnings { out.append("   · \(w)") }
        }
        return out
    }
}
