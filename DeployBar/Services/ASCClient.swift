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

    struct Version { let id: String; let versionString: String; let state: String; var hasBuild: Bool = false }

    static func appStoreVersions(appId: String) async throws -> [Version] {
        // build 관계를 같이 받는다 — '업로드는 했는데 버전에 빌드를 안 붙였다' 를 잡기 위해서다.
        // 이걸 모르면 심사 제출이 안 된 채로 "배포 완료" 로 보인다.
        //
        // ⚠️ include=build 가 반드시 있어야 한다. fields[...] 에 build 를 적는 것만으로는
        //    relationships.build 에 links 만 오고 data 는 아예 오지 않는다 → hasBuild 가
        //    **모든 버전에서 늘 false** 가 되어, 빌드를 제대로 붙여 놓은 앱에도
        //    "버전에 빌드 미연결" 경고가 영원히 뜬다. 사람이 고칠 수 없는 경고는
        //    체크리스트 전체의 신뢰를 깎으므로, 관계는 include 로 확실히 받는다.
        let j = try await api("GET", "/v1/apps/\(appId)/appStoreVersions?limit=10"
            + "&fields[appStoreVersions]=versionString,appStoreState,build"
            + "&include=build&fields[builds]=version")
        let data = j["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let attr = item["attributes"] as? [String: Any] else { return nil }
            let rel = (item["relationships"] as? [String: Any])?["build"] as? [String: Any]
            let hasBuild = (rel?["data"] as? [String: Any])?["id"] != nil
            return Version(
                id: id,
                versionString: attr["versionString"] as? String ?? "",
                state: attr["appStoreState"] as? String ?? "",
                hasBuild: hasBuild
            )
        }
    }

    static func latestBuild(appId: String) async throws -> String? {
        try await latestUpload(appId: appId)?.build
    }

    /// 가장 최근에 올라간 빌드 — 빌드번호와 **그 빌드의 마케팅 버전**을 함께.
    /// 마케팅 버전이 있어야 "이 버전 빌드가 아직 안 올라간 것" 과
    /// "올라갔는데 버전에 안 붙인 것" 을 가를 수 있다. 요청은 한 번 그대로다.
    struct Upload { let build: String; let version: String? }
    static func latestUpload(appId: String) async throws -> Upload? {
        let j = try await api("GET", "/v1/builds?filter[app]=\(appId)&limit=1&sort=-uploadedDate"
            + "&fields[builds]=version,preReleaseVersion"
            + "&include=preReleaseVersion&fields[preReleaseVersions]=version")
        guard let item = (j["data"] as? [[String: Any]])?.first,
              let build = (item["attributes"] as? [String: Any])?["version"] as? String else { return nil }
        let pid = ((item["relationships"] as? [String: Any])?["preReleaseVersion"] as? [String: Any])?["data"] as? [String: Any]
        let version = (pid?["id"] as? String).flatMap { id in
            (j["included"] as? [[String: Any]])?.first { $0["id"] as? String == id }
                .flatMap { ($0["attributes"] as? [String: Any])?["version"] as? String }
        }
        return Upload(build: build, version: version)
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

    // 최근 업로드된 빌드들 — "방금 올린 게 진짜 도착했나" 를 확인하는 데 쓴다.
    struct BuildInfo { let build: String; let version: String; let state: String; let uploaded: String }
    static func recentBuilds(appId: String, limit: Int = 8) async throws -> [BuildInfo] {
        let j = try await api("GET", "/v1/builds?filter[app]=\(appId)&limit=\(limit)&sort=-uploadedDate"
            + "&fields[builds]=version,processingState,uploadedDate,preReleaseVersion"
            + "&include=preReleaseVersion&fields[preReleaseVersions]=version")
        let data = j["data"] as? [[String: Any]] ?? []
        let included = j["included"] as? [[String: Any]] ?? []
        var verById: [String: String] = [:]
        for inc in included where inc["type"] as? String == "preReleaseVersions" {
            if let id = inc["id"] as? String,
               let v = (inc["attributes"] as? [String: Any])?["version"] as? String { verById[id] = v }
        }
        return data.map { d in
            let a = d["attributes"] as? [String: Any] ?? [:]
            let rel = ((d["relationships"] as? [String: Any])?["preReleaseVersion"] as? [String: Any])
            let vid = ((rel?["data"] as? [String: Any])?["id"] as? String) ?? ""
            return BuildInfo(build: a["version"] as? String ?? "?",
                             version: verById[vid] ?? "?",
                             state: a["processingState"] as? String ?? "?",
                             uploaded: a["uploadedDate"] as? String ?? "?")
        }
    }

    // ── 릴리즈노트 업로드 ──
    // whatsNew 를 같이 읽는다 — "이 버전에서 업그레이드된 사항" 이 비었는지 배포 **전에** 알아야 한다
    struct Localization {
        let id: String
        let locale: String
        var whatsNew: String = ""
        var isEmpty: Bool { whatsNew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func versionLocalizations(versionId: String) async throws -> [Localization] {
        let j = try await api("GET", "/v1/appStoreVersions/\(versionId)/appStoreVersionLocalizations"
            + "?limit=50&fields[appStoreVersionLocalizations]=locale,whatsNew")
        let data = j["data"] as? [[String: Any]] ?? []
        return data.compactMap { item in
            guard let id = item["id"] as? String,
                  let attr = item["attributes"] as? [String: Any],
                  let locale = attr["locale"] as? String else { return nil }
            return Localization(id: id, locale: locale, whatsNew: attr["whatsNew"] as? String ?? "")
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
