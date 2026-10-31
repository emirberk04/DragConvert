import Foundation
import PDFKit

/// PDF araçları. PDFKit macOS'ta AppKit'e bağlı ama burada sadece belge modeli kullanılıyor (görünüm yok).
public enum PDFTools {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        guard !document.isEncrypted || !document.isLocked else {
            throw ConversionError.failed(L("“\(url.lastPathComponent)” is password-protected; remove the password first.", "“\(url.lastPathComponent)” parolalı; önce kilidini açın."))
        }
        return document
    }

    /// Görüntüleri JPEG olarak ve ekran çözünürlüğünde yeniden kaydeder. Metin ve vektörler değişmez.
    static func compress(_ url: URL, to destination: URL) throws {
        let document = try open(url)
        let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
        guard document.write(to: destination, withOptions: options) else {
            throw ConversionError.writeFailed(destination, L("Could not save the PDF.", "PDF kaydedilemedi."))
        }
    }

    /// `pages` sıfırdan başlar.
    static func extract(_ url: URL, pages: [Int], to destination: URL) throws {
        let document = try open(url)
        let result = PDFDocument()
        for index in pages {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            result.insert(page, at: result.pageCount)
        }
        guard result.pageCount > 0, result.write(to: destination) else {
            throw ConversionError.writeFailed(destination, L("Could not save the PDF.", "PDF kaydedilemedi."))
        }
    }

    static func rotate(_ url: URL, degrees: Int, to destination: URL) throws {
        let document = try open(url)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((page.rotation + degrees) % 360 + 360) % 360
        }
        guard document.write(to: destination) else {
            throw ConversionError.writeFailed(destination, L("Could not save the PDF.", "PDF kaydedilemedi."))
        }
    }

    static func merge(_ urls: [URL], to destination: URL) throws {
        let result = PDFDocument()
        for url in urls {
            let document = try open(url)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                result.insert(page, at: result.pageCount)
            }
        }
        guard result.write(to: destination) else {
            throw ConversionError.writeFailed(destination, L("Could not save the PDF.", "PDF kaydedilemedi."))
        }
    }

    /// PDF parolası sadece ASCII olabilir (PDF standardının eski şifreleme sürümü). PDFKit Türkçe karakterli
    /// parolayı hata vermeden yok sayıp şifresiz kaydediyordu; bu yüzden önceden denetleniyor.
    public static func isValidPassword(_ password: String) -> Bool {
        !password.isEmpty && password.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 && $0.value < 0x7F }
    }

    /// Açmak için parola ister (açma ve sahip parolası aynı). Bağlantılar ve form alanları korunur.
    static func protect(_ url: URL, password: String, to destination: URL) throws {
        guard isValidPassword(password) else {
            throw ConversionError.failed(L("PDF passwords can only use plain ASCII letters, digits and symbols.", "Parola Türkçe karakter (ç, ğ, ı, ö, ş, ü) içeremez; PDF bunu desteklemiyor."))
        }
        let document = try open(url)
        let options: [PDFDocumentWriteOption: Any] = [.userPasswordOption: password, .ownerPasswordOption: password]
        guard document.write(to: destination, withOptions: options), PDFDocument(url: destination)?.isEncrypted == true else {
            throw ConversionError.writeFailed(destination, L("Could not encrypt the PDF.", "PDF şifrelenemedi."))
        }
    }

    static func unprotect(_ url: URL, password: String, to destination: URL) throws {
        guard let document = PDFDocument(url: url) else { throw ConversionError.unreadable(url) }
        if document.isLocked && !document.unlock(withPassword: password) {
            throw ConversionError.failed(L("Wrong password.", "Parola yanlış."))
        }
        guard document.isEncrypted else { throw ConversionError.failed(L("This PDF has no password.", "Bu PDF'in parolası yok.")) }
        // Sayfaları yeni bir belgeye kopyalamak şifrelemeyi kesin olarak bırakır (aynı belgeyi yazmak tutabilir).
        let result = PDFDocument()
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            result.insert(page, at: result.pageCount)
        }
        guard result.write(to: destination) else {
            throw ConversionError.writeFailed(destination, L("Could not save the PDF.", "PDF kaydedilemedi."))
        }
    }

    static func pageCount(_ url: URL) throws -> Int {
        try open(url).pageCount
    }
}
