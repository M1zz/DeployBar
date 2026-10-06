import Foundation
import AVFoundation

// 앱 미리보기 영상 올리기. 검색 결과 첫 칸에 소리 없이 자동 재생되는 그것.
//
// 자리 (스크린샷과 같은 폴더 아래, 언어별):
//
//   docs/screenshots/preview/<로케일>/app-preview.mp4    언어별 (권장)
//   docs/screenshots/preview/app-preview.mp4             모든 언어에 같은 영상
//
// 한 언어 폴더에 세 개까지 둘 수 있고, 파일 이름 순서가 스토어 순서다.
// 어느 기기 칸에 갈지는 스크린샷처럼 **픽셀이 가른다**(886x1920 → 아이폰, 1200x1600 → 아이패드).
// 대표 프레임은 deploy.env 의 `PREVIEW_POSTER=<초>` (없으면 애플 기본값 5초).
//
// 올리기 전에 애플이 "손상된 파일" 로 돌려보내는 것을 먼저 잡는다: 길이(15~30초) · 크기(500MB) ·
// 소리 트랙(무음이어도 있어야 한다). 거절은 처리 뒤에야 오고, 그때는 어느 파일인지 알기 어렵다.
extension StorePublish {

    static let canonicalPreviewDir = "docs/screenshots/preview"
    private static let previewDirs = ["docs/screenshots/preview", "docs/screenshots/previews", "docs/preview"]
    private static let videoExts: Set<String> = ["mp4", "mov", "m4v"]

