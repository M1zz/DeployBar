import Foundation

enum ReleaseNotes {
    struct Draft { var commits: [String]; var ko: String; var en: String; var note: String? }

    static func draft(_ app: ManagedApp) async -> Draft {
        let r = AppRepo.resolve(app)
        let tag = GitInfo.lastDeployTag(app.path)
        let commits = GitInfo.commitsSince(app.path, tag: tag)
        _ = r
        if commits.isEmpty { return Draft(commits: [], ko: "", en: "", note: "새 커밋 없음") }
        // AI 키가 있으면 다듬은 ko/en 을, 없으면 커밋에서 자동 정리한 초안을 넣는다.
        if let key = Config.anthropicKey {
            do {
                let (ko, en) = try await callAnthropic(commits: commits, key: key)
                return Draft(commits: commits, ko: ko, en: en, note: nil)
            } catch {
                let ko = heuristicNotes(commits)
                return Draft(commits: commits, ko: ko, en: "", note: "AI 호출 실패(\(error.localizedDescription)) — 커밋 기반 초안으로 대체")
            }
        }
        let ko = heuristicNotes(commits)
        let note = ko.isEmpty
            ? "사용자 대상 변경이 없어 보입니다 — 커밋을 확인하고 직접 작성하세요."
            : "커밋에서 자동 정리한 초안입니다. 다듬고 영어(en)를 채우려면 config.env 에 ANTHROPIC_API_KEY 를 넣으세요."
        return Draft(commits: commits, ko: ko, en: "", note: note)
    }

    // API 키 없이 커밋 메시지에서 "적당히" 릴리즈노트 초안을 만든다.
    // - 내부 작업(chore/build/refactor 등) 제외, 사용자 대상 변경만
    // - conventional prefix(feat:, fix(scope): 등) 제거, 최대 8줄
    private static func heuristicNotes(_ commits: [String]) -> String {
        let skip = ["chore", "build", "ci", "docs", "test", "refactor", "style", "perf", "merge", "revert", "wip", "bump"]
        var lines: [String] = []
        for c in commits {
            let lower = c.lowercased()
            if skip.contains(where: { lower.hasPrefix($0) }) { continue }
            var s = c
            if let range = s.range(of: "^[a-zA-Z]+(\\([^)]*\\))?!?:\\s*", options: .regularExpression) {
                s.removeSubrange(range)
            }
            s = s.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }
            lines.append("· \(s)")
            if lines.count >= 8 { break }
        }
        return lines.joined(separator: "\n")
    }

    private static func callAnthropic(commits: [String], key: String) async throws -> (String, String) {
        let prompt = """
        다음은 iOS 앱의 마지막 배포 이후 git 커밋 메시지입니다. 이를 바탕으로 App Store 릴리즈노트를 작성하세요.
        규칙: 사용자 관점의 개선/신기능 중심, 내부 리팩터링·빌드 설정은 제외, 기술용어 배제, 각 항목 한 줄, 3~5개.
        한국어(ko)와 영어(en) 두 버전을 만들고 JSON {"ko":"...","en":"..."} 형식으로만 답하세요.

        커밋:
        \(commits.map { "- \($0)" }.joined(separator: "\n"))
        """
        let payload: [String: Any] = [
            "model": Config.anthropicModel,
            "max_tokens": 1024,
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code < 400 else { throw NSError(domain: "Anthropic", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code)"]) }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (j?["content"] as? [[String: Any]]) ?? []
        let text = content.compactMap { $0["text"] as? String }.joined()
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else { return ("", "") }
        let jsonStr = String(text[start...end])
        let parsed = (try? JSONSerialization.jsonObject(with: Data(jsonStr.utf8))) as? [String: Any]
        return (parsed?["ko"] as? String ?? "", parsed?["en"] as? String ?? "")
    }

    struct UploadResult { let version: String; let locales: [String] }

    static func upload(_ app: ManagedApp, ko: String, en: String) async throws -> UploadResult {
        let r = AppRepo.resolve(app)
        let info = try AppRepo.buildSettings(r)
        guard let id = try await ASCClient.appId(bundleId: info.bundleId) else {
            throw NSError(domain: "DeployBar", code: 20, userInfo: [NSLocalizedDescriptionKey: "ASC 에서 앱을 찾지 못함"])
        }
        let vers = try await ASCClient.appStoreVersions(appId: id)
        let editableStates = ["PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"]
        guard let editable = vers.first(where: { editableStates.contains($0.state) }) else {
            throw NSError(domain: "DeployBar", code: 21, userInfo: [NSLocalizedDescriptionKey: "편집 가능한 App Store 버전이 없습니다 (먼저 새 버전을 준비하세요)"])
        }
        let locs = try await ASCClient.versionLocalizations(versionId: editable.id)
        var updated: [String] = []
        for loc in locs {
            let text: String?
            if loc.locale == "ko" { text = ko }
            else if loc.locale.hasPrefix("en") { text = en }
            else { text = nil }
            guard let whatsNew = text, !whatsNew.isEmpty else { continue }
            try await ASCClient.patchWhatsNew(localizationId: loc.id, whatsNew: whatsNew)
            updated.append(loc.locale)
        }
        return UploadResult(version: editable.versionString, locales: updated)
    }
}
