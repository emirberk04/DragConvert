import AppKit
import DragConvertCore

/// Halkaya bırakılan şey.
public enum DropPayload {
    /// Finder'dan: gerçek dosyalar, çıktı yanlarına.
    case files([URL])
    /// Fotoğraflar gibi bir uygulamadan: dosyalar bırakınca geçici bir klasöre yazdırılır (iCloud'dan inmesi
    /// gerekiyorsa sürebilir). İş bitince `folder` silinmeli.
    case promised(folder: URL, files: Task<[URL], any Error>)
}

/// `NSFilePromiseReceiver` ile sözü verilen dosyaları teslim alır.
@MainActor
enum PromisedFiles {
    /// Teslim almayı hemen (bırakma sırasında) başlatır: pano sadece o an geçerli.
    static func receive(_ receivers: [NSFilePromiseReceiver]) -> DropPayload {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragConvert-\(UUID().uuidString)", isDirectory: true)
        // Önerilen ad boş olabiliyor (Fotoğraflar); o zaman öğe başına bir dosya beklenir.
        let expected = receivers.reduce(0) { $0 + max(1, $1.fileNames.count) }
        let collector = Collector(expected: expected)
        let started = Date()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .promised(folder: folder, files: Task { throw error })
        }
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: queue) { url, error in
                collector.add(url, error)
            }
        }
        return .promised(folder: folder, files: Task {
            let files = try await collector.wait()
            // Teşhis: Fotoğraflar iCloud'daki asıl kopyayı indirirken bu süre uzar.
            Log.drag.info("Kaynak uygulamadan \(files.count) dosya \(Date().timeIntervalSince(started), format: .fixed(precision: 1)) sn'de alındı")
            return files
        })
    }
}

/// Teslim edilen dosyaları toplar; beklenen sayıya ulaşınca bekleyeni uyandırır.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private let expected: Int
    private var urls: [URL] = []
    private var errors: [any Error] = []
    private var continuation: CheckedContinuation<[URL], any Error>?

    init(expected: Int) { self.expected = expected }

    func add(_ url: URL, _ error: (any Error)?) {
        let finished: (CheckedContinuation<[URL], any Error>, Result<[URL], any Error>)? = lock.withLock {
            if let error { errors.append(error) } else { urls.append(url) }
            guard urls.count + errors.count >= expected, let waiting = continuation else { return nil }
            continuation = nil
            return (waiting, result)
        }
        if let (waiting, result) = finished { waiting.resume(with: result) }
    }

    func wait() async throws -> [URL] {
        try await withCheckedThrowingContinuation { waiting in
            let ready: Result<[URL], any Error>? = lock.withLock {
                guard urls.count + errors.count >= expected else {
                    continuation = waiting
                    return nil
                }
                return result
            }
            if let ready { waiting.resume(with: ready) }
        }
    }

    /// Kilit altında çağrılır. Hiç dosya gelmediyse ilk hata; biri bile geldiyse gelenlerle devam.
    private var result: Result<[URL], any Error> {
        if urls.isEmpty, let first = errors.first { return .failure(first) }
        return .success(urls)
    }
}
