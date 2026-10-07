import Foundation
import AVFoundation
import ImageIO
import CryptoKit

// 크리에이티브 자산 올리기, 제품 페이지 맨 위의 **헤더**와 검색 결과에 스크린샷 대신 뜨는 **검색 결과** 한 장.
// iOS·iPadOS 27 부터 보인다. 둘 다 비워도 심사는 되지만(검색 결과는 스크린샷이 대신 나간다) 채우면 눈에 띈다.
//
// 자리 (스크린샷과 같은 폴더 아래, 언어별):
//
//   docs/screenshots/creative/<로케일>/header.png     언어별 헤더
//   docs/screenshots/creative/<로케일>/search.png     언어별 검색 결과
//   docs/screenshots/creative/header.png              모든 언어에 같은 그림
//
// 칸마다 따로 빌려 온다: 헤더는 모든 언어 한 벌, 검색 결과만 언어별 같은 섞어 쓰기가 된다
// (정확한 로케일 → 같은 언어(en-US 를 en-GB 에) → 모든 언어 순).
//
// 어느 칸에 갈지는 **이름이 먼저, 그다음 픽셀**이다:
//   이름이 header… → 헤더, search… → 검색 결과
//   이름이 말하지 않으면 21:9(3840x1646) → 헤더, 3:2 → 검색 결과, 16:9(5244x2950) → **둘 다**
// 그림(PNG·JPEG)도 영상(5~30초, 30·60fps)도 된다. 영상은 소리 없이 반복 재생된다.
//
// 규격은 애플이 런타임 목록으로 주는 것을 따른다(못 읽으면 내장 사본). 올리기 전에 거절될 파일을 먼저 거른다:
// 크기·비율, PNG 만 받는 크기, **투명(알파) 채널**, 영상 길이·프레임, 500MB.
extension StorePublish {

    static let canonicalCreativeDir = "docs/screenshots/creative"
    private static let creativeDirs = ["docs/screenshots/creative", "docs/creative"]
    private static let creativeExts: Set<String> = ["png", "jpg", "jpeg", "mp4", "mov", "m4v"]
    private static let refPrefix = "DeployBar"

    static func creativeDir(_ root: String) -> URL? {
        let fm = FileManager.default
        return creativeDirs.map { (root as NSString).appendingPathComponent($0) }
            .first { var d: ObjCBool = false; return fm.fileExists(atPath: $0, isDirectory: &d) && d.boolValue }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func creativeFiles(in dir: URL) -> [URL] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        return names.filter { creativeExts.contains(($0 as NSString).pathExtension.lowercased()) }
            .map { dir.appendingPathComponent($0) }
    }

    /// 로케일 → 파일들. 키가 `""` 면 모든 언어에 같은 파일.
    static func resolveCreatives(_ root: String, locales: [String]) -> [String: [URL]] {
        guard let dir = creativeDir(root) else { return [:] }
        var out: [String: [URL]] = [:]
        let shared = creativeFiles(in: dir)
        if !shared.isEmpty { out[""] = shared }
        let fm = FileManager.default
        for name in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() {
            let sub = dir.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: sub.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let loc = Locales.looksLikeCode(name) ? name : Locales.match(heading: name, among: locales)
            guard let loc else { continue }
            let files = creativeFiles(in: sub)
            if !files.isEmpty { out[loc] = files }
        }
        return out
    }

    // ── 파일 검사 ───────────────────────────────────────────────────────
    struct CreativeFile {
        let file: URL
        let kind: ASCClient.MediaKind
        /// 이 파일이 들어갈 칸들 (문제가 있으면 비어 있다)
        let types: [String]
        let problem: String?
        let seconds: Double?
        /// 이름이 칸을 말했나 (header… · search…). 같은 폴더에서 픽셀로 정해진 파일보다 앞선다
        var named = false
    }

    struct MediaFacts { let width: Int; let height: Int; let alpha: Bool; let seconds: Double?; let fps: Double?; let bytes: Int }

