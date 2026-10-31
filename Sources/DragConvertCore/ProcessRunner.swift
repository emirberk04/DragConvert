import Foundation

/// Bir programı alt süreç olarak çalıştırır. Görev iptal edilirse süreç sonlandırılır.
enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// - Parameter onLine: stdout'tan gelen her satır (ffmpeg `-progress pipe:1` için), arka plan kuyruğunda.
    static func run(_ executable: URL, _ arguments: [String],
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe(), stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdout = LineCollector(onLine: onLine)
        let stderr = LineCollector(onLine: nil, limit: 64 * 1024)
        stdoutPipe.fileHandleForReading.readabilityHandler = { stdout.append($0.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { stderr.append($0.availableData) }

        let box = ProcessBox(process)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let status: Int32 = try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    continuation.resume(returning: finished.terminationStatus)
                }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            for (pipe, collector) in [(stdoutPipe, stdout), (stderrPipe, stderr)] {
                pipe.fileHandleForReading.readabilityHandler = nil
                collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
                collector.finish()
            }
            try Task.checkCancellation()
            return Output(status: status, stdout: stdout.text, stderr: stderr.text)
        } onCancel: {
            box.terminate()
        }
    }
}

/// `Process` Sendable değil; iptal işleyicisinden sonlandırmak için kilitli kutu.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()
    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.withLock { if process.isRunning { process.terminate() } }
    }
}

/// Boru verisini biriktirir, satırlara böler. Okuma işleyicileri farklı kuyruklardan çağrılır; kilitli.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let onLine: (@Sendable (String) -> Void)?
    private let limit: Int
    private var buffer = Data()
    private var all = Data()

    init(onLine: (@Sendable (String) -> Void)?, limit: Int = 1024 * 1024) {
        self.onLine = onLine
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines: [String] = lock.withLock {
            all.append(data)
            // Sadece sonunu tut: ffmpeg hatası her zaman son satırlarda.
            if all.count > limit { all.removeFirst(all.count - limit) }
            guard onLine != nil else { return [] }
            buffer.append(data)
            var lines: [String] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            return lines
        }
        lines.forEach { onLine?($0) }
    }

    func finish() {
        let rest: String? = lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
        }
        if let rest { onLine?(rest) }
    }

    var text: String { lock.withLock { String(decoding: all, as: UTF8.self) } }
}
