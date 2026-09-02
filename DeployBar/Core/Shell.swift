import Foundation

// Process 래퍼: 스트리밍 실행(run)과 동기 캡처(capture).
enum Shell {
    // 실패한 명령의 출력까지 들고 다닌다.
    // 출력을 안 담으면 error.localizedDescription 이
    // "The operation couldn't be completed. (DeployBar.Shell.Error error 1.)" 로 나와서
    // 로그 창을 열기 전엔 무엇이 왜 실패했는지 알 길이 없다.
    struct Error: Swift.Error, LocalizedError {
        let code: Int32
        let cmd: String
        var output: String = ""

        /// 사람이 읽을 몇 줄. fatal:/error: 가 있으면 그것만 — 없을 때만 마지막 줄들을 보여 준다.
        /// (git 은 hint: 로 화면을 채워서, 끝 4줄이 정작 원인이 아닌 경우가 많다)
        var tail: String {
            let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("$ ") && !$0.hasPrefix("hint:") }
            let hard = lines.filter { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") }
            return (hard.isEmpty ? Array(lines.suffix(4)) : Array(hard.prefix(4)))
                .joined(separator: "\n")
        }
        var errorDescription: String? {
            let name = (cmd as NSString).lastPathComponent
            return tail.isEmpty ? "\(name) 종료코드 \(code)" : "\(name) 종료코드 \(code)\n\(tail)"
        }
    }

    // 표준출력+표준에러를 라인 단위로 onLog 스트리밍. 종료코드 0 이 아니면 throw.
    // 전체 출력 문자열을 반환한다(altool 처럼 종료코드 0 으로도 실패를 알리는 경우 검사용).
    @discardableResult
    static func run(
        _ launch: String,
        _ args: [String],
        cwd: URL? = nil,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        onLog("$ \(launch) \(args.joined(separator: " "))")
        return try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launch)
            p.arguments = args
            if let cwd { p.currentDirectoryURL = cwd }
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe

            let buf = LineBuffer(onLine: onLog)
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                buf.feed(d)
            }
            p.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                // 프로세스가 끝나도 파이프에 아직 안 읽힌 데이터가 남아 있다.
                // 핸들러만 떼고 끝내면 그 부분이 통째로 사라진다 —
                // altool 처럼 '마지막 줄' 이 성공/실패를 가르는 도구에서는 치명적이다.
                if let rest = try? pipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                    buf.feed(rest)
                }
                buf.flush()
                let output = buf.collected.joined(separator: "\n")
                if proc.terminationStatus == 0 {
                    cont.resume(returning: output)
                } else {
                    cont.resume(throwing: Error(code: proc.terminationStatus, cmd: launch, output: output))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    /// 종료코드까지 필요한 동기 실행 (stdout+stderr 합침).
    ///
    /// capture 로는 부족한 경우가 있다: git fetch/pull 은 **실패한 이유가 stderr 에만** 있고,
    /// 자격증명이 없으면 프롬프트에서 영영 멈춘다. 조회 한 번에 앱 수만큼 도는 명령이라
    /// 하나가 멈추면 새로고침 전체가 멈춘다 — 그래서 프롬프트를 끄고 시간 제한을 둔다.
    struct Outcome {
        var code: Int32
        var output: String
        var timedOut: Bool
        var ok: Bool { code == 0 && !timedOut }
        /// 사람이 읽을 한 줄 (fatal:/error: 우선)
        var reason: String {
            if timedOut { return "응답 없음 (시간 초과)" }
            let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("hint:") }
            return lines.first(where: { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") })
                ?? lines.last ?? "종료코드 \(code)"
        }
    }

    static func outcome(
        _ launch: String, _ args: [String], cwd: URL? = nil,
        env extra: [String: String] = [:], timeout: TimeInterval? = nil
    ) -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        if !extra.isEmpty {
            var e = ProcessInfo.processInfo.environment
            for (k, v) in extra { e[k] = v }
            p.environment = e
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return Outcome(code: -1, output: error.localizedDescription, timedOut: false)
        }

        // 시간 제한: 넘기면 죽인다. 죽이면 파이프가 닫혀 아래 읽기도 함께 풀린다.
        let killed = Flag()
        if let timeout {
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak p] in
                guard let p, p.isRunning else { return }
                killed.set()
                p.terminate()
            }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return Outcome(code: p.terminationStatus,
                       output: String(data: data, encoding: .utf8) ?? "",
                       timedOut: killed.value)
    }

    // 동기 캡처(stdout). stderr 는 버린다. showBuildSettings·git 용.
    static func capture(_ launch: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launch)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// 청크를 줄 단위로 쪼개는 버퍼 (스레드 안전)
final class LineBuffer: @unchecked Sendable {
    private var buffer = Data()
    private(set) var collected: [String] = []
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    private func emit(_ line: String) {
        collected.append(line)
        onLine(line)
    }
    func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            emit(String(data: lineData, encoding: .utf8) ?? "")
        }
    }
    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty {
            emit(String(data: buffer, encoding: .utf8) ?? "")
            buffer.removeAll()
        }
    }
}

/// 다른 스레드에서 세우는 한 칸짜리 깃발 (시간 초과 표시용)
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
