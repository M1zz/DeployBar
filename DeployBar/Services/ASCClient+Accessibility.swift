import Foundation

// '앱의 손쉬운 사용' (Accessibility Nutrition Labels) — accessibilityDeclarations 리소스.
//
// 애플 문서(App Store Connect API ▸ Accessibility declarations)대로:
//   GET    /v1/apps/{id}/accessibilityDeclarations   기기(deviceFamily)마다 DRAFT · PUBLISHED · REPLACED
//   POST   /v1/accessibilityDeclarations             새 초안 (deviceFamily + supports… + app 관계)
//   PATCH  /v1/accessibilityDeclarations/{id}        초안(DRAFT)만 고칠 수 있다. attributes.publish = true 면 게시
//   DELETE /v1/accessibilityDeclarations/{id}        초안만 지울 수 있다
// 적지 않은 supports… 는 false 다. 그래서 그 기기가 받는 칸은 다 보낸다 — 애플 기본값에 기대지 않는다.
extension ASCClient {

    struct AccessibilityDeclaration {
        let id: String
        let deviceFamily: String
        let state: String                 // DRAFT · PUBLISHED · REPLACED
        let supports: Set<String>         // true 인 속성 이름 (supportsVoiceover …)
    }

    static func accessibilityDeclarations(appId: String) async throws -> [AccessibilityDeclaration] {
        let j = try await api("GET", "/v1/apps/\(appId)/accessibilityDeclarations?limit=200")
        return (j["data"] as? [[String: Any]] ?? []).compactMap { item in
            guard let id = item["id"] as? String, let a = item["attributes"] as? [String: Any] else { return nil }
            return AccessibilityDeclaration(
                id: id,
                deviceFamily: a["deviceFamily"] as? String ?? "",
                state: a["state"] as? String ?? "",
                supports: Set(A11y.attributes.filter { a[$0] as? Bool == true }))
        }
    }

    /// 새 초안. 돌려받은 id 로 게시한다.
    static func createAccessibilityDeclaration(appId: String, device: A11y.Device,
                                               supports: Set<String>) async throws -> String {
        var attrs: [String: Any] = ["deviceFamily": device.rawValue]
        for k in device.attributes { attrs[k] = supports.contains(k) }
        let payload: [String: Any] = ["data": [
            "type": "accessibilityDeclarations",
            "attributes": attrs,
            "relationships": ["app": ["data": ["type": "apps", "id": appId]]],
        ]]
        let j = try await api("POST", "/v1/accessibilityDeclarations",
                              body: try JSONSerialization.data(withJSONObject: payload))
        return (j["data"] as? [String: Any])?["id"] as? String ?? ""
    }

    /// 초안의 칸을 레포 값으로 (초안일 때만 애플이 받는다).
    static func updateAccessibilityDeclaration(id: String, device: A11y.Device,
                                               supports: Set<String>) async throws {
        var attrs: [String: Any] = [:]
        for k in device.attributes { attrs[k] = supports.contains(k) }
        try await patchAccessibilityDeclaration(id: id, attributes: attrs)
    }

    /// 초안을 스토어 페이지에 낸다. 같은 기기의 예전 게시본은 애플이 REPLACED 로 돌린다.
    static func publishAccessibilityDeclaration(id: String) async throws {
        try await patchAccessibilityDeclaration(id: id, attributes: ["publish": true])
    }

    static func deleteAccessibilityDeclaration(id: String) async throws {
        _ = try await api("DELETE", "/v1/accessibilityDeclarations/\(id)")
    }

    private static func patchAccessibilityDeclaration(id: String, attributes: [String: Any]) async throws {
        let payload: [String: Any] = ["data": [
            "type": "accessibilityDeclarations", "id": id, "attributes": attributes,
        ]]
        _ = try await api("PATCH", "/v1/accessibilityDeclarations/\(id)",
                          body: try JSONSerialization.data(withJSONObject: payload))
    }
}
