import Foundation

/// Çıktı dosyasının adı ve yeri.
///
/// Kural: çıktı varsayılan olarak kaynağın yanına yazılır ve var olan hiçbir dosyanın (kaynağın kendisi
/// dahil) üzerine yazılmaz. Ad doluysa Finder'ın kopyalarda yaptığı gibi numara eklenir: `foto.jpg`,
/// `foto 2.jpg`, `foto 3.jpg`.
public enum OutputNaming {
    /// - Parameters:
    ///   - source: Dönüştürülen dosya.
    ///   - stem: Uzantısız ad; `nil` ise kaynağın adı (`"rapor - sayfa 2"` gibi türetilmiş adlar için).
    ///   - pathExtension: Hedef uzantı (`"jpg"`). Boşsa uzantısız ad üretilir.
    ///   - directory: Çıktı klasörü; `nil` ise kaynağın klasörü.
    ///   - exists: Bir yolun dolu olup olmadığı. Testlerde değiştirilebilsin diye parametre.
    public static func destination(
        for source: URL,
        stem: String? = nil,
        pathExtension: String,
        in directory: URL? = nil,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let folder = directory ?? source.deletingLastPathComponent()
        let stem = stem ?? source.deletingPathExtension().lastPathComponent

        func candidate(_ number: Int) -> URL {
            let name = number == 1 ? stem : "\(stem) \(number)"
            let url = folder.appendingPathComponent(name, isDirectory: false)
            return pathExtension.isEmpty ? url : url.appendingPathExtension(pathExtension)
        }

        var number = 1
        while true {
            let url = candidate(number)
            // Kaynağın kendisi diskte olmasa bile (ör. testte) hedef asla kaynakla aynı olamaz.
            if url.standardizedFileURL != source.standardizedFileURL && !exists(url) {
                return url
            }
            number += 1
        }
    }
}
