import Foundation

/// ZIP: macOS'un `ditto`'su (Finder'ın "Sıkıştır"ı ile aynı biçim; Türkçe adlar ve izinler korunur).
public enum ArchiveTools {
    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")

    /// Tek öğe → Finder gibi `ad.uzantı.zip`; birden çok → ilk öğenin klasöründe `Arşiv.zip`. Var olan dosyanın üzerine yazılmaz.
    public static func zip(_ items: [URL], in directory: URL? = nil) async throws -> URL {
        guard let first = items.first else { throw ConversionError.failed(L("Nothing to zip.", "Sıkıştırılacak dosya yok.")) }
        if items.count == 1 {
            return try await AtomicOutput.write(beside: first, stem: first.lastPathComponent, pathExtension: "zip",
                                                in: directory) {
                // Klasörde --keepParent arşive klasörün adını koyar; dosyada ise üst klasörü ekler, kullanılmaz.
                let isFolder = (try? first.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                try await run(["-c", "-k", "--sequesterRsrc"] + (isFolder ? ["--keepParent"] : []) + [first.path, $0.path],
                              file: first)
            }
        }
        return try await AtomicOutput.write(beside: first, stem: L("Archive", "Arşiv"), pathExtension: "zip", in: directory) { output in
            // Farklı klasörlerdeki öğeleri tek arşivin köküne koymak için bir hazırlık klasörü; APFS'te kopya
            // klon olduğu için yer kaplamaz ve hızlıdır.
            let staging = output.deletingLastPathComponent().appendingPathComponent("hazırlık", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            for item in items {
                let target = OutputNaming.destination(for: item, pathExtension: item.pathExtension, in: staging)
                try FileManager.default.copyItem(at: item, to: target)
            }
            try await run(["-c", "-k", "--sequesterRsrc", staging.path, output.path], file: first)
        }
    }

    /// Tek öğe içeren arşiv o öğeyi, birden çok içeren arşiv adını taşıyan bir klasörü yanına çıkarır.
    public static func unzip(_ archive: URL, in directory: URL? = nil) async throws -> URL {
        let folder = directory ?? archive.deletingLastPathComponent()
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: folder, create: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let extracted = scratch.appendingPathComponent("çıkan", isDirectory: true)
        try await run(["-x", "-k", archive.path, extracted.path], file: archive)
        let items = try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
        let (source, name): (URL, String) = items.count == 1
            ? (items[0], items[0].lastPathComponent)
            : (extracted, archive.deletingPathExtension().lastPathComponent)
        // Kaynak olarak arşivin kendisi: çıkan ad onunla aynı olamaz, var olanların üzerine de yazılmaz.
        let destination = OutputNaming.destination(for: archive, stem: (name as NSString).deletingPathExtension,
                                                   pathExtension: (name as NSString).pathExtension, in: folder)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private static func run(_ args: [String], file: URL) async throws {
        let output = try await ProcessRunner.run(ditto, args)
        guard output.status == 0 else {
            let reason = output.stderr.split(separator: "\n").last.map(String.init) ?? ""
            throw ConversionError.failed(L("Could not process “\(file.lastPathComponent)” (ditto: \(reason)).", "“\(file.lastPathComponent)” işlenemedi (ditto: \(reason))."))
        }
    }
}
