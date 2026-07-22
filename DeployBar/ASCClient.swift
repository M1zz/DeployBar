import Foundation
import CryptoKit

// App Store Connect API 클라이언트 (CryptoKit ES256 JWT + URLSession, 의존성 0)
enum ASCClient {
    struct APIError: Error { let status: Int; let body: String }

    static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func jwt() throws -> String {
        let asc = Config.asc
        guard !asc.keyId.isEmpty, !asc.issuer.isEmpty else {
            throw APIError(status: 0, body: "ASC_KEY_ID / ASC_ISSUER_ID 미설정 (asc.env 확인)")
        }
        let pem = try String(contentsOf: asc.keyPath, encoding: .utf8)
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let headerStr = "{\"alg\":\"ES256\",\"kid\":\"\(asc.keyId)\",\"typ\":\"JWT\"}"
        let header = base64url(Data(headerStr.utf8))
        let now = Int(Date().timeIntervalSince1970)
        let payloadStr = "{\"iss\":\"\(asc.issuer)\",\"iat\":\(now),\"exp\":\(now + 1000),\"aud\":\"appstoreconnect-v1\"}"
        let payload = base64url(Data(payloadStr.utf8))
        let signingInput = "\(header).\(payload)"
        let sig = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64url(sig.rawRepresentation))"
    }

    @discardableResult
    static func api(_ method: String, _ path: String, body: Data? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com\(path)")!)
        req.httpMethod = method
        req.setValue("Bearer \(try jwt())", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { req.httpBody = body }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code >= 400 {
            throw APIError(status: code, body: String(data: data, encoding: .utf8) ?? "")
        }
        if data.isEmpty { return [:] }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    // ── 조회 헬퍼 ──
    static func appId(bundleId: String) async throws -> String? {
        let j = try await api("GET", "/v1/apps?filter[bundleId]=\(bundleId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? bundleId)&limit=1")
        let data = j["data"] as? [[String: Any]]
        return data?.first?["id"] as? String
    }

    struct Version { let id: String; let versionString: String; let state: String }

    static func appStoreVersions(appId: String) async throws -> [Version] {
        let j = try await api("GET", "/v1/apps/\(appId)/appStoreVersions?limit=10&fields[appStoreVersions]=versionString,appStoreState")
        let data = j["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let attr = item["attributes"] as? [String: Any] else { return nil }
            return Version(
                id: id,
                versionString: attr["versionString"] as? String ?? "",
                state: attr["appStoreState"] as? String ?? ""
            )
        }
    }

    static func latestBuild(appId: String) async throws -> String? {
        let j = try await api("GET", "/v1/builds?filter[app]=\(appId)&limit=1&sort=-uploadedDate&fields[builds]=version")
        let data = j["data"] as? [[String: Any]]
        return (data?.first?["attributes"] as? [String: Any])?["version"] as? String
    }

    // 특정 마케팅 버전(preReleaseVersion.version)에 이미 올라간 최신 빌드번호.
    // 그 버전으로 올라간 빌드가 아직 없으면 nil → 호출측에서 1부터 시작한다.
    static func latestBuild(appId: String, marketingVersion: String) async throws -> Int? {
        let v = marketingVersion.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? marketingVersion
        let j = try await api("GET", "/v1/builds?filter[app]=\(appId)&filter[preReleaseVersion.version]=\(v)&limit=200&fields[builds]=version")
        let data = j["data"] as? [[String: Any]] ?? []
        let nums = data.compactMap { ($0["attributes"] as? [String: Any])?["version"] as? String }.compactMap { Int($0) }
        return nums.max()
    }

    // ── 릴리즈노트 업로드 ──
    struct Localization { let id: String; let locale: String }

    static func versionLocalizations(versionId: String) async throws -> [Localization] {
        let j = try await api("GET", "/v1/appStoreVersions/\(versionId)/appStoreVersionLocalizations?limit=50")
        let data = j["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let attr = item["attributes"] as? [String: Any],
                  let locale = attr["locale"] as? String else { return nil }
            return Localization(id: id, locale: locale)
        }
    }

    static func patchWhatsNew(localizationId: String, whatsNew: String) async throws {
        let payload: [String: Any] = [
            "data": [
                "type": "appStoreVersionLocalizations",
                "id": localizationId,
                "attributes": ["whatsNew": whatsNew],
            ],
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        _ = try await api("PATCH", "/v1/appStoreVersionLocalizations/\(localizationId)", body: body)
    }
}
