import Foundation
import CryptoKit

// 앱 미리보기 영상, 스크린샷과 같은 "예약 → 조각 업로드 → 체크섬으로 확정" 이다.
//
// 스크린샷과 다른 점 둘:
//  1. 애플이 영상을 **나중에** 처리한다(수 분). 처리 중인 자산은 대표 프레임을 받지 않는다.
//     그래서 대표 프레임(`previewFrameTimeCode`)은 처리가 끝난 뒤에 따로 고친다.
//  2. 한 칸(언어 × 기기)에 세 개까지다.
//
// 참고: https://developer.apple.com/documentation/appstoreconnectapi/uploading-app-previews
extension ASCClient {

    struct Preview {
        let id: String
        let fileName: String
        let fileSize: Int
        /// AWAITING_UPLOAD · UPLOAD_COMPLETE · COMPLETE · FAILED
        let state: String
        /// 처리에서 거절된 이유(있으면). "손상된 파일" 이 대개 여기로 온다
        let errors: [String]
        let frameTimeCode: String?
        let hasVideo: Bool
    }
    struct PreviewSet { let id: String; let previewType: String; var previews: [Preview] }

    static func previewSets(localizationId: String) async throws -> [PreviewSet] {
        let j = try await api("GET", "/v1/appStoreVersionLocalizations/\(localizationId)/appPreviewSets"
            + "?limit=50&include=appPreviews"
            + "&fields[appPreviewSets]=previewType,appPreviews"
            + "&fields[appPreviews]=fileName,fileSize,assetDeliveryState,previewFrameTimeCode,videoUrl")
        let data = j["data"] as? [[String: Any]] ?? []
        let included = j["included"] as? [[String: Any]] ?? []
        var byId: [String: Preview] = [:]
        for inc in included where inc["type"] as? String == "appPreviews" {
            guard let id = inc["id"] as? String else { continue }
            byId[id] = preview(id: id, attributes: inc["attributes"] as? [String: Any] ?? [:])
        }
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let type = (item["attributes"] as? [String: Any])?["previewType"] as? String
            else { return nil }
            let rel = ((item["relationships"] as? [String: Any])?["appPreviews"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
            return PreviewSet(id: id, previewType: type,
                              previews: rel.compactMap { ($0["id"] as? String).flatMap { byId[$0] } })
        }
    }

    static func previewInfo(id: String) async throws -> Preview {
        let j = try await api("GET", "/v1/appPreviews/\(id)"
            + "?fields[appPreviews]=fileName,fileSize,assetDeliveryState,previewFrameTimeCode,videoUrl")
        let d = j["data"] as? [String: Any] ?? [:]
        return preview(id: id, attributes: d["attributes"] as? [String: Any] ?? [:])
    }

    private static func preview(id: String, attributes a: [String: Any]) -> Preview {
        let delivery = a["assetDeliveryState"] as? [String: Any] ?? [:]
        let errors = (delivery["errors"] as? [[String: Any]] ?? []).compactMap {
            ($0["description"] as? String) ?? ($0["code"] as? String)
        }
        return Preview(id: id, fileName: a["fileName"] as? String ?? "?",
                       fileSize: a["fileSize"] as? Int ?? 0,
                       state: delivery["state"] as? String ?? "?", errors: errors,
                       frameTimeCode: a["previewFrameTimeCode"] as? String,
                       hasVideo: a["videoUrl"] as? String != nil)
    }

    static func createPreviewSet(localizationId: String, previewType: String) async throws -> String {
        let payload: [String: Any] = ["data": [
            "type": "appPreviewSets",
            "attributes": ["previewType": previewType],
            "relationships": ["appStoreVersionLocalization": [
                "data": ["type": "appStoreVersionLocalizations", "id": localizationId]]],
        ]]
        let j = try await api("POST", "/v1/appPreviewSets",
                              body: try JSONSerialization.data(withJSONObject: payload))
        return (j["data"] as? [String: Any])?["id"] as? String ?? ""
    }

    static func deletePreview(id: String) async throws {
        _ = try await api("DELETE", "/v1/appPreviews/\(id)")
    }

    /// 영상 하나 올리기, 예약 → 조각별 PUT → 체크섬으로 확정. 확정에 실패하면 예약을 지운다
    /// (반쯤 올라간 자산은 웹에서 멀쩡해 보여 원인을 찾기 어렵다. 스크린샷과 같은 이유).
    static func uploadPreview(setId: String, file: URL) async throws -> String {
        let data = try Data(contentsOf: file)
        let name = file.lastPathComponent
        let mime = file.pathExtension.lowercased() == "mov" ? "video/quicktime" : "video/mp4"
        let payload: [String: Any] = ["data": [
            "type": "appPreviews",
            "attributes": ["fileName": name, "fileSize": data.count, "mimeType": mime],
            "relationships": ["appPreviewSet": ["data": ["type": "appPreviewSets", "id": setId]]],
        ]]
        let j = try await api("POST", "/v1/appPreviews",
                              body: try JSONSerialization.data(withJSONObject: payload))
        let d = j["data"] as? [String: Any] ?? [:]
        guard let id = d["id"] as? String else {
            throw APIError(status: 0, body: "미리보기 영상 자리를 예약하지 못했습니다: \(name)")
        }
        let ops = (d["attributes"] as? [String: Any])?["uploadOperations"] as? [[String: Any]] ?? []
        do {
            for op in ops { try await runUpload(op, data: data) }
            let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let commit: [String: Any] = ["data": [
                "type": "appPreviews", "id": id,
                "attributes": ["uploaded": true, "sourceFileChecksum": md5],
            ]]
            _ = try await api("PATCH", "/v1/appPreviews/\(id)",
                              body: try JSONSerialization.data(withJSONObject: commit))
        } catch {
            try? await deletePreview(id: id)
            throw error
        }
        return id
    }

    /// 대표 프레임(자동 재생이 꺼진 기기에 보이는 한 장). 형식은 `HH:MM:SS:FF`.
    /// ⚠️ 처리가 끝난 영상만 받는다. 처리 중에 보내면 거절된다.
    static func setPreviewFrame(id: String, timeCode: String) async throws {
        let payload: [String: Any] = ["data": [
            "type": "appPreviews", "id": id,
            "attributes": ["previewFrameTimeCode": timeCode],
        ]]
        _ = try await api("PATCH", "/v1/appPreviews/\(id)",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }

    static func orderPreviews(setId: String, ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let payload: [String: Any] = ["data": ids.map { ["type": "appPreviews", "id": $0] }]
        _ = try await api("PATCH", "/v1/appPreviewSets/\(setId)/relationships/appPreviews",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }
}
