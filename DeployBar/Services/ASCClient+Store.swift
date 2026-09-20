import Foundation
import CryptoKit

// App Store Connect 에 **쓰는** 쪽. 조회만 하던 ASCClient 의 반대편이다.
//
// 왜 필요한가: DeployBar 는 여태 빌드를 올리는 데서 멈췄고, 그 뒤 —
// 버전 만들기, 빌드 고르기, 설명·키워드 쓰기, 스크린샷 올리기, 심사 제출 — 은
// 전부 "App Store Connect 웹에서 사람이" 였다. 그런데 그 일들 대부분은 API 가 한다.
// 체크리스트가 "이건 네가 할 수 있는 일이 아니다" 라고 적어 둔 항목 중
// 진짜로 못 하는 것은 **앱 레코드 생성과 앱 개인정보(데이터 수집) 라벨** 둘뿐이다.
//
// 쓰기는 조회와 달리 되돌리기 어렵다. 그래서 이 파일의 규칙:
//   1. 함수 하나가 API 호출 하나 — 조립은 StorePublish 가 한다.
//   2. 실패는 그대로 던진다. 삼키면 "올린 줄 알았는데 안 올라간" 상태가 된다.
//   3. 지우는 건 부르는 쪽이 명시적으로 부를 때만 (스크린샷 교체 등).
extension ASCClient {

    // ── 버전 ────────────────────────────────────────────────────────────
    /// 편집 가능한 새 App Store 버전을 만든다.
    /// 첫 업로드 앱이 "편집 가능한 버전이 없어 릴리즈노트를 못 넣는" 상태를 푸는 열쇠다.
    static func createVersion(appId: String, versionString: String,
                              platform: Platform) async throws -> Version {
        let payload: [String: Any] = ["data": [
            "type": "appStoreVersions",
            "attributes": ["platform": platform.ascPlatform, "versionString": versionString],
            "relationships": ["app": ["data": ["type": "apps", "id": appId]]],
        ]]
        let j = try await api("POST", "/v1/appStoreVersions",
                              body: try JSONSerialization.data(withJSONObject: payload))
        let d = j["data"] as? [String: Any] ?? [:]
        let attr = d["attributes"] as? [String: Any] ?? [:]
        return Version(id: d["id"] as? String ?? "",
                       versionString: attr["versionString"] as? String ?? versionString,
                       state: attr["appStoreState"] as? String ?? "PREPARE_FOR_SUBMISSION")
    }

