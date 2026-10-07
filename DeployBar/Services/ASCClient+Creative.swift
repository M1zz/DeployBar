import Foundation

// 크리에이티브 자산(제품 페이지 헤더 · 검색 결과), 2026년 가을에 생긴 칸이다.
//
// 스크린샷·미리보기 영상과 길이 다르다. 칸(set)에 파일을 바로 넣지 않고 **자산 라이브러리**를 거친다:
//   1. 앱마다 하나뿐인 라이브러리에 그림·영상을 올린다 (예약 → 조각 PUT → `uploaded: true`, 체크섬 없음)
//   2. 그 자산을 언어 페이지의 한 칸에 **배치(placement)** 한다. 한 자산을 여러 언어에 배치할 수 있다
//   3. 배치는 바꿀 수 없다. 다른 그림으로 바꾸려면 배치를 지우고 새로 만든다
//   4. 심사는 배치가 붙은 버전과 함께 받는다
//
// 칸 이름·규격은 애플이 런타임 목록(`appAssetLibraryRefData`)으로 준다. 새 기기가 생겨도 API 는 그대로라
// 고정해 두지 말라는 것이 애플의 권고다. 그래서 규격은 거기서 읽고, 못 읽을 때만 내장 목록을 쓴다.
//
// 참고: https://developer.apple.com/documentation/appstoreconnectapi/understanding-the-app-asset-library
extension ASCClient {

    enum MediaKind: String { case image, video
        var resource: String { self == .image ? "appAssetLibraryImages" : "appAssetLibraryVideos" }
    }

    /// 라이브러리에 있는 자산 하나.
    struct LibraryAsset {
        let kind: MediaKind
        let id: String
        let fileName: String
        let fileSize: Int
        let referenceName: String
        /// AWAITING_UPLOAD · UPLOAD_COMPLETE · PREPARE_FOR_SUBMISSION · … · APPROVED · FAILED · REJECTED · ARCHIVED
        let state: String
        let stateDetail: String?
        /// 애플이 처리하면서 맞춘 규격. 처리 전에는 nil
        let specId: String?
    }

    /// 언어 페이지의 한 칸에 놓인 자산.
    struct Placement {
        let id: String
        let placementType: String
        let placementGroup: String
        let state: String
        let asset: LibraryAsset?
    }

    // ── 규격 목록 ───────────────────────────────────────────────────────
    struct CreativeSpec {
        let id: String
        let kind: MediaKind
        let minW: Int, maxW: Int, minH: Int, maxH: Int
        /// "21:9" → (21, 9)
        let ratio: (Int, Int)?
        let exts: Set<String>
        let alphaAllowed: Bool
        let maxBytes: Int
        let minSeconds: Double?, maxSeconds: Double?
        /// 허용 프레임 범위들 (영상만)
        let fps: [(Double, Double)]
        let types: Set<String>
    }

    struct CreativeCatalog {
        /// 버전 페이지의 칸 종류 → 그 칸의 그룹 · 한 그룹에 놓을 수 있는 수
        var slots: [String: (group: String, max: Int)]
        var specs: [CreativeSpec]
    }

    /// 버전 페이지에서 크리에이티브 자산을 받는 칸들.
    static let creativeTypes = ["PRODUCT_PAGE_HEADER_ASSET", "APP_STORE_SEARCH_RESULTS_ASSET"]

