import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HalkaCore

/// Gerçek dosyalarla: geçici bir klasörde küçük görüntüler üretilir, dönüştürülür ve sonuç ImageIO ile okunur.
struct ConverterTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HalkaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// Sol yarısı kırmızı, sağ yarısı saydam (alpha) bir PNG.
    func makePNG(_ name: String, width: Int = 40, height: Int = 20) throws -> URL {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        Self.pixel(image, x: x, y: y)
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        var data = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (data[0], data[1], data[2])
    }

    func format(_ id: String) -> Format { FormatRegistry.shared.format(id: id)! }

    @Test func pngToJPGBesideOriginalWithWhiteBackground() async throws {
        let source = try makePNG("logo.png")
        let outcomes = await Converter.run(.convert([source], to: format("jpg")))
        let output = try #require(outcomes.first?.outputs.first)
        #expect(output.lastPathComponent == "logo.jpg")
        #expect(output.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        let image = try #require(image(at: output))
        #expect(image.width == 40 && image.height == 20)
        // Saydam yarı siyah değil beyaz olmalı.
        let right = pixel(image, x: 30, y: 10)
        #expect(right.r > 240 && right.g > 240 && right.b > 240)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func neverOverwritesExistingOutput() async throws {
        let source = try makePNG("foto.png")
        try Data("eski".utf8).write(to: folder.appendingPathComponent("foto.heic"))
        let outcomes = await Converter.run(.convert([source], to: format("heic")))
        #expect(outcomes.first?.outputs.first?.lastPathComponent == "foto 2.heic")
        #expect(try String(contentsOf: folder.appendingPathComponent("foto.heic"), encoding: .utf8) == "eski")
    }

    @Test func batchKeepsOrderAndSkipsSameFormat() async throws {
        let a = try makePNG("a.png"), b = try makePNG("b.png")
        let jpg = folder.appendingPathComponent("c.jpg")
        _ = await Converter.run(.convert([a], to: format("jpg")))
        try FileManager.default.moveItem(at: folder.appendingPathComponent("a.jpg"), to: jpg)

        let outcomes = await Converter.run(.convert([a, jpg, b], to: format("jpg")))
        #expect(outcomes.map(\.sources.first!.lastPathComponent) == ["a.png", "c.jpg", "b.png"])
        if case .skipped = outcomes[1].result {} else { Issue.record("c.jpg atlanmalıydı") }
        #expect(outcomes[2].outputs.first?.lastPathComponent == "b.jpg")
    }

    @Test func imagesCombineIntoOneMultiPagePDF() async throws {
        let wide = try makePNG("1.png", width: 60, height: 20)
        let tall = try makePNG("2.png", width: 20, height: 60)
        let outcomes = await Converter.run(.combineIntoPDF([wide, tall]))
        let pdf = try #require(outcomes.first?.outputs.first)
        #expect(pdf.lastPathComponent == "Merged.pdf")
        let document = try #require(CGPDFDocument(pdf as CFURL))
        #expect(document.numberOfPages == 2)
        // Her sayfa kendi görüntüsünün yönünde.
        #expect(document.page(at: 1)!.getBoxRect(.mediaBox).size == CGSize(width: 60, height: 20))
        #expect(document.page(at: 2)!.getBoxRect(.mediaBox).size == CGSize(width: 20, height: 60))
    }

    @Test func multiPagePDFBecomesNumberedImages() async throws {
        let a = try makePNG("1.png"), b = try makePNG("2.png")
        let pdf = try #require(await Converter.run(.combineIntoPDF([a, b])).first?.outputs.first)
        let outcomes = await Converter.run(.convert([pdf], to: format("png")))
        let names = outcomes.first?.outputs.map(\.lastPathComponent)
        #expect(names == ["Merged - page 1.png", "Merged - page 2.png"])
        // 2x ölçek: 40×20 pt sayfa → 80×40 px.
        let page = try #require(image(at: outcomes[0].outputs[0]))
        #expect(page.width == 80 && page.height == 40)
    }

    @Test func singleImageToPDF() async throws {
        let source = try makePNG("tek.png")
        let outcomes = await Converter.run(.convert([source], to: format("pdf")))
        let pdf = try #require(outcomes.first?.outputs.first)
        #expect(pdf.lastPathComponent == "tek.pdf")
        #expect(CGPDFDocument(pdf as CFURL)?.numberOfPages == 1)
    }

    @Test func corruptFileFailsWithMessage() async throws {
        let bad = folder.appendingPathComponent("bozuk.png")
        try Data("bu bir png değil".utf8).write(to: bad)
        let outcomes = await Converter.run(.convert([bad], to: format("jpg")))
        guard case .failed(let message) = outcomes.first?.result else {
            Issue.record("hata bekleniyordu")
            return
        }
        #expect(message.contains("bozuk.png"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("bozuk.jpg").path))
    }
}
