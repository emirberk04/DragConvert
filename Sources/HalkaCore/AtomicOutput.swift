import Foundation

/// Çıktıyı önce geçici bir dosyaya yazar, bitince boş bir ada taşır.
///
/// Böylece yarım kalmış (veya iptal edilmiş) bir iş hedef klasörde bozuk dosya bırakmaz ve iş sürerken aynı ada
/// başka bir dosya yazılmışsa üzerine yazılmaz (taşıma "dosya var" hatası verir, bir sonraki numara denenir).
enum AtomicOutput {
    static func write(beside source: URL, stem: String? = nil, pathExtension: String, in directory: URL? = nil,
                      _ body: (URL) throws -> Void) throws -> URL {
        let slot = try Slot(source: source, stem: stem, pathExtension: pathExtension, directory: directory)
        defer { slot.cleanUp() }
        try body(slot.temporary)
        return try slot.commit()
    }

    static func write(beside source: URL, stem: String? = nil, pathExtension: String, in directory: URL? = nil,
                      _ body: (URL) async throws -> Void) async throws -> URL {
        let slot = try Slot(source: source, stem: stem, pathExtension: pathExtension, directory: directory)
        defer { slot.cleanUp() }
        try await body(slot.temporary)
        try Task.checkCancellation()
        return try slot.commit()
    }

    private struct Slot {
        let source: URL, stem: String?, pathExtension: String, folder: URL
        let scratch: URL, temporary: URL

        init(source: URL, stem: String?, pathExtension: String, directory: URL?) throws {
            self.source = source
            self.stem = stem
            self.pathExtension = pathExtension
            folder = directory ?? source.deletingLastPathComponent()
            let provisional = OutputNaming.destination(for: source, stem: stem, pathExtension: pathExtension, in: folder)
            scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: folder, create: true)
            temporary = scratch.appendingPathComponent(provisional.lastPathComponent)
        }

        func commit() throws -> URL {
            for _ in 0..<1000 {
                let destination = OutputNaming.destination(for: source, stem: stem, pathExtension: pathExtension,
                                                           in: folder)
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    return destination
                } catch let error as CocoaError where error.code == .fileWriteFileExists {
                    continue
                }
            }
            throw ConversionError.writeFailed(temporary, L("Could not find a free file name.", "Uygun bir dosya adı bulunamadı."))
        }

        func cleanUp() {
            try? FileManager.default.removeItem(at: scratch)
        }
    }
}