    /// 애플의 규격 목록에서 헤더·검색 결과 칸에 필요한 것만 읽는다.
    static func creativeCatalog() async throws -> CreativeCatalog {
        let j = try await api("GET", "/v1/appAssetLibraryRefData"
            + "?fields[appAssetLibraryRefData]=features,placementTypes,imageSpecs,videoSpecs")
        let a = ((j["data"] as? [[String: Any]])?.first?["attributes"] as? [String: Any]) ?? [:]

        var slots: [String: (group: String, max: Int)] = [:]
        for f in a["features"] as? [[String: Any]] ?? [] where (f["featureId"] ?? f["feature"]) as? String == "APP_STORE_VERSIONS" {
            for p in f["placementPolicies"] as? [[String: Any]] ?? [] {
                guard let t = p["placementType"] as? String, creativeTypes.contains(t),
                      let lim = (p["groupLimits"] as? [[String: Any]])?.first,
                      let g = (lim["groupIds"] as? [String])?.first else { continue }
                slots[t] = (g, lim["maxCount"] as? Int ?? 1)
            }
        }
        var wanted = Set<String>()
        for pt in a["placementTypes"] as? [[String: Any]] ?? [] {
            guard let t = pt["placementTypeId"] as? String, slots[t] != nil else { continue }
            for m in pt["specMappings"] as? [[String: Any]] ?? [] where m["placementGroupId"] as? String == slots[t]?.group {
                wanted.formUnion(m["specs"] as? [String] ?? [])
            }
        }
        var specs: [CreativeSpec] = []
        for (kind, key) in [(MediaKind.image, "imageSpecs"), (.video, "videoSpecs")] {
            for s in a[key] as? [[String: Any]] ?? [] {
                guard let id = s["specId"] as? String, wanted.contains(id) else { continue }
                specs.append(creativeSpec(kind: kind, s))
            }
        }
        guard !slots.isEmpty, !specs.isEmpty else {
            throw APIError(status: 0, body: "애플의 규격 목록에 헤더·검색 결과 칸이 없습니다")
        }
        return CreativeCatalog(slots: slots, specs: specs)
    }

