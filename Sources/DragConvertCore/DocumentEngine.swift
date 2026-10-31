import Foundation
import PDFKit

/// Metin belgeleri: macOS'un `textutil`'i (DOCX, DOC, RTF, ODT, TXT, HTML birbirine) ve PDF'ten metin.
/// Uygulama açmaz, izin istemez. Düzen basit belgelerde korunur; karmaşık Word düzenleri için Word yolu var.
enum DocumentEngine {
    static let textutil = URL(fileURLWithPath: "/usr/bin/textutil")

    static func convert(_ file: URL, to target: Format, writingTo destination: URL) async throws {
        var args = ["-convert", target.id, "-output", destination.path]
        if target.id == "txt" || target.id == "html" { args += ["-encoding", "UTF-8"] }
        // Bildirimsiz HTML ve düz metin textutil'de Latin-1 sayılıyor; Türkçe karakterler bozuluyordu.
        if ["txt", "text", "html", "htm"].contains(file.pathExtension.lowercased()) { args = ["-inputencoding", "UTF-8"] + args }
        let output = try await ProcessRunner.run(textutil, args + [file.path])
        guard output.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            let reason = output.stderr.split(separator: "\n").last.map(String.init) ?? ""
            throw ConversionError.failed(L("Could not convert “\(file.lastPathComponent)” (textutil: \(reason)).", "“\(file.lastPathComponent)” dönüştürülemedi (textutil: \(reason))."))
        }
    }

    /// PDF'in metni, sayfalar arasında boş satır. Seçilebilir metni olmayan sayfalar (taranmış) OCR'dan geçer.
    static func extractText(_ file: URL, to destination: URL) throws {
        let text = try pdfText(file)
        try text.write(to: destination, atomically: true, encoding: .utf8)
    }

    static func pdfText(_ file: URL) throws -> String {
        let document = try PDFTools.open(file)
        var pages: [String] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let embedded = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !embedded.isEmpty {
                pages.append(embedded)
            } else {
                // 2x çizim OCR için yeterli; daha büyüğü yavaşlatıyor, doğruluğu artırmıyor.
                pages.append(try VisionTools.recognizeText(in: PDFEngine.renderPage(file, index: index, scale: 2)))
            }
        }
        let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ConversionError.failed(L("No readable text found in “\(file.lastPathComponent)”.", "“\(file.lastPathComponent)” içinde okunabilir metin bulunamadı."))
        }
        return text
    }
}