    /// 업로드된 빌드를 버전에 고른다. 이걸 안 하면 심사 제출 버튼 자체가 안 눌린다.
    static func attachBuild(versionId: String, buildId: String) async throws {
        let payload: [String: Any] = ["data": ["type": "builds", "id": buildId]]
        _ = try await api("PATCH", "/v1/appStoreVersions/\(versionId)/relationships/build",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    /// 이 마케팅 버전으로 올라간 빌드 중 **고를 수 있는 것**(처리 완료) 하나.
    /// 처리 중(PROCESSING)인 빌드는 버전에 붙일 수 없어서 제외한다 —
    /// 붙이려다 실패하는 것보다 "아직 처리 중입니다" 라고 말하는 편이 낫다.
    struct BuildRef { let id: String; let build: String; let state: String }
    static func attachableBuild(appId: String, marketingVersion: String) async throws -> BuildRef? {
        let v = marketingVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? marketingVersion
        let j = try await api("GET", "/v1/builds?filter[app]=\(appId)"
            + "&filter[preReleaseVersion.version]=\(v)&limit=50&sort=-uploadedDate"
            + "&fields[builds]=version,processingState")
        let data = j["data"] as? [[String: Any]] ?? []
        let refs = data.compactMap { item -> BuildRef? in
            guard let id = item["id"] as? String,
                  let attr = item["attributes"] as? [String: Any] else { return nil }
            return BuildRef(id: id, build: attr["version"] as? String ?? "?",
                            state: attr["processingState"] as? String ?? "?")
        }
        return refs.first { $0.state == "VALID" } ?? refs.first
    }

    // ── 버전별 문구 (설명·키워드·프로모션·URL·릴리즈노트) ────────────────
    static func createVersionLocalization(versionId: String, locale: String) async throws -> Localization {
        let payload: [String: Any] = ["data": [
            "type": "appStoreVersionLocalizations",
            "attributes": ["locale": locale],
            "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionId]]],
        ]]
        let j = try await api("POST", "/v1/appStoreVersionLocalizations",
                              body: try JSONSerialization.data(withJSONObject: payload))
        let d = j["data"] as? [String: Any] ?? [:]
        return Localization(id: d["id"] as? String ?? "", locale: locale)
    }

    /// 버전 문구를 통째로 읽는다 (릴리즈노트만 보는 versionLocalizations 의 확장판).
    /// 첫 출시 앱은 설명·키워드가 비어 있는 게 진짜 막는 요인이라, 같은 요청에서 같이 받는다.
    struct StoreText {
        let id: String
        let locale: String
        var description: String = ""
        var keywords: String = ""
        var promotionalText: String = ""
        var supportUrl: String = ""
        var marketingUrl: String = ""
        var whatsNew: String = ""
        var hasDescription: Bool { !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var hasKeywords: Bool { !keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static func storeTexts(versionId: String) async throws -> [StoreText] {
        let j = try await api("GET", "/v1/appStoreVersions/\(versionId)/appStoreVersionLocalizations"
            + "?limit=50&fields[appStoreVersionLocalizations]="
            + "locale,description,keywords,promotionalText,supportUrl,marketingUrl,whatsNew")
        let data = j["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let a = item["attributes"] as? [String: Any],
                  let locale = a["locale"] as? String else { return nil }
            func s(_ k: String) -> String { a[k] as? String ?? "" }
            return StoreText(id: id, locale: locale, description: s("description"),
                             keywords: s("keywords"), promotionalText: s("promotionalText"),
                             supportUrl: s("supportUrl"), marketingUrl: s("marketingUrl"),
                             whatsNew: s("whatsNew"))
        }
    }

    /// nil 인 값은 **보내지 않는다** — 빈 문자열을 보내면 이미 있던 문구가 지워진다.
    static func patchVersionLocalization(id: String, fields: [String: String]) async throws {
        guard !fields.isEmpty else { return }
        let payload: [String: Any] = ["data": [
            "type": "appStoreVersionLocalizations", "id": id, "attributes": fields,
        ]]
        _ = try await api("PATCH", "/v1/appStoreVersionLocalizations/\(id)",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    // ── 앱 정보 (이름·부제·개인정보처리방침 URL) ─────────────────────────
    // 버전과 별개로 앱 전체에 붙는 값이다. 그래서 appInfo 라는 다른 리소스를 탄다.
    struct AppInfoRef { let id: String; let state: String }
    static func appInfo(appId: String) async throws -> AppInfoRef? {
        let j = try await api("GET", "/v1/apps/\(appId)/appInfos?limit=10&fields[appInfos]=state,appStoreState")
        let data = j["data"] as? [[String: Any]] ?? []
        let refs = data.compactMap { item -> AppInfoRef? in
            guard let id = item["id"] as? String else { return nil }
            let a = item["attributes"] as? [String: Any] ?? [:]
            return AppInfoRef(id: id, state: (a["state"] as? String) ?? (a["appStoreState"] as? String) ?? "")
        }
        // 출시된 앱은 appInfo 가 둘이다 (판매 중 사본 + 편집본). 고칠 수 있는 쪽을 고른다.
        return refs.first { ReleaseNotes.editableStates.contains($0.state) } ?? refs.first
    }

    struct InfoText {
        let id: String
        let locale: String
        var name: String = ""
        var subtitle: String = ""
        var privacyPolicyUrl: String = ""
    }
    static func infoTexts(appInfoId: String) async throws -> [InfoText] {
        let j = try await api("GET", "/v1/appInfos/\(appInfoId)/appInfoLocalizations"
            + "?limit=50&fields[appInfoLocalizations]=locale,name,subtitle,privacyPolicyUrl")
        let data = j["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let a = item["attributes"] as? [String: Any],
                  let locale = a["locale"] as? String else { return nil }
            return InfoText(id: id, locale: locale,
                            name: a["name"] as? String ?? "",
                            subtitle: a["subtitle"] as? String ?? "",
                            privacyPolicyUrl: a["privacyPolicyUrl"] as? String ?? "")
        }
    }

    static func createInfoText(appInfoId: String, locale: String, name: String) async throws -> InfoText {
        // name 은 필수다 — 이름 없는 현지화는 만들 수 없다.
        let payload: [String: Any] = ["data": [
            "type": "appInfoLocalizations",
            "attributes": ["locale": locale, "name": name],
            "relationships": ["appInfo": ["data": ["type": "appInfos", "id": appInfoId]]],
        ]]
        let j = try await api("POST", "/v1/appInfoLocalizations",
                              body: try JSONSerialization.data(withJSONObject: payload))
        let d = j["data"] as? [String: Any] ?? [:]
        return InfoText(id: d["id"] as? String ?? "", locale: locale, name: name)
    }

    static func patchInfoText(id: String, fields: [String: String]) async throws {
        guard !fields.isEmpty else { return }
        let payload: [String: Any] = ["data": [
            "type": "appInfoLocalizations", "id": id, "attributes": fields,
        ]]
        _ = try await api("PATCH", "/v1/appInfoLocalizations/\(id)",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    // ── 연령 등급 ───────────────────────────────────────────────────────
    /// 설문이 하나라도 비어 있으면 심사 제출이 막힌다.
    static func ageRatingDone(appInfoId: String) async throws -> Bool {
        let j = try await api("GET", "/v1/appInfos/\(appInfoId)/ageRatingDeclaration")
        let a = (j["data"] as? [String: Any])?["attributes"] as? [String: Any] ?? [:]
        // 내용 관련 문항이 하나라도 답해져 있으면 '작성함' 으로 본다.
        // (Override 류는 기본값이 NONE 으로 차 있어 판단 근거가 못 된다)
        let content = ["violenceCartoonOrFantasy", "violenceRealistic", "profanityOrCrudeHumor",
                       "matureOrSuggestiveThemes", "sexualContentOrNudity", "horrorOrFearThemes",
                       "alcoholTobaccoOrDrugUseOrReferences", "medicalOrTreatmentInformation",
                       "gamblingSimulated", "contests"]
        return content.contains { !(a[$0] is NSNull) && a[$0] != nil }
    }

    /// "해당 없음" 으로 전 문항을 선언한다 — 레포의 APPSTORE.md 에 사람이 그렇게 적어 둔 앱에만.
    ///
    /// ⚠️ 이건 애플에 하는 **내용 신고**다. 도구가 마음대로 정할 값이 아니라서
    ///    부르는 쪽(StoreMeta 의 `### 연령 등급` 절)이 사람의 뜻을 들고 와야 한다.
    ///    애플이 문항을 늘릴 때마다 여기 키도 늘어난다 — 거절되면 본문을 그대로 보여 주고
    ///    사람이 웹에서 답하게 한다 (조용히 넘어가면 심사 직전에 막힌다).
    static func declareAgeRatingNone(appInfoId: String) async throws {
        let j = try await api("GET", "/v1/appInfos/\(appInfoId)/ageRatingDeclaration")
        guard let id = (j["data"] as? [String: Any])?["id"] as? String else {
            throw APIError(status: 0, body: "연령 등급 설문을 찾지 못했습니다")
        }
        let none = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
                    "horrorOrFearThemes", "matureOrSuggestiveThemes", "medicalOrTreatmentInformation",
                    "profanityOrCrudeHumor", "sexualContentGraphicAndNudity", "sexualContentOrNudity",
                    "violenceCartoonOrFantasy", "violenceRealistic",
                    "violenceRealisticProlongedGraphicOrSadistic"]
        var attrs: [String: Any] = [:]
        for k in none { attrs[k] = "NONE" }
        attrs["gambling"] = false
        attrs["unrestrictedWebAccess"] = false
        attrs["ageRatingOverride"] = "NONE"
        attrs["koreaAgeRatingOverride"] = "NONE"
        let payload: [String: Any] = ["data": [
            "type": "ageRatingDeclarations", "id": id, "attributes": attrs,
        ]]
        _ = try await api("PATCH", "/v1/ageRatingDeclarations/\(id)",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    // ── 스크린샷 ────────────────────────────────────────────────────────
    struct Shot { let id: String; let fileName: String; let fileSize: Int; let state: String }
    struct ShotSet { let id: String; let displayType: String; var shots: [Shot] }

    static func shotSets(localizationId: String) async throws -> [ShotSet] {
        let j = try await api("GET", "/v1/appStoreVersionLocalizations/\(localizationId)/appScreenshotSets"
            + "?limit=50&include=appScreenshots"
            + "&fields[appScreenshotSets]=screenshotDisplayType,appScreenshots"
            + "&fields[appScreenshots]=fileName,fileSize,assetDeliveryState")
        let data = j["data"] as? [[String: Any]] ?? []
        let included = j["included"] as? [[String: Any]] ?? []
        var shotById: [String: Shot] = [:]
        for inc in included where inc["type"] as? String == "appScreenshots" {
            guard let id = inc["id"] as? String else { continue }
            let a = inc["attributes"] as? [String: Any] ?? [:]
            let delivery = (a["assetDeliveryState"] as? [String: Any])?["state"] as? String ?? "?"
            shotById[id] = Shot(id: id, fileName: a["fileName"] as? String ?? "?",
                                fileSize: a["fileSize"] as? Int ?? 0, state: delivery)
        }
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let type = (item["attributes"] as? [String: Any])?["screenshotDisplayType"] as? String
            else { return nil }
            let rel = ((item["relationships"] as? [String: Any])?["appScreenshots"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            let shots = rel.compactMap { ($0["id"] as? String).flatMap { shotById[$0] } }
            return ShotSet(id: id, displayType: type, shots: shots)
        }
    }

    static func createShotSet(localizationId: String, displayType: String) async throws -> String {
        let payload: [String: Any] = ["data": [
            "type": "appScreenshotSets",
            "attributes": ["screenshotDisplayType": displayType],
            "relationships": ["appStoreVersionLocalization": [
                "data": ["type": "appStoreVersionLocalizations", "id": localizationId]]],
        ]]
        let j = try await api("POST", "/v1/appScreenshotSets",
                              body: try JSONSerialization.data(withJSONObject: payload))
        return (j["data"] as? [String: Any])?["id"] as? String ?? ""
    }

    static func deleteShot(id: String) async throws {
        _ = try await api("DELETE", "/v1/appScreenshots/\(id)")
    }

    /// 그림 한 장 올리기 — 예약 → 조각별 PUT → 체크섬으로 확정, 셋이 한 몸이다.
    ///
    /// 중간에 끊기면 App Store Connect 쪽에 '올리다 만' 자산이 남는다. 그래서 확정에
    /// 실패하면 예약한 자산을 지우고 던진다 — 반쯤 올라간 그림은 심사에서 막히는데
    /// 웹에서 보면 멀쩡해 보여서 원인을 찾기가 아주 어렵다.
    @discardableResult
    static func uploadShot(setId: String, file: URL) async throws -> String {
        let data = try Data(contentsOf: file)
        let name = file.lastPathComponent
        let payload: [String: Any] = ["data": [
            "type": "appScreenshots",
            "attributes": ["fileName": name, "fileSize": data.count],
            "relationships": ["appScreenshotSet": ["data": ["type": "appScreenshotSets", "id": setId]]],
        ]]
        let j = try await api("POST", "/v1/appScreenshots",
                              body: try JSONSerialization.data(withJSONObject: payload))
        let d = j["data"] as? [String: Any] ?? [:]
        guard let id = d["id"] as? String else {
            throw APIError(status: 0, body: "스크린샷 자리를 예약하지 못했습니다: \(name)")
        }
        let ops = (d["attributes"] as? [String: Any])?["uploadOperations"] as? [[String: Any]] ?? []
        do {
            for op in ops { try await runUpload(op, data: data) }
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let commit: [String: Any] = ["data": [
                "type": "appScreenshots", "id": id,
                "attributes": ["uploaded": true, "sourceFileChecksum": md5],
            ]]
            _ = try await api("PATCH", "/v1/appScreenshots/\(id)",
                              body: try JSONSerialization.data(withJSONObject: commit))
        } catch {
            try? await deleteShot(id: id)   // 반쯤 올라간 자산을 남기지 않는다
            throw error
        }
        return id
    }

    /// 올린 순서대로 보이게 — 파일 이름 순서가 곧 스토어에서 보일 순서다.
    static func orderShots(setId: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let payload: [String: Any] = ["data": ids.map { ["type": "appScreenshots", "id": $0] }]
        _ = try await api("PATCH", "/v1/appScreenshotSets/\(setId)/relationships/appScreenshots",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    /// 예약 응답이 시키는 대로 조각을 올린다. 서명된 URL 이라 우리 토큰을 붙이지 않는다.
    private static func runUpload(_ op: [String: Any], data: Data) async throws {
        guard let urlStr = op["url"] as? String, let url = URL(string: urlStr) else { return }
        let offset = op["offset"] as? Int ?? 0
        let length = op["length"] as? Int ?? data.count
        var req = URLRequest(url: url)
        req.httpMethod = (op["method"] as? String) ?? "PUT"
        for h in (op["requestHeaders"] as? [[String: Any]] ?? []) {
            if let n = h["name"] as? String, let v = h["value"] as? String {
                req.setValue(v, forHTTPHeaderField: n)
            }
        }
        let end = min(offset + length, data.count)
        guard offset < end else { return }
        let chunk = data.subdata(in: offset..<end)
        let (body, resp) = try await URLSession.shared.upload(for: req, from: chunk)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code >= 400 {
            throw APIError(status: code, body: String(data: body, encoding: .utf8) ?? "업로드 거부")
        }
    }

    /// 배포 끝에서 스크린샷을 판단하는 데 필요한 것 한 묶음.
    /// 요청을 아끼려고 그림 수와 스토어 버전을 같이 들고 온다 —
    /// 버전이 있어야 지시문에 "스토어 v1.0" 이라고 사실대로 적을 수 있다.
    struct ShotState { let count: Int?; let storeVersion: String? }

    static func screenshotState(appId: String) async throws -> ShotState {
        let vers = try await appStoreVersions(appId: appId)
        let live = vers.first { $0.state == "READY_FOR_SALE" } ?? vers.first
        guard let editable = vers.first(where: { ReleaseNotes.editableStates.contains($0.state) })
        else { return ShotState(count: nil, storeVersion: live?.versionString) }
        let texts = try await storeTexts(versionId: editable.id)
        guard let first = texts.first else { return ShotState(count: 0, storeVersion: live?.versionString) }
        let n = try await shotSets(localizationId: first.id).reduce(0) { $0 + $1.shots.count }
        return ShotState(count: n, storeVersion: live?.versionString)
    }

    // ── 심사 제출 / 출시 ────────────────────────────────────────────────
    struct Submission { let id: String; let state: String; let submitted: Bool }

    /// 진행 중인 심사 제출 묶음. 같은 앱에 두 개를 만들 수 없어서 먼저 찾아본다.
    static func openSubmission(appId: String) async throws -> Submission? {
        let j = try await api("GET", "/v1/reviewSubmissions?filter[app]=\(appId)&limit=10"
            + "&sort=-submittedDate&fields[reviewSubmissions]=state,submitted")
        let data = j["data"] as? [[String: Any]] ?? []
        let open = data.compactMap { item -> Submission? in
            guard let id = item["id"] as? String else { return nil }
            let a = item["attributes"] as? [String: Any] ?? [:]
            return Submission(id: id, state: a["state"] as? String ?? "",
                              submitted: a["submitted"] as? Bool ?? false)
        }
        // 이미 끝난 것(COMPLETE·CANCELING)은 재사용하면 안 된다
        return open.first { ["READY_FOR_REVIEW", "WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"].contains($0.state) }
    }

    static func createSubmission(appId: String, platform: Platform) async throws -> String {
        let payload: [String: Any] = ["data": [
            "type": "reviewSubmissions",
            "attributes": ["platform": platform.ascPlatform],
            "relationships": ["app": ["data": ["type": "apps", "id": appId]]],
        ]]
        let j = try await api("POST", "/v1/reviewSubmissions",
                              body: try JSONSerialization.data(withJSONObject: payload))
        return (j["data"] as? [String: Any])?["id"] as? String ?? ""
    }

    static func addVersionToSubmission(submissionId: String, versionId: String) async throws {
        let payload: [String: Any] = ["data": [
            "type": "reviewSubmissionItems",
            "relationships": [
                "reviewSubmission": ["data": ["type": "reviewSubmissions", "id": submissionId]],
                "appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionId]],
            ],
        ]]
        _ = try await api("POST", "/v1/reviewSubmissionItems",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    /// 제출 버튼. 여기서부터 애플이 본다 — 되돌리려면 심사를 취소해야 한다.
    static func submit(submissionId: String) async throws {
        let payload: [String: Any] = ["data": [
            "type": "reviewSubmissions", "id": submissionId, "attributes": ["submitted": true],
        ]]
        _ = try await api("PATCH", "/v1/reviewSubmissions/\(submissionId)",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    static func cancelSubmission(submissionId: String) async throws {
        let payload: [String: Any] = ["data": [
            "type": "reviewSubmissions", "id": submissionId, "attributes": ["canceled": true],
        ]]
        _ = try await api("PATCH", "/v1/reviewSubmissions/\(submissionId)",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    /// '출시 대기' 를 실제 출시로. 웹에서 [출시] 를 누르는 것과 같은 일이다.
    static func releaseVersion(versionId: String) async throws {
        let payload: [String: Any] = ["data": [
            "type": "appStoreVersionReleaseRequests",
            "relationships": ["appStoreVersion": ["data": ["type": "appStoreVersions", "id": versionId]]],
        ]]
        _ = try await api("POST", "/v1/appStoreVersionReleaseRequests",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    // ── 제출 전에 사람이 해야만 하는 것들 (확인만 한다) ──────────────────
    /// 판매 지역이 정해져 있나. 안 정하면 제출 버튼이 안 눌린다 (404 = 아직 미설정).
    static func availabilitySet(appId: String) async -> Bool {
        do { _ = try await api("GET", "/v1/apps/\(appId)/appAvailabilityV2"); return true }
        catch { return false }
    }

    /// 가격이 정해져 있나 — 기준 지역이 잡혀 있으면 가격표가 선 것이다.
    static func priceSet(appId: String) async -> Bool {
        do {
            let j = try await api("GET", "/v1/appPriceSchedules/\(appId)/baseTerritory")
            return (j["data"] as? [String: Any])?["id"] != nil
        } catch { return false }
    }

    /// 인앱결제가 코드에는 있는데 App Store Connect 에 없으면, 심사에서 반드시 막힌다.
    static func inAppPurchaseIds(appId: String) async throws -> [String] {
        let j = try await api("GET", "/v1/apps/\(appId)/inAppPurchasesV2?limit=50&fields[inAppPurchases]=productId")
        let data = j["data"] as? [[String: Any]] ?? []
        return data.compactMap { ($0["attributes"] as? [String: Any])?["productId"] as? String }
    }
}
