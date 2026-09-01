import Foundation
import Translation

// 릴리즈노트 — 온디바이스 번역 브리지, 배포 직후 자동 반영, 노트 창이 쓰는 편집 기능.
// 번역은 뷰(LogView)가 translationTask 로 실행해 주어야 도는 특이한 의존이 있어서,
// 배포 흐름과 섞어 두면 둘 다 읽기 어려워진다.
extension Store {
    func translate(_ text: String, from source: String = "ko", toLanguage lang: String) async -> String? {
        // 온디바이스 번역이 지원하지 않는 언어는 애초에 요청하지 않는다 (30초 대기 낭비 방지)
        guard Locales.supportsOnDeviceTranslation(lang) else { return nil }
        if Locales.sameLanguage(source, lang) { return text }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            translationSeq += 1
            let id = translationSeq
            translationCont = cont
            pendingTranslation = TranslationRequest(text: text,
                                                    source: Locales.language(source),
                                                    target: Locales.language(lang))
            // 안전장치: 번역 뷰가 없거나 지연되면 30초 후 nil 로 진행
            Task { try? await Task.sleep(nanoseconds: 30_000_000_000); fulfillTranslation(nil, id: id) }
        }
    }

    /// id 를 주면 그 요청이 아직 진행 중일 때만 끝낸다 (뷰에서 부를 땐 생략).
    func fulfillTranslation(_ result: String?, id: Int? = nil) {
        if let id, id != translationSeq { return }   // 지난 요청의 타임아웃 — 무시
        guard let c = translationCont else { return }
        translationCont = nil
        pendingTranslation = nil
        c.resume(returning: result)
    }

    /// 비어 있는 로케일을 온디바이스 번역으로 메운다. 같은 언어(en-US/en-GB)는 한 번만 번역해 재사용.
    /// 반환: 채운 texts, 끝내 못 채운 로케일.
    func fillMissing(_ texts: [String: String], base: String,
                             log: ((String) -> Void)? = nil) async -> (texts: [String: String], failed: [String]) {
        var out = texts
        var failed: [String] = []
        var cache: [String: String] = [:]   // 언어코드 → 번역 결과
        guard !base.isEmpty else { return (out, out.filter { $0.value.isEmpty }.keys.sorted()) }
        for loc in Locales.sorted(out.keys.filter { out[$0]?.isEmpty ?? true }) {
            let lang = Locales.language(loc)
            if let hit = cache[lang] { out[loc] = hit; continue }
            // 이미 채워진 같은 언어의 문구가 있으면 그대로 쓴다 (en-US → en-GB)
            if let sibling = out.first(where: { Locales.sameLanguage($0.key, loc) && !$0.value.isEmpty })?.value {
                out[loc] = sibling; cache[lang] = sibling; continue
            }
            guard Locales.supportsOnDeviceTranslation(loc) else {
                failed.append(loc)
                log?("   – \(loc) (\(Locales.displayName(loc))): 온디바이스 번역 미지원 — 비워 둠")
                continue
            }
            log?("   … \(loc) (\(Locales.displayName(loc))) 번역 중")
            if let t = await translate(base, toLanguage: loc).map(ReleaseNotes.sanitize), !t.isEmpty {
                // 번역 결과에도 같은 문구 규칙을 적용한다 (특수기호·이모지 없이 간결하게)
                out[loc] = t; cache[lang] = t
            } else {
                failed.append(loc)
                log?("   – \(loc): 번역 실패 — 비워 둠 (설정 › 일반 › 언어에서 번역 다운로드 필요할 수 있음)")
            }
        }
        return (out, failed)
    }

    // 배포 직후 앱의 App Store 언어를 전부 조회해 언어별 릴리즈노트를 자동 반영
    func applyReleaseNotes(_ app: ManagedApp, into job: Job) async {
        let st = statuses.first { $0.path == app.path }
        do {
            guard let target = try await ReleaseNotes.editableVersionAndLocales(app) else {
                job.lines.append("📝 릴리즈노트 보류 — 편집 가능한 App Store 버전이 없습니다. ASC 에서 새 버전을 만든 뒤 [릴리즈노트]로 적용하세요.")
                return
            }
            let codes = target.localeCodes
            job.lines.append("📝 릴리즈노트 자동 반영 (v\(target.versionString)) — 이 앱 언어 \(codes.count)개: \(codes.joined(separator: ", "))")

            // App Store 가 실제로 요구하는 언어 그대로 초안을 만든다 (AI 키가 있으면 호출 1회로 전부)
            let draft = await ReleaseNotes.draft(app,
                                                 liveVersion: st?.liveVersion,
                                                 localVersion: st?.localVersion,
                                                 locales: codes)
            if draft.base.isEmpty && draft.filled.isEmpty {
                // 조용히 건너뛰면 '이 버전의 새로운 기능' 이 빈 채로 배포된다 — 왜 비었는지 말한다
                job.lines.append("   ⚠️ 릴리즈노트를 만들지 못했습니다 — \(draft.note ?? "직전 릴리즈 이후 커밋이 없습니다")")
                job.lines.append("   → [릴리즈노트] 창에서 직접 입력하면 이 버전에 반영됩니다")
                return
            }
            if Config.anthropicKey == nil {
                job.lines.append("   ℹ️ ANTHROPIC_API_KEY 가 없어 커밋 제목을 그대로 씁니다 (사용자용 문구가 아닐 수 있음)")
                job.lines.append("     ~/Library/Application Support/DeployBar/config.env 에 키를 넣으면 언어별로 다듬어 만듭니다")
            }
            let (texts, failed) = await fillMissing(draft.texts, base: draft.base) { job.lines.append($0) }
            let result = try await ReleaseNotes.upload(app, texts: texts)
            job.lines.append("   ✓ 반영 완료 \(result.locales.count)/\(codes.count): \(result.locales.joined(separator: ", "))")
            if !result.skipped.isEmpty {
                job.lines.append("   ⚠️ 못 채운 언어 \(result.skipped.count)개: \(result.skipped.joined(separator: ", ")) — [릴리즈노트] 창에서 직접 입력하세요")
            }
            if !failed.isEmpty && result.skipped.isEmpty {
                job.lines.append("   ↳ 번역 실패했지만 같은 언어 문구로 채워진 언어: \(failed.joined(separator: ", "))")
            }
        } catch {
            job.lines.append("📝 릴리즈노트 실패: \(error.localizedDescription)")
        }
    }

    func loadNotes(_ app: ManagedApp) async {
        notesApp = app
        notesAppName = app.name
        notesCommits = []; notesLocales = []; notesTexts = [:]; notesBase = ""; notesMsg = ""
        notesLoading = true
        defer { notesLoading = false }
        let st = statuses.first(where: { $0.path == app.path })

        // 편집 대상 언어는 App Store 가 결정한다. 조회에 실패하면 deploy.env/xcstrings 로 대체.
        var codes: [String] = []
        var header = ""
        do {
            if let target = try await ReleaseNotes.editableVersionAndLocales(app) {
                codes = target.localeCodes
                header = "App Store v\(target.versionString) · \(codes.count)개 언어"
            } else {
                header = "⚠️ 편집 가능한 App Store 버전이 없습니다 — 초안만 작성해 두고, 새 버전을 만든 뒤 업로드하세요."
            }
        } catch {
            header = "⚠️ App Store 언어 조회 실패(\(error.localizedDescription)) — 프로젝트 설정 기준으로 표시합니다"
        }
        if codes.isEmpty { codes = fallbackLocales(app) }

        let d = await ReleaseNotes.draft(app, liveVersion: st?.liveVersion, localVersion: st?.localVersion, locales: codes)
        notesCommits = d.commits
        notesLocales = Locales.sorted(codes)
        notesTexts = d.texts
        notesBase = d.base
        notesMsg = [header, d.note].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
    }

    // App Store 조회가 안 될 때 쓰는 언어 목록: deploy.env 의 LOCALES → .xcstrings 언어 → ko/en
    func fallbackLocales(_ app: ManagedApp) -> [String] {
        let r = AppRepo.resolve(app)
        if !r.locales.isEmpty { return r.locales }
        let scan = Localization.scan(app.path)
        if !scan.locales.isEmpty { return scan.locales }
        return ["ko", "en-US"]
    }

    // 비어 있는 언어를 온디바이스 번역으로 한 번에 채운다 (릴리즈노트 창의 [빈 언어 채우기])
    func fillNotesGaps() async {
        guard !notesTranslating else { return }
        notesTranslating = true
        defer { notesTranslating = false }
        let base = notesKorean
        guard !base.isEmpty else { notesMsg = "한국어 문구를 먼저 채워 주세요 — 번역의 출발점입니다."; return }
        var seed = notesTexts
        for loc in notesLocales where seed[loc] == nil { seed[loc] = "" }
        let (filled, failed) = await fillMissing(seed, base: base)
        notesTexts = filled
        notesMsg = failed.isEmpty
            ? "✅ 빈 언어를 모두 채웠습니다 — 내용을 확인하고 업로드하세요."
            : "⚠️ 못 채운 언어: \(failed.joined(separator: ", ")) — 직접 입력이 필요합니다."
    }

    func uploadNotes() async {
        guard let app = notesApp else { return }
        let empty = notesLocales.filter { (notesTexts[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        notesMsg = "업로드 중…"
        do {
            let r = try await ReleaseNotes.upload(app, texts: notesTexts)
            var msg = "✅ v\(r.version) 업데이트 \(r.locales.count)개: \(r.locales.joined(separator: ", "))"
            if !r.skipped.isEmpty { msg += " · 건너뜀: \(r.skipped.joined(separator: ", "))" }
            else if !empty.isEmpty { msg += " · 빈 언어 \(empty.count)개는 기존 문구 유지" }
            notesMsg = msg
        } catch {
            notesMsg = "오류: \(error.localizedDescription)"
        }
    }
}