    static func previewDir(_ root: String) -> URL? {
        let fm = FileManager.default
        return previewDirs.map { (root as NSString).appendingPathComponent($0) }
            .first { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func videos(in dir: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return names.filter { videoExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { dir.appendingPathComponent($0) }
    }

    /// 로케일 → 영상들. 키가 `""` 면 모든 언어에 같은 영상.
    static func resolvePreviews(_ root: String, locales: [String]) -> [String: [URL]] {
        guard let dir = previewDir(root) else { return [:] }
        var out: [String: [URL]] = [:]
        let shared = videos(in: dir)
        if !shared.isEmpty { out[""] = shared }
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
            let sub = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let loc = Locales.looksLikeCode(name) ? name : Locales.match(heading: name, among: locales)
            guard let loc else { continue }
            let files = videos(in: sub)
            if !files.isEmpty { out[loc] = files }
        }
        return out
    }

    /// 이 언어에 올릴 영상. 정확히 같은 로케일 → 같은 언어(en-US 를 en-GB 에) → 모든 언어 순.
    static func previewFiles(_ resolved: [String: [URL]], for locale: String) -> [URL] {
        if let exact = resolved[locale] { return exact }
        if let same = resolved.first(where: { !$0.key.isEmpty && Locales.sameLanguage($0.key, locale) }) {
            return same.value
        }
        return resolved[""] ?? []
    }

    // ── 영상 검사 ───────────────────────────────────────────────────────
    struct VideoInfo { let width: Int; let height: Int; let seconds: Double; let hasAudio: Bool; let bytes: Int }

    static func videoInfo(_ url: URL) async -> VideoInfo? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let r = CGRect(origin: .zero, size: size).applying(transform)
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
        return VideoInfo(width: Int(abs(r.width).rounded()), height: Int(abs(r.height).rounded()),
                         seconds: duration.seconds, hasAudio: !audio.isEmpty, bytes: bytes)
    }

    /// 애플이 받지 않을 영상이면 그 이유. 받을 영상이면 nil.
    static func previewProblem(_ v: VideoInfo) -> String? {
        if v.seconds < 15 || v.seconds > 30.5 { return String(format: "길이 %.1f초 (15~30초여야 한다)", v.seconds) }
        if v.bytes > 500_000_000 { return "크기 \(v.bytes / 1_000_000)MB (500MB 까지)" }
        if !v.hasAudio { return "소리 트랙이 없다 (무음이어도 있어야 한다. 없으면 '손상된 파일' 로 돌아온다)" }
        return nil
    }

    /// 픽셀 → 미리보기 칸. 아이폰 영상은 **그 언어의 아이폰 스크린샷과 같은 칸**에 둔다
    /// (스크린샷이 6.5" 칸에 있는데 영상만 6.9" 칸에 있으면 6.5" 페이지에 영상이 안 보인다).
    static func previewType(w: Int, h: Int, platform: Platform, iphoneShotType: String?) -> String? {
        let (a, b) = (min(w, h), max(w, h))
        if platform == .macOS { return (a, b) == (1080, 1920) ? "DESKTOP" : nil }
        switch (a, b) {
        case (886, 1920): return iphoneShotType == "APP_IPHONE_67" ? "IPHONE_67" : "IPHONE_65"
        case (1080, 1920): return "IPHONE_55"
        case (1200, 1600), (900, 1200): return "IPAD_PRO_3GEN_129"
        default: return nil
        }
    }

    static func previewTypeLabel(_ t: String) -> String {
        switch t {
        case "IPHONE_67": return "iPhone 6.9\""
        case "IPHONE_65": return "iPhone 6.5\""
        case "IPHONE_55": return "iPhone 5.5\""
        case "IPAD_PRO_3GEN_129": return "iPad 13\""
        case "DESKTOP": return "Mac"
        default: return t
        }
    }

    /// 초 → 애플의 시간 코드 `HH:MM:SS:FF` (30fps 기준 프레임).
    static func timeCode(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let frames = Int(((seconds - Double(whole)) * 30).rounded())
        return String(format: "%02d:%02d:%02d:%02d", whole / 3600, (whole / 60) % 60, whole % 60, min(frames, 29))
    }

    /// 그 언어의 아이폰 스크린샷이 어느 칸에 가는지.
    private static func iphoneShotType(_ root: String, locale: String, platform: Platform) -> String? {
        guard let dir = shotDir(root) else { return nil }
        let resolved = resolveShots(dir, locales: [locale])
        let files = resolved.first { !$0.key.isEmpty && Locales.sameLanguage($0.key, locale) }?.value ?? resolved[""] ?? []
        return group(files, platform: platform).byType.keys.first { deviceFamily($0) == "iPhone" }
    }

    // ── 올리기 ──────────────────────────────────────────────────────────
    static func pushPreviews(_ app: ManagedApp, version: ASCClient.Version, platform: Platform,
                             poster: Double?, options: Options,
                             report: inout Report, onLog: (String) -> Void) async throws {
        let texts = try await ASCClient.storeTexts(versionId: version.id)
        let resolved = resolvePreviews(app.path, locales: texts.map(\.locale))
        guard !resolved.isEmpty else { return }   // 영상을 안 쓰는 앱엔 말하지 않는다

        var awaitingFrame: [(id: String, label: String)] = []
        for t in texts {
            let lang = Locales.displayName(t.locale)
            let files = previewFiles(resolved, for: t.locale)
            guard !files.isEmpty else {
                report.manual.append("\(lang) 미리보기 영상이 없습니다. \(canonicalPreviewDir)/\(t.locale)/ 에 두면 올라갑니다")
                continue
            }
            // 검사 → 칸별로 묶기
            var byType: [String: [URL]] = [:]
            let shotType = iphoneShotType(app.path, locale: t.locale, platform: platform)
            for f in files {
                guard let v = await videoInfo(f) else {
                    report.warnings.append("\(lang) \(f.lastPathComponent) 를 영상으로 읽지 못했습니다"); continue
                }
                if let why = previewProblem(v) {
                    report.warnings.append("\(lang) \(f.lastPathComponent) 는 올리지 않았습니다: \(why)"); continue
                }
                guard let type = previewType(w: v.width, h: v.height, platform: platform, iphoneShotType: shotType) else {
                    report.warnings.append("\(lang) \(f.lastPathComponent) 의 크기 \(v.width)x\(v.height) 는 미리보기 규격이 아닙니다 (아이폰 886x1920)")
                    continue
                }
                byType[type, default: []].append(f)
            }

            var sets = try await ASCClient.previewSets(localizationId: t.id)
            if options.shotMode == .replaceAll && !options.dryRun {
                for set in sets where byType[set.previewType] == nil {
                    for p in set.previews { try? await ASCClient.deletePreview(id: p.id) }
                }
                sets = sets.map { var x = $0; if byType[x.previewType] == nil { x.previews = [] }; return x }
            }
            for (type, list) in byType.sorted(by: { $0.key < $1.key }) {
                let sorted = Array(list.sorted { $0.lastPathComponent < $1.lastPathComponent }.prefix(3))
                if list.count > 3 {
                    report.warnings.append("\(lang) \(previewTypeLabel(type)) 영상은 세 개까지라 \(list.count - 3)개는 올리지 않았습니다")
                }
                let existing = sets.first { $0.previewType == type }
                let same = existing.map { set in
                    set.previews.count == sorted.count &&
                    zip(set.previews, sorted).allSatisfy { $0.fileName == $1.lastPathComponent
                        && $0.fileSize == ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? NSNumber)??.intValue ?? -1) }
                } ?? false
                if same && options.shotMode != .replaceAll && !options.replaceShots {
                    report.kept.append("\(lang) \(previewTypeLabel(type)) 미리보기 영상 \(sorted.count)개는 이미 같습니다")
                    // 영상은 같아도 대표 프레임이 다르면 맞춘다
                    if let poster, let first = existing?.previews.first, first.frameTimeCode != timeCode(poster) {
                        awaitingFrame.append((first.id, "\(lang) \(previewTypeLabel(type))"))
                    }
                    continue
                }
                if options.shotMode == .fillEmpty, let e = existing, !e.previews.isEmpty {
                    report.kept.append("\(lang) \(previewTypeLabel(type)) 기존 미리보기 영상 \(e.previews.count)개 유지")
                    continue
                }
                if options.dryRun {
                    report.changed.append("\(lang) \(previewTypeLabel(type)) 미리보기 영상 \(sorted.count)개 올리기 (미리보기)")
                    continue
                }
                let setId: String
                if let e = existing {
                    for p in e.previews { try? await ASCClient.deletePreview(id: p.id) }
                    setId = e.id
                } else {
                    setId = try await ASCClient.createPreviewSet(localizationId: t.id, previewType: type)
                }
                onLog("🎬 \(lang) · \(previewTypeLabel(type)), 미리보기 영상 \(sorted.count)개 올리는 중…")
                var ids: [String] = []
                for f in sorted {
                    do { ids.append(try await ASCClient.uploadPreview(setId: setId, file: f)) }
                    catch { report.warnings.append("\(lang) \(f.lastPathComponent) 업로드 실패: \(reason(error))") }
                }
                try? await ASCClient.orderPreviews(setId: setId, ids: ids)
                if !ids.isEmpty {
                    report.changed.append("\(lang) \(previewTypeLabel(type)) 미리보기 영상 \(ids.count)개 업로드")
                    if poster != nil, let first = ids.first { awaitingFrame.append((first, "\(lang) \(previewTypeLabel(type))")) }
                }
            }
        }

