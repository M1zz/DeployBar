import Foundation

// Process 래퍼: 스트리밍 실행(run)과 동기 캡처(capture).
enum Shell {
    struct Error: Swift.Error { let code: Int32; let cmd: String }

    // 표준출력+표준에러를 라인 단위로 onLog 스트리밍. 종료코드 0 이 아니면 throw.
    @discardableResult
    static func run(
        _ launch: String,
        _ args: [String],
        cwd: URL? = nil,
        onLog: @escaping @Sendable (String) -> Void
    ) async throws -> Int32 {
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
                buf.flush()
                if proc.terminationStatus == 0 {
                    cont.resume(returning: 0)
                } else {
                    cont.resume(throwing: Error(code: proc.terminationStatus, cmd: launch))
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
    private let onLine: @Sendable (String) -> Void
    private let lock = NSLock()
    init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

    func feed(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buffer.append(d)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<nl)
            buffer.removeSubrange(buffer.startIndex...nl)
            onLine(String(data: lineData, encoding: .utf8) ?? "")
        }
    }
    func flush() {
        lock.lock(); defer { lock.unlock() }
        if !buffer.isEmpty {
            onLine(String(data: buffer, encoding: .utf8) ?? "")
            buffer.removeAll()
        }
    }
}