    private static func creativeSpec(kind: MediaKind, _ s: [String: Any]) -> CreativeSpec {
        let d = s["dimensions"] as? [String: Any] ?? [:]
        let ratio: (Int, Int)? = (s["aspectRatio"] as? String).flatMap { r in
            let p = r.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 ? (p[0], p[1]) : nil
        }
        let dur = s["duration"] as? [String: Any]
        let fps = (s["frameRates"] as? [[String: Any]] ?? []).compactMap { r -> (Double, Double)? in
            guard let lo = (r["minFps"] as? NSNumber)?.doubleValue, let hi = (r["maxFps"] as? NSNumber)?.doubleValue else { return nil }
            return (lo, hi)
        }
        return CreativeSpec(
            id: s["specId"] as? String ?? "", kind: kind,
            minW: d["minWidth"] as? Int ?? 0, maxW: d["maxWidth"] as? Int ?? 0,
            minH: d["minHeight"] as? Int ?? 0, maxH: d["maxHeight"] as? Int ?? 0,
            ratio: ratio,
            exts: Set((s["fileExtensions"] as? [String] ?? []).map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }),
            alphaAllowed: s["alphaAllowed"] as? Bool ?? true,
            maxBytes: s["maxFileSize"] as? Int ?? 524_288_000,
            minSeconds: (dur?["min"] as? String).flatMap(isoSeconds),
            maxSeconds: (dur?["max"] as? String).flatMap(isoSeconds),
            fps: fps,
            types: Set(s["compatiblePlacementTypes"] as? [String] ?? []))
    }

    /// "PT30S" · "PT1M" → 초
    static func isoSeconds(_ s: String) -> Double? {
        guard s.hasPrefix("PT") else { return nil }
        var total = 0.0, num = ""
        for c in s.dropFirst(2) {
            if c.isNumber || c == "." { num.append(c); continue }
            let v = Double(num) ?? 0; num = ""
            switch c { case "H": total += v * 3600; case "M": total += v * 60; case "S": total += v; default: return nil }
        }
        return total
    }

    /// 애플 목록을 못 읽을 때(오프라인 `--shotplan` 등) 쓰는 사본. 2026-10 에 애플이 준 값 그대로다.
    static let builtinCreativeCatalog = CreativeCatalog(
        slots: ["PRODUCT_PAGE_HEADER_ASSET": ("DEFAULT_PROFILE", 1),
                "APP_STORE_SEARCH_RESULTS_ASSET": ("DEFAULT_PROFILE", 1)],
        specs: [
            CreativeSpec(id: "c8f4e2b1-7a3d-5c9e-8b6f-2d1a0e9c8b7a", kind: .image, minW: 5244, maxW: 5244, minH: 2950, maxH: 2950,
                         ratio: (16, 9), exts: ["png"], alphaAllowed: false, maxBytes: 524_288_000,
                         minSeconds: nil, maxSeconds: nil, fps: [],
                         types: ["PRODUCT_PAGE_HEADER_ASSET", "APP_STORE_SEARCH_RESULTS_ASSET"]),
            CreativeSpec(id: "1eb43b80-e0b7-4d96-bd32-47a42a8c5fed", kind: .image, minW: 3840, maxW: 3840, minH: 1646, maxH: 1646,
                         ratio: (21, 9), exts: ["png"], alphaAllowed: false, maxBytes: 524_288_000,
                         minSeconds: nil, maxSeconds: nil, fps: [], types: ["PRODUCT_PAGE_HEADER_ASSET"]),
            CreativeSpec(id: "d2ffa3b7-6c55-5cdf-8512-229d92791333", kind: .image, minW: 1920, maxW: 3840, minH: 1280, maxH: 2560,
                         ratio: (3, 2), exts: ["png", "jpg", "jpeg"], alphaAllowed: false, maxBytes: 524_288_000,
                         minSeconds: nil, maxSeconds: nil, fps: [], types: ["APP_STORE_SEARCH_RESULTS_ASSET"]),
            CreativeSpec(id: "8aeaae00-2a17-4781-bfc0-44ca02e26ccb", kind: .video, minW: 3840, maxW: 3840, minH: 1646, maxH: 1646,
                         ratio: (21, 9), exts: ["mp4", "m4v", "mov"], alphaAllowed: true, maxBytes: 524_288_000,
                         minSeconds: 5, maxSeconds: 30, fps: [(30, 30), (60, 60)], types: ["PRODUCT_PAGE_HEADER_ASSET"]),
            CreativeSpec(id: "a28b6440-2fe2-58f0-9da3-354cb54cab57", kind: .video, minW: 1920, maxW: 3840, minH: 1280, maxH: 2560,
                         ratio: (3, 2), exts: ["mp4", "m4v", "mov"], alphaAllowed: true, maxBytes: 524_288_000,
                         minSeconds: 5, maxSeconds: 30, fps: [(30, 30), (60, 60)], types: ["APP_STORE_SEARCH_RESULTS_ASSET"]),
        ])

    // ── 라이브러리 ──────────────────────────────────────────────────────
    static func assetLibraryId(appId: String) async throws -> String? {
        let j = try await api("GET", "/v1/apps/\(appId)/assetLibrary")
        return (j["data"] as? [String: Any])?["id"] as? String
    }

    private static let assetFields = "fileName,fileSize,referenceName,state,stateDetails,specId"

    private static func libraryAsset(kind: MediaKind, _ item: [String: Any]) -> LibraryAsset? {
        guard let id = item["id"] as? String else { return nil }
        let a = item["attributes"] as? [String: Any] ?? [:]
        let detail = (a["stateDetails"] as? [[String: Any]])?.first.flatMap {
            ($0["description"] as? String) ?? ($0["code"] as? String)
        }
        return LibraryAsset(kind: kind, id: id, fileName: a["fileName"] as? String ?? "?",
                            fileSize: a["fileSize"] as? Int ?? 0,
                            referenceName: a["referenceName"] as? String ?? "",
                            state: a["state"] as? String ?? "?", stateDetail: detail,
                            specId: a["specId"] as? String)
    }

    /// 같은 이름표(referenceName)로 이미 올라간 자산. 같은 파일을 언어마다·배포마다 다시 올리지 않으려고 쓴다.
    static func libraryAssets(libraryId: String, kind: MediaKind, referenceName: String) async throws -> [LibraryAsset] {
        let ref = referenceName.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? referenceName
        let path = kind == .image ? "images" : "videos"
        let j = try await api("GET", "/v1/appAssetLibraries/\(libraryId)/\(path)?limit=20"
            + "&filter[referenceName]=\(ref)&fields[\(kind.resource)]=\(assetFields)")
        return (j["data"] as? [[String: Any]] ?? []).compactMap { libraryAsset(kind: kind, $0) }
    }

    static func libraryAsset(kind: MediaKind, id: String) async throws -> LibraryAsset? {
        let j = try await api("GET", "/v1/\(kind.resource)/\(id)?fields[\(kind.resource)]=\(assetFields)")
        return (j["data"] as? [String: Any]).flatMap { libraryAsset(kind: kind, $0) }
    }

    /// 자산 하나 올리기, 예약 → 조각별 PUT → `uploaded: true` 로 확정. 확정에 실패하면 예약을 지운다.
    /// 영상의 대표 프레임은 예약 때 같이 보낸다(라이브러리 자산은 처리 전에도 받는다).
    static func uploadLibraryAsset(libraryId: String, kind: MediaKind, file: URL,
                                   referenceName: String, frameTimeCode: String? = nil) async throws -> String {
        let data = try Data(contentsOf: file)
        var attrs: [String: Any] = ["fileName": file.lastPathComponent, "fileSize": data.count,
                                    "category": "CREATIVE_ASSETS", "referenceName": referenceName]
        if kind == .video, let frameTimeCode { attrs["previewFrameTimeCode"] = frameTimeCode }
        let payload: [String: Any] = ["data": [
            "type": kind.resource, "attributes": attrs,
            "relationships": ["assetLibrary": ["data": ["type": "appAssetLibraries", "id": libraryId]]],
        ]]
        let j = try await api("POST", "/v1/\(kind.resource)", body: try JSONSerialization.data(withJSONObject: payload))
        let d = j["data"] as? [String: Any] ?? [:]
        guard let id = d["id"] as? String else {
            throw APIError(status: 0, body: "자산 라이브러리에 자리를 예약하지 못했습니다: \(file.lastPathComponent)")
        }
        let ops = (d["attributes"] as? [String: Any])?["uploadOperations"] as? [[String: Any]] ?? []
        do {
            for op in ops { try await runUpload(op, data: data) }
            let commit: [String: Any] = ["data": ["type": kind.resource, "id": id, "attributes": ["uploaded": true]]]
            _ = try await api("PATCH", "/v1/\(kind.resource)/\(id)", body: try JSONSerialization.data(withJSONObject: commit))
        } catch {
            try? await deleteLibraryAsset(kind: kind, id: id)
            throw error
        }
        return id
    }

    /// 배치가 남아 있거나 이미 심사를 받은 자산은 애플이 거절한다(409). 부르는 쪽은 실패를 무시해도 된다.
    static func deleteLibraryAsset(kind: MediaKind, id: String) async throws {
        _ = try await api("DELETE", "/v1/\(kind.resource)/\(id)")
    }

    // ── 배치 ────────────────────────────────────────────────────────────
    static func creativePlacements(localizationId: String) async throws -> [Placement] {
        let j = try await api("GET", "/v1/appStoreVersionLocalizations/\(localizationId)/placements?limit=50"
            + "&filter[placementType]=\(creativeTypes.joined(separator: ","))"
            + "&include=image,video"
            + "&fields[appAssetLibraryImages]=\(assetFields)&fields[appAssetLibraryVideos]=\(assetFields)")
        var assets: [String: LibraryAsset] = [:]
        for inc in j["included"] as? [[String: Any]] ?? [] {
            let kind: MediaKind? = inc["type"] as? String == MediaKind.image.resource ? .image
                : inc["type"] as? String == MediaKind.video.resource ? .video : nil
            if let kind, let a = libraryAsset(kind: kind, inc) { assets["\(kind.rawValue):\(a.id)"] = a }
        }
        return (j["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String else { return nil }
            let a = item["attributes"] as? [String: Any] ?? [:]
            let rel = item["relationships"] as? [String: Any] ?? [:]
            var asset: LibraryAsset?
            for kind in [MediaKind.image, .video] {
                if let aid = ((rel[kind.rawValue] as? [String: Any])?["data"] as? [String: Any])?["id"] as? String {
                    asset = assets["\(kind.rawValue):\(aid)"]
                }
            }
            return Placement(id: id, placementType: a["placementType"] as? String ?? "?",
                             placementGroup: a["placementGroup"] as? String ?? "?",
                             state: a["state"] as? String ?? "?", asset: asset)
        }
    }

    static func createPlacement(localizationId: String, placementType: String, group: String,
                                kind: MediaKind, assetId: String) async throws -> String {
        let payload: [String: Any] = ["data": [
            "type": "appAssetLibraryPlacements",
            "attributes": ["placementType": placementType, "placementGroup": group],
            "relationships": [
                kind.rawValue: ["data": ["type": kind.resource, "id": assetId]],
                "appStoreVersionLocalization": ["data": ["type": "appStoreVersionLocalizations", "id": localizationId]],
            ],
        ]]
        let j = try await api("POST", "/v1/appAssetLibraryPlacements", body: try JSONSerialization.data(withJSONObject: payload))
        return (j["data"] as? [String: Any])?["id"] as? String ?? ""
    }

    static func deletePlacement(id: String) async throws {
        _ = try await api("DELETE", "/v1/appAssetLibraryPlacements/\(id)")
    }
}