    static func mediaFacts(_ url: URL) async -> (ASCClient.MediaKind, MediaFacts)? {
        let ext = url.pathExtension.lowercased()
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)??.intValue ?? 0
        if ["png", "jpg", "jpeg"].contains(ext) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Int,
                  let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
            let alpha = p[kCGImagePropertyHasAlpha] as? Bool ?? false
            return (.image, MediaFacts(width: w, height: h, alpha: alpha, seconds: nil, fps: nil, bytes: bytes))
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else { return nil }
        let r = CGRect(origin: .zero, size: size).applying(transform)
        let fps = (try? await track.load(.nominalFrameRate)).map(Double.init)
        return (.video, MediaFacts(width: Int(abs(r.width).rounded()), height: Int(abs(r.height).rounded()),
                                   alpha: false, seconds: duration.seconds, fps: fps, bytes: bytes))
    }

    static func creativeLabel(_ type: String) -> String {
        switch type {
        case "PRODUCT_PAGE_HEADER_ASSET": return "헤더"
        case "APP_STORE_SEARCH_RESULTS_ASSET": return "검색 결과"
        default: return type
        }
    }

    /// 이름이 칸을 말하면 그 칸. 말하지 않으면 nil (픽셀이 가른다).
    private static func typeFromName(_ url: URL) -> String? {
        let n = url.deletingPathExtension().lastPathComponent.lowercased()
        if n.hasPrefix("header") || n.hasPrefix("헤더") { return "PRODUCT_PAGE_HEADER_ASSET" }
        if n.hasPrefix("search") || n.hasPrefix("검색") { return "APP_STORE_SEARCH_RESULTS_ASSET" }
        return nil
    }

    private static func fits(_ s: ASCClient.CreativeSpec, w: Int, h: Int) -> Bool {
        guard (s.minW...max(s.minW, s.maxW)).contains(w), (s.minH...max(s.minH, s.maxH)).contains(h) else { return false }
        guard let (a, b) = s.ratio else { return true }
        // 범위 규격(3:2, 1920~3840)은 비율로 가른다. 반올림으로 1px 어긋나는 것은 봐준다
        return abs(Double(w * b) - Double(h * a)) <= Double(max(a, b))
    }

    private static func sizeHint(_ catalog: ASCClient.CreativeCatalog, kind: ASCClient.MediaKind, type: String?) -> String {
        let specs = catalog.specs.filter { $0.kind == kind && (type == nil || $0.types.contains(type!)) }
        return specs.map { s in
            let dims = s.minW == s.maxW ? "\(s.minW)x\(s.minH)" : "\(s.minW)x\(s.minH)~\(s.maxW)x\(s.maxH)"
            let to = ASCClient.creativeTypes.filter(s.types.contains).map(creativeLabel).joined(separator: "·")
            return "\(to) \(dims)"
        }.joined(separator: ", ")
    }

    /// 파일 하나를 칸에 맞춘다. 업로드·`--shotplan` 이 같은 함수로 판단한다.
    static func classifyCreative(_ url: URL, catalog: ASCClient.CreativeCatalog) async -> CreativeFile {
        guard let (kind, f) = await mediaFacts(url) else {
            return CreativeFile(file: url, kind: .image, types: [], problem: "그림·영상으로 읽지 못했습니다", seconds: nil)
        }
        func bad(_ why: String) -> CreativeFile { CreativeFile(file: url, kind: kind, types: [], problem: why, seconds: f.seconds) }
        let named = typeFromName(url)
        let ext = url.pathExtension.lowercased()
        let matches = catalog.specs.filter { $0.kind == kind && fits($0, w: f.width, h: f.height) }
        guard !matches.isEmpty else {
            return bad("크기 \(f.width)x\(f.height) 는 규격이 아닙니다 (\(sizeHint(catalog, kind: kind, type: named)))")
        }
        let usable = named.map { n in matches.filter { $0.types.contains(n) } } ?? matches
        guard let spec = usable.first else {
            let actual = ASCClient.creativeTypes.filter { t in matches.contains { $0.types.contains(t) } }
                .map(creativeLabel).joined(separator: "·")
            return bad("이름은 \(creativeLabel(named!))인데 \(f.width)x\(f.height) 는 \(actual) 크기입니다")
        }
        if !spec.exts.contains(ext) {
            return bad("이 크기는 \(spec.exts.sorted().map { $0.uppercased() }.joined(separator: "·")) 만 받습니다")
        }
        if f.alpha && !spec.alphaAllowed {
            return bad("투명(알파) 채널이 있습니다. 애플이 받지 않습니다 (알파 없이 다시 저장: `sips -s format jpeg` 또는 PNG 를 불투명으로)")
        }
        if f.bytes > spec.maxBytes { return bad("크기 \(f.bytes / 1_000_000)MB (\(spec.maxBytes / 1_000_000)MB 까지)") }
        if kind == .video {
            let sec = f.seconds ?? 0
            if let lo = spec.minSeconds, let hi = spec.maxSeconds, sec < lo - 0.05 || sec > hi + 0.5 {
                return bad(String(format: "길이 %.1f초 (%.0f~%.0f초여야 한다)", sec, lo, hi))
            }
            if !spec.fps.isEmpty, let fps = f.fps, !spec.fps.contains(where: { fps >= $0.0 - 0.5 && fps <= $0.1 + 0.5 }) {
                let allowed = spec.fps.map { $0.0 == $0.1 ? "\(Int($0.0))" : "\(Int($0.0))~\(Int($0.1))" }.joined(separator: "·")
                return bad(String(format: "%.1ffps (%@fps 만 받는다)", fps, allowed))
            }
        }
        let types = ASCClient.creativeTypes.filter { t in named.map { $0 == t } ?? spec.types.contains(t) }
        return CreativeFile(file: url, kind: kind, types: types, problem: nil, seconds: f.seconds, named: named != nil)
    }

    /// 이 언어의 칸별 파일. 칸마다 정확한 로케일 → 같은 언어 → 모든 언어 순으로 빌린다.
    /// 한 폴더에 같은 칸 파일이 둘이면 이름순 첫 것을 쓰고 나머지는 `extra` 로 돌려준다.
    static func creativesFor(_ locale: String, resolved: [String: [CreativeFile]]) -> (byType: [String: CreativeFile], extra: [CreativeFile]) {
        let order: [[CreativeFile]] = [
            resolved[locale],
            resolved.first { !$0.key.isEmpty && $0.key != locale && Locales.sameLanguage($0.key, locale) }?.value,
            resolved[""],
        ].compactMap { $0 }
        var byType: [String: CreativeFile] = [:]
        var extra: [CreativeFile] = []
        for list in order {
            let before = Set(byType.keys)
            // 이름으로 칸을 정한 파일이 먼저 (search.jpg 가 있으면 16:9 공용 그림보다 그것이 검색 결과다)
            for c in list.filter({ $0.named }) + list.filter({ !$0.named }) where c.problem == nil {
                var used = false
                for t in c.types where byType[t] == nil { byType[t] = c; used = true }
                // 같은 폴더의 다른 파일에 칸을 다 뺏겼을 때만 '안 쓴 파일' 이다 (빌려 온 폴더에 밀린 것은 정상)
                if !used, c.types.contains(where: { !before.contains($0) }) { extra.append(c) }
            }
        }
        return (byType, extra)
    }

    /// 라이브러리에서 같은 파일을 찾는 이름표. 내용이 바뀌면 이름표도 바뀐다.
    static func creativeReference(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let hash = SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(refPrefix) \(url.lastPathComponent) \(hash)"
    }

    // ── 올리기 ──────────────────────────────────────────────────────────
    static func pushCreatives(_ app: ManagedApp, appId: String, version: ASCClient.Version,
                              poster: Double?, options: Options,
                              report: inout Report, onLog: (String) -> Void) async throws {
        let texts = try await ASCClient.storeTexts(versionId: version.id)
        let raw = resolveCreatives(app.path, locales: texts.map(\.locale))
        guard !raw.isEmpty else { return }   // 안 쓰는 앱엔 말하지 않는다

        let catalog: ASCClient.CreativeCatalog
        do { catalog = try await ASCClient.creativeCatalog() } catch {
            onLog("   ⚠️  애플 규격 목록을 못 읽어 내장 사본으로 검사합니다: \(reason(error))")
            catalog = ASCClient.builtinCreativeCatalog
        }
        var resolved: [String: [CreativeFile]] = [:]
        for (loc, files) in raw {
            for f in files {
                let c = await classifyCreative(f, catalog: catalog)
                if let why = c.problem {
                    report.warnings.append("\(rel(f, app.path)) 는 올리지 않았습니다: \(why)")
                }
                resolved[loc, default: []].append(c)
            }
        }
        guard let libraryId = try await ASCClient.assetLibraryId(appId: appId) else {
            report.warnings.append("이 앱에 자산 라이브러리가 없어 헤더·검색 결과를 올리지 못했습니다")
            return
        }

        // 같은 파일은 한 번만 올린다 (모든 언어 한 벌이면 언어가 열이어도 업로드는 하나)
        var assetFor: [String: String] = [:]          // 파일 경로 → 자산 id
        var uploaded: [(kind: ASCClient.MediaKind, id: String, label: String)] = []
        var placedFor: [String: [String]] = [:]       // 자산 id → 이번에 만든 배치들
        var warnedExtra = Set<String>()

        func asset(for c: CreativeFile) async throws -> String {
            if let id = assetFor[c.file.path] { return id }
            let ref = creativeReference(c.file) ?? "\(refPrefix) \(c.file.lastPathComponent)"
            let unusable: Set<String> = ["FAILED", "REJECTED", "ARCHIVED", "AWAITING_UPLOAD"]
            if let found = (try? await ASCClient.libraryAssets(libraryId: libraryId, kind: c.kind, referenceName: ref))?
                .first(where: { $0.referenceName == ref && !unusable.contains($0.state) }) {
                assetFor[c.file.path] = found.id
                return found.id
            }
            let code = (c.kind == .video ? poster : nil).flatMap { p in (c.seconds ?? 0) > p ? timeCode(p) : nil }
            onLog("🖼  \(c.file.lastPathComponent) 를 자산 라이브러리에 올리는 중…")
            let id = try await ASCClient.uploadLibraryAsset(libraryId: libraryId, kind: c.kind, file: c.file,
                                                            referenceName: ref, frameTimeCode: code)
            assetFor[c.file.path] = id
            uploaded.append((c.kind, id, c.file.lastPathComponent))
            return id
        }

        for t in texts {
            let lang = Locales.displayName(t.locale)
            let (byType, extra) = creativesFor(t.locale, resolved: resolved)
            for e in extra where warnedExtra.insert(e.file.path).inserted {
                report.warnings.append("\(rel(e.file, app.path)) 는 같은 칸 파일이 이미 있어 쓰지 않았습니다 (한 칸에 하나, 이름순 첫 파일)")
            }
            var placements = try await ASCClient.creativePlacements(localizationId: t.id)

            if options.shotMode == .replaceAll && !options.dryRun {
                for p in placements where byType[p.placementType] == nil {
                    try? await ASCClient.deletePlacement(id: p.id)
                    report.changed.append("\(lang) \(creativeLabel(p.placementType)) 비움 (레포에 없음)")
                }
                placements.removeAll { byType[$0.placementType] == nil }
            }

            for type in ASCClient.creativeTypes {
                guard let c = byType[type], let slot = catalog.slots[type] else { continue }
                let label = "\(lang) \(creativeLabel(type))"
                let existing = placements.filter { $0.placementType == type }
                let ref = creativeReference(c.file)
                let bytes = (try? FileManager.default.attributesOfItem(atPath: c.file.path)[.size] as? NSNumber)??.intValue ?? -1
                let same = existing.count == 1 && existing[0].asset.map { a in
                    (ref != nil && a.referenceName == ref) || (a.fileName == c.file.lastPathComponent && a.fileSize == bytes)
                } == true
                if same && options.shotMode != .replaceAll && !options.replaceShots {
                    report.kept.append("\(label) 는 이미 같습니다 (\(c.file.lastPathComponent))")
                    continue
                }
                if options.shotMode == .fillEmpty && !existing.isEmpty {
                    report.kept.append("\(label) 기존 자산 유지")
                    continue
                }
                if options.dryRun {
                    report.changed.append("\(label) ← \(c.file.lastPathComponent) (미리보기)")
                    continue
                }
                do {
                    let assetId = try await asset(for: c)
                    // 한 칸에 하나뿐이라 먼저 비워야 새로 놓을 수 있다
                    for p in existing { try await ASCClient.deletePlacement(id: p.id) }
                    let pid = try await ASCClient.createPlacement(localizationId: t.id, placementType: type,
                                                                  group: slot.group, kind: c.kind, assetId: assetId)
                    placedFor[assetId, default: []].append(pid)
                    report.changed.append("\(label) ← \(c.file.lastPathComponent)")
                    // 우리가 올렸고 아직 심사 전인 옛 자산은 정리한다. 다른 칸이 아직 쓰면 애플이 거절하므로 무시한다
                    for p in existing {
                        if let old = p.asset, old.id != assetId, old.referenceName.hasPrefix(refPrefix),
                           old.state == "PREPARE_FOR_SUBMISSION" {
                            try? await ASCClient.deleteLibraryAsset(kind: old.kind, id: old.id)
                        }
                    }
                } catch {
                    report.warnings.append("\(label) 를 올리지 못했습니다: \(reason(error))")
                }
            }
        }

        // 놓을 곳이 없었던 새 자산은 라이브러리에 남기지 않는다
        for u in uploaded where placedFor[u.id] == nil {
            try? await ASCClient.deleteLibraryAsset(kind: u.kind, id: u.id)
        }
        let fresh = uploaded.filter { placedFor[$0.id] != nil }
        guard !fresh.isEmpty else { return }

        // 애플의 처리를 기다린다. 처리에 실패한 자산이 칸에 남아 있으면 심사 제출이 막힌다
        onLog("⏳ 헤더·검색 결과 자산 \(fresh.count)개의 처리를 기다립니다…")
        let deadline = Date().addingTimeInterval(options.previewWait)
        var pending = fresh
        while !pending.isEmpty && Date() < deadline {
            var next: [(kind: ASCClient.MediaKind, id: String, label: String)] = []
            for u in pending {
                guard let a = try? await ASCClient.libraryAsset(kind: u.kind, id: u.id) else { next.append(u); continue }
                switch a.state {
                case "AWAITING_UPLOAD", "UPLOAD_COMPLETE":
                    next.append(u)
                case "FAILED":
                    report.warnings.append("\(u.label) 를 애플이 처리하지 못했습니다: \(a.stateDetail ?? "이유 없음"). 그 칸은 비웠습니다")
                    for pid in placedFor[u.id] ?? [] { try? await ASCClient.deletePlacement(id: pid) }
                    try? await ASCClient.deleteLibraryAsset(kind: u.kind, id: u.id)
                    report.changed.removeAll { $0.hasSuffix("← \(u.label)") }
                default:
                    break
                }
            }
            pending = next
            if !pending.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000_000) }
        }
        if !pending.isEmpty {
            report.warnings.append("헤더·검색 결과 자산 \(pending.count)개가 아직 처리 중입니다. 실패하면 다음 `--publish` 가 알려 줍니다")
        }
    }

    /// `--shotplan` 이 보여 줄 줄들. 업로드와 같은 함수로 판단한다(규격은 내장 사본, 네트워크 없음).
    static func creativePlan(_ root: String, locales: [String]) async -> [(locale: String, file: CreativeFile)] {
        var rows: [(locale: String, file: CreativeFile)] = []
        for (loc, files) in resolveCreatives(root, locales: locales).sorted(by: { $0.key < $1.key }) {
            for f in files {
                rows.append((loc, await classifyCreative(f, catalog: ASCClient.builtinCreativeCatalog)))
            }
        }
        return rows
    }
}
