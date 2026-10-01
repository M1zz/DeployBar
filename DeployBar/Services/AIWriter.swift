import Foundation

// 글 쓰는 AI 를 부르는 한 곳.
//
// 키(ANTHROPIC_API_KEY)가 있으면 Anthropic API 를, 없으면 이 Mac 의 `claude` CLI(Claude Code)를
// 헤드리스(-p)로 부른다. 키를 따로 발급받지 않아도 Claude Code 를 쓰는 사람이면 바로 돈다 —
// 스토어 문구를 열 개 언어로 쓰는 일이 "키 설정" 에서 막히면 결국 사람이 손으로 쓴다.
enum AIWriter {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// GUI 로 띄운 앱에는 터미널의 PATH 가 없다 — 흔한 설치 위치를 직접 본다.
    static var cliPath: String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude",
                "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var available: Bool { Config.anthropicKey != nil || cliPath != nil }
    static var engineLabel: String { Config.anthropicKey != nil ? "Anthropic API" : "Claude Code CLI" }

    static func complete(_ prompt: String, maxTokens: Int = 8000) async throws -> String {
        if let key = Config.anthropicKey { return try await api(prompt, key: key, maxTokens: maxTokens) }
        guard let cli = cliPath else {
            throw Failure(message: "AI 를 부를 수 없습니다 — ANTHROPIC_API_KEY 를 설정하거나 Claude Code 를 설치하세요")
        }
        return try await runCLI(cli, prompt)
    }

    /// 응답에서 JSON 객체만 꺼낸다. 앞뒤 설명이나 코드펜스가 붙어 와도 받는다.
    static func json(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8))) as? [String: Any]
    }

    // ── Anthropic API ───────────────────────────────────────────────────
    private static func api(_ prompt: String, key: String, maxTokens: Int) async throws -> String {
        let payload: [String: Any] = [
            "model": Config.anthropicModel,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": prompt]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code < 400 else { throw Failure(message: "Anthropic API HTTP \(code)") }
        let j = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = (j?["content"] as? [[String: Any]]) ?? []
        return content.compactMap { $0["text"] as? String }.joined()
    }

    // ── claude CLI ──────────────────────────────────────────────────────
    /// 도구는 끈다(`--tools ""`) — 글만 받으면 되고, 레포를 만지게 둘 이유가 없다.
    /// 작업 폴더는 임시 폴더다. 앱 레포에서 돌리면 그 레포의 CLAUDE.md 가 끼어든다.
    private static func runCLI(_ cli: String, _ prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: cli)
                p.arguments = ["-p", "--output-format", "text", "--tools", "", "--no-session-persistence"]
                p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
                var env = Shell.childEnvironment()
                let dir = (cli as NSString).deletingLastPathComponent
                env["PATH"] = [dir, "/opt/homebrew/bin", "/usr/local/bin", env["PATH"] ?? "/usr/bin:/bin"]
                    .joined(separator: ":")
                p.environment = env
                let input = Pipe(), output = Pipe(), errors = Pipe()
                p.standardInput = input
                p.standardOutput = output
                p.standardError = errors
                do { try p.run() } catch {
                    cont.resume(throwing: Failure(message: "claude 를 실행하지 못했습니다 — \(error.localizedDescription)"))
                    return
                }
                // 오래 걸려도 5분이면 끊는다 — 배포 창이 영원히 '작성 중' 으로 남으면 안 된다
                let timer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: timer)
                input.fileHandleForWriting.write(Data(prompt.utf8))
                try? input.fileHandleForWriting.close()
                let out = output.fileHandleForReading.readDataToEndOfFile()
                let err = errors.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                let text = String(decoding: out, as: UTF8.self)
                if p.terminationStatus != 0 {
                    let why = String(decoding: err, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " ")
                    cont.resume(throwing: Failure(message: "claude 종료코드 \(p.terminationStatus)"
                                                  + (why.isEmpty ? "" : " — \(why)")))
                } else {
                    cont.resume(returning: text)
                }
            }
        }
    }
}
