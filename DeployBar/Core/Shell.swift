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
