import Foundation
import PDFKit
import Testing
@testable import HalkaCore

struct DocumentRegistryTests {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    let withOffice = FormatRegistry(office: OfficeApps(word: true, powerpoint: true, excel: true))
    let without = FormatRegistry(office: OfficeApps())

    @Test func kinds() {
        #expect(FileKind(url: url("a.docx")) == .document)
        #expect(FileKind(url: url("a.rtf")) == .document)
        #expect(FileKind(url: url("a.pptx")) == .presentation)
        #expect(FileKind(url: url("a.xlsx")) == .spreadsheet)
        #expect(FileKind(url: url("a.csv")) == .spreadsheet)
    }

    @Test func wordDocumentTargets() {
        let docx = withOffice.format(id: "docx")!
        #expect(withOffice.targets(from: docx).map(\.id) == ["pdf", "doc", "rtf", "odt", "txt", "html"])
        // Word yoksa PDF yok, metin dönüşümleri (textutil) yine var.
        #expect(without.targets(from: docx).map(\.id) == ["doc", "rtf", "odt", "txt", "html"])
    }

    @Test func pdfToDocumentNeedsWordOnlyForDocx() {
        let pdf = withOffice.format(id: "pdf")!
        #expect(withOffice.targets(from: pdf).map(\.id).suffix(2) == ["docx", "txt"])
        #expect(!without.targets(from: pdf).map(\.id).contains("docx"))
        #expect(without.targets(from: pdf).map(\.id).contains("txt"))
    }

    @Test func officeFormatsNeedTheirApp() {
        #expect(withOffice.targets(from: withOffice.format(id: "pptx")!).map(\.id) == ["pdf", "ppt"])
        #expect(withOffice.targets(from: withOffice.format(id: "csv")!).map(\.id) == ["pdf", "xlsx", "xls"])
        #expect(without.targets(from: without.format(id: "xlsx")!).isEmpty)
        #expect(withOffice.officeApp(for: withOffice.format(id: "docx")!, to: withOffice.format(id: "pdf")!) == .word)
        #expect(withOffice.officeApp(for: withOffice.format(id: "docx")!, to: withOffice.format(id: "rtf")!) == nil)
    }

    @Test func officeScriptsUseTheAppsOwnTempFolder() {
        let script = OfficeEngine.script(app: .powerpoint, format: OfficeEngine.saveFormat(app: .powerpoint, target: "pdf")!)
        #expect(script.contains("save as PDF") && script.contains("path to temporary items"))
        #expect(OfficeEngine.saveFormat(app: .excel, target: "csv") == "CSV file format")
        #expect(OfficeEngine.saveFormat(app: .word, target: "pptx") == nil)
        #expect(OfficeEngine.explain("execution error: Not authorized to send Apple events to Microsoft Word. (-1743)",
                                     app: .word, file: url("a.docx")).contains("Automation"))
    }
}

/// Gerçek dosyalarla `textutil` ve PDF metni (Office otomasyonu izin istediği için elle denenir).
struct DocumentConversionTests {
    let helper = try! ConverterTests()
    var folder: URL { helper.folder }
    let registry = FormatRegistry(office: OfficeApps())

    func convert(_ file: URL, to id: String) async throws -> URL {
        let outcomes = await Converter.run(.convert([file], to: registry.format(id: id)!), registry: registry)
        if case .failed(let message) = outcomes.first?.result { Issue.record("\(id): \(message)") }
        return try #require(outcomes.first?.outputs.first)
    }

    @Test func htmlToDocxAndBackKeepsText() async throws {
        let html = folder.appendingPathComponent("not.html")
        try "<html><body><h1>Başlık</h1><p>Merhaba <b>dünya</b>, çğıöşü.</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        let docx = try await convert(html, to: "docx")
        #expect(docx.lastPathComponent == "not.docx")
        for id in ["rtf", "odt", "doc", "txt"] {
            let output = try await convert(docx, to: id)
            #expect(output.pathExtension == id)
        }
        let text = try String(contentsOf: try await convert(docx, to: "txt"), encoding: .utf8)
        #expect(text.contains("Merhaba dünya, çğıöşü."))
    }

    @Test func pdfToText() async throws {
        // PDF'e metin yazmak için RTF → PDF yerine PDFKit: bir sayfaya metin ek açıklaması yeterli değil;
        // Core Text ile metinli bir PDF çiz.
        let pdf = folder.appendingPathComponent("metin.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(pdf as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let attributed = NSAttributedString(string: "Halka deneme metni",
                                            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 18, nil)])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 20, y: 100)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        let text = try String(contentsOf: try await convert(pdf, to: "txt"), encoding: .utf8)
        #expect(text.contains("Halka deneme metni"))
    }

    @Test func imageOnlyPDFExplainsMissingText() async throws {
        let png = try helper.makePNG("tarama.png")
        let pdf = try #require(await Converter.run(.convert([png], to: registry.format(id: "pdf")!)).first?.outputs.first)
        let outcomes = await Converter.run(.convert([pdf], to: registry.format(id: "txt")!), registry: registry)
        guard case .failed(let message) = outcomes.first?.result else { Issue.record("hata bekleniyordu"); return }
        #expect(message.contains("No readable text"))
    }
}
