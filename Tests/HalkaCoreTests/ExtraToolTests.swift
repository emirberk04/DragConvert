import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import HalkaCore

/// Arka plan silme, OCR, PDF parola, kırpma bölgesi, ZIP, tahmini boyut.
struct ExtraToolTests {
    let helper = try! ConverterTests()
    var folder: URL { helper.folder }
    let registry = FormatRegistry.shared

    func run(_ tool: ToolID, _ options: ToolOptions = .none, _ files: [URL]) async -> [ConversionOutcome] {
        await ToolRunner.run(ToolRequest(tool: tool, files: files, options: options), registry: registry)
    }

    /// Beyaz zeminde siyah, büyük harflerle metin içeren bir PNG.
    func makeTextImage(_ name: String, text: String) throws -> URL {
        let width = 900, height = 200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let attributed = NSAttributedString(string: text, attributes: [
            .font: CTFontCreateWithName("Helvetica-Bold" as CFString, 56, nil),
            .foregroundColor: CGColor(gray: 0, alpha: 1)])
        context.textPosition = CGPoint(x: 30, y: 75)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        let url = folder.appendingPathComponent(name)
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func ocrReadsImageText() async throws {
        let image = try makeTextImage("ekran.png", text: "Merhaba Halka 2026")
        let outcome = try #require(await run(.extractText, .none, [image]).first)
        let output = try #require(outcome.outputs.first, "\(outcome.result)")
        #expect(output.lastPathComponent == "ekran - text.txt")
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("Merhaba") && text.contains("2026"))
    }

    @Test func scannedPDFFallsBackToOCR() async throws {
        let image = try makeTextImage("tarama.png", text: "Taranmis belge 42")
        let pdf = try #require(await Converter.run(.convert([image], to: registry.format(id: "pdf")!)).first?.outputs.first)
        let outcomes = await Converter.run(.convert([pdf], to: registry.format(id: "txt")!), registry: registry)
        let txt = try #require(outcomes.first?.outputs.first, "\(String(describing: outcomes.first?.result))")
        #expect(try String(contentsOf: txt, encoding: .utf8).contains("belge 42"))
    }

    @Test func removeBackgroundGivesTransparentPNGOrExplains() async throws {
        // Yapay görüntüde ön plan bulunmayabilir; ya saydam PNG ya da açıklamalı hata, asla sessiz başarısızlık.
        let png = try helper.makePNG("nesne.png", width: 200, height: 200)
        let outcome = try #require(await run(.removeBackground, .none, [png]).first)
        switch outcome.result {
        case .written(let urls):
            let source = try #require(CGImageSourceCreateWithURL(urls[0] as CFURL, nil))
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            #expect(properties?[kCGImagePropertyHasAlpha] as? Bool == true)
            #expect(urls[0].lastPathComponent == "nesne - no background.png")
        case .failed(let message):
            #expect(message.contains("found"))
        default:
            Issue.record("beklenmeyen sonuç: \(outcome.result)")
        }
    }

    @Test func pdfPasswordRoundTrip() async throws {
        let png = try helper.makePNG("gizli.png")
        let pdf = try #require(await Converter.run(.convert([png], to: registry.format(id: "pdf")!)).first?.outputs.first)
        let locked = try #require(await run(.protect, .password("sifre123"), [pdf]).first?.outputs.first)
        let lockedDocument = try #require(PDFDocument(url: locked))
        #expect(lockedDocument.isEncrypted && lockedDocument.isLocked)

        let turkish = await run(.protect, .password("şifre"), [pdf])
        guard case .failed(let reason) = turkish.first?.result else { Issue.record("Türkçe parola reddedilmeliydi"); return }
        #expect(reason.contains("ASCII"))

        let wrong = await run(.unprotect, .password("yanlis"), [locked])
        guard case .failed(let message) = wrong.first?.result else { Issue.record("hata bekleniyordu"); return }
        #expect(message.contains("Wrong password"))

        let opened = try #require(await run(.unprotect, .password("sifre123"), [locked]).first?.outputs.first)
        let openDocument = try #require(PDFDocument(url: opened))
        #expect(!openDocument.isEncrypted && openDocument.pageCount == 1)
    }