        // 대표 프레임, 애플의 처리가 끝나야 받는다. 다 올린 뒤 한꺼번에 기다린다.
        guard let poster, !awaitingFrame.isEmpty, !options.dryRun else { return }
        let code = timeCode(poster)
        onLog("⏳ 미리보기 영상 \(awaitingFrame.count)개의 처리를 기다렸다가 대표 프레임을 \(code) 로 맞춥니다…")
        let deadline = Date().addingTimeInterval(options.previewWait)
        var pending = awaitingFrame
        while !pending.isEmpty && Date() < deadline {
            var next: [(id: String, label: String)] = []
            for item in pending {
                guard let p = try? await ASCClient.previewInfo(id: item.id) else { next.append(item); continue }
                if p.state == "FAILED" {
                    let why = p.errors.first ?? "이유 없음"
                    report.warnings.append("\(item.label) 미리보기 영상을 애플이 거절했습니다: \(why)")
                } else if p.state == "COMPLETE" || p.hasVideo {
                    do {
                        try await ASCClient.setPreviewFrame(id: item.id, timeCode: code)
                        report.changed.append("\(item.label) 대표 프레임 \(code)")
                    } catch {
                        report.warnings.append("\(item.label) 대표 프레임을 정하지 못했습니다: \(reason(error))")
                    }
                } else {
                    next.append(item)
                }
            }
            pending = next
            if !pending.isEmpty { try? await Task.sleep(nanoseconds: 15_000_000_000) }
        }
        if !pending.isEmpty {
            report.warnings.append("미리보기 영상 \(pending.count)개가 아직 처리 중이라 대표 프레임을 못 정했습니다, 다음 `--publish` 가 맞춥니다 (그때까지는 애플 기본값 5초)")
        }
    }

    /// `--shotplan` 이 보여 줄 줄들. 업로드와 같은 함수로 판단한다.
    struct PreviewRow { let locale: String; let file: URL; let type: String?; let problem: String? }

    static func previewPlan(_ root: String, platform: Platform, locales: [String]) async -> [PreviewRow] {
        var rows: [PreviewRow] = []
        for (loc, files) in resolvePreviews(root, locales: locales).sorted(by: { $0.key < $1.key }) {
            let shotType = iphoneShotType(root, locale: loc.isEmpty ? (locales.first ?? "") : loc, platform: platform)
            for f in files {
                guard let v = await videoInfo(f) else {
                    rows.append(PreviewRow(locale: loc, file: f, type: nil, problem: "영상으로 읽지 못함")); continue
                }
                rows.append(PreviewRow(locale: loc, file: f,
                                       type: previewType(w: v.width, h: v.height, platform: platform, iphoneShotType: shotType),
                                       problem: previewProblem(v)))
            }
        }
        return rows
    }
}