    @Test func cropRectFromTopLeft() async throws {
        // Sol yarı kırmızı: sol üst çeyrek kırmızı, sağ üst çeyrek saydam.
        let png = try helper.makePNG("bolge.png", width: 40, height: 20)
        let left = try #require(await run(.crop, .crop(CropRect(x: 0, y: 0, width: 0.25, height: 0.5)), [png]).first?.outputs.first)
        let leftImage = try #require(helper.image(at: left))
        #expect(leftImage.width == 10 && leftImage.height == 10)
        #expect(helper.pixel(leftImage, x: 5, y: 5).r > 200)
        let right = try #require(await run(.crop, .crop(CropRect(x: 0.75, y: 0, width: 0.25, height: 0.5)), [png]).first?.outputs.first)
        #expect(helper.pixel(try #require(helper.image(at: right)), x: 5, y: 5).r < 50)
    }

    @Test func zipAndUnzipRoundTrip() async throws {
        let a = try helper.makePNG("a.png"), b = try helper.makePNG("b.png")
        let single = try await ArchiveTools.zip([a])
        #expect(single.lastPathComponent == "a.png.zip")
        let both = try await ArchiveTools.zip([a, b])
        #expect(both.lastPathComponent == "Archive.zip")

        let restored = try await ArchiveTools.unzip(single)
        // a.png zaten var: üzerine yazılmaz.
        #expect(restored.lastPathComponent == "a 2.png")
        let folderOut = try await ArchiveTools.unzip(both)
        #expect(folderOut.lastPathComponent == "Archive")
        let contents = try FileManager.default.contentsOfDirectory(atPath: folderOut.path).sorted()
        #expect(contents == ["a.png", "b.png"])
    }

    @Test func imageCompressionEstimateMatchesReality() async throws {
        let png = try makeTextImage("tahmin.png", text: "Boyut tahmini")
        let estimate = try #require(await SizeEstimate.compress(png, level: .strong))
        let output = try #require(await run(.compress, .compress(.strong), [png]).first?.outputs.first)
        let actual = try #require(try output.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        // Bellekte kodlanan tahmin, yazılanla metadata farkı kadar ayrışabilir.
        #expect(abs(Double(estimate.after) - Double(actual)) / Double(actual) < 0.2)
    }

    @Test func ringOffersUnzipOnlyForArchives() {
        let zips = RingTargets.targets(for: .actions, files: [URL(fileURLWithPath: "/tmp/a.zip")]).map(\.id)
        #expect(zips.contains("action.unzip") && !zips.contains("action.zip"))
        let files = RingTargets.targets(for: .actions, files: [URL(fileURLWithPath: "/tmp/a.png")]).map(\.id)
        #expect(files.contains("action.zip") && !files.contains("action.unzip"))
    }
}

/// Gerçek ffmpeg ile kare alma, önizleme ve video boyut tahmini.
@Suite(.enabled(if: vendorFFmpeg != nil, "Vendor/ffmpeg yok"))
struct VideoExtraTests {
    let clips = try! FFmpegIntegrationTests()

    @Test func frameAtTime() async throws {
        let clip = try await clips.makeClip("kare.mov", seconds: 2)
        let outcomes = await ToolRunner.run(ToolRequest(tool: .frame, files: [clip], options: .frame(at: 1)),
                                            registry: clips.registry)
        let png = try #require(outcomes.first?.outputs.first, "\(String(describing: outcomes.first?.result))")
        #expect(png.lastPathComponent == "kare - frame.png")
        let image = try #require(CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 320 && image.height == 240)
    }

    @Test func previewsAndEstimate() async throws {
        let clip = try await clips.makeClip("onizleme.mov", seconds: 4)
        let strip = await Previews.filmstrip(of: clip, duration: 4, count: 4, registry: clips.registry)
        #expect(strip.count == 4 && strip[0].width <= 160)
        let frame = try #require(await Previews.image(of: clip, at: 2, registry: clips.registry))
        #expect(frame.width == 320)
        // Kare gerçekten çözülmüş olmalı: geçici dosya silindikten sonra tembel okunan JPEG'in alt kısmı griydi.
        // testsrc'nin alt şeridi renkli; düz gri (128) olmamalı.
        let bottom = ConverterTests.pixel(frame, x: 20, y: 230)
        #expect(!(abs(Int(bottom.r) - 128) < 4 && abs(Int(bottom.g) - 128) < 4 && abs(Int(bottom.b) - 128) < 4),
                "alt kısım gri: \(bottom)")
        let estimate = try #require(await SizeEstimate.compress(clip, level: .medium, registry: clips.registry))
        #expect(estimate.after > 0)
    }
}
