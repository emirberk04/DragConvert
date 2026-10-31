import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import HalkaCore

struct ToolCatalogTests {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }
    let registry = FormatRegistry(ffmpeg: FFmpegToolkit(ffmpeg: URL(fileURLWithPath: "/x"), ffprobe: URL(fileURLWithPath: "/y"),
                                                        encoders: ["h264_videotoolbox", "aac_at"]))

    @Test func singleImage() {
        let ids = ToolCatalog.tools(for: [url("a.jpg")], registry: registry).map(\.id)
        #expect(ids == [.compress, .resize, .crop, .rotate, .flip, .removeBackground, .extractText, .strip])
    }

    @Test func severalVideosCanMergeButNotTrim() {
        let ids = ToolCatalog.tools(for: [url("a.mov"), url("b.mp4")], registry: registry).map(\.id)
        #expect(ids.contains(.merge) && !ids.contains(.trim) && !ids.contains(.split))
    }

    @Test func mixedKindsShareCommonTools() {
        let ids = ToolCatalog.tools(for: [url("a.jpg"), url("b.mov")], registry: registry).map(\.id)
        #expect(ids == [.compress, .rotate])
    }

    @Test func mediaNeedsFFmpeg() {
        let none = FormatRegistry(ffmpeg: nil)
        #expect(ToolCatalog.tools(for: [url("a.mov")], registry: none).isEmpty)
    }

    @Test func pageRanges() {
        #expect(PageRange.parse("1-3, 5", pageCount: 6) == [0, 1, 2, 4])
        #expect(PageRange.parse("4-", pageCount: 6) == [3, 4, 5])
        #expect(PageRange.parse("2,2,1", pageCount: 3) == [1, 0])
        #expect(PageRange.parse("0", pageCount: 3) == nil)
        #expect(PageRange.parse("2-9", pageCount: 3) == nil)
        #expect(PageRange.parse("abc", pageCount: 3) == nil)
    }

    @Test func trimSeeksBeforeInput() throws {
        let args = try #require(MediaTools.arguments(
            tool: .trim, options: .trim(start: 1.5, end: 4), input: url("a.mov"), output: url("b.mov"),
            source: registry.format(id: "mov")!, outputFormat: registry.format(id: "mov")!,
            encoders: ["h264_videotoolbox", "aac_at"]))
        let ss = try #require(args.firstIndex(of: "-ss")), input = try #require(args.firstIndex(of: "-i"))
        #expect(ss < input && args[ss + 1] == "1.500")
        #expect(args[args.firstIndex(of: "-t")! + 1] == "2.500")
    }
}

/// Gerçek dosyalarla görüntü ve PDF araçları.
struct ImageAndPDFToolTests {
    let helper = try! ConverterTests()
    var folder: URL { helper.folder }
    let registry = FormatRegistry.shared

    func run(_ tool: ToolID, _ options: ToolOptions = .none, _ files: [URL]) async throws -> [URL] {
        let outcomes = await ToolRunner.run(ToolRequest(tool: tool, files: files, options: options), registry: registry)
        for outcome in outcomes { if case .failed(let m) = outcome.result { Issue.record("\(tool): \(m)") } }
        return outcomes.flatMap(\.outputs)
    }

    func one(_ tool: ToolID, _ options: ToolOptions = .none, _ files: [URL]) async throws -> URL {
        try #require(try await run(tool, options, files).first)
    }

    @Test func cropToSquareFromCentre() async throws {
        let png = try helper.makePNG("kare.png", width: 40, height: 20)
        let output = try await one(.crop, .crop(.centred(aspect: 1, imageAspect: 2)), [png])
        #expect(output.lastPathComponent == "kare - cropped.png")
        let image = try #require(helper.image(at: output))
        #expect(image.width == 20 && image.height == 20)
    }

    @Test func rotateClockwiseMovesLeftToTop() async throws {
        // Sol yarı kırmızı; saat yönünde 90° sonra üst yarı kırmızı olmalı.
        let png = try helper.makePNG("don.png", width: 40, height: 20)
        let output = try await one(.rotate, .rotate(90), [png])
        let image = try #require(helper.image(at: output))
        #expect(image.width == 20 && image.height == 40)
        #expect(helper.pixel(image, x: 10, y: 5).r > 200)
        #expect(helper.pixel(image, x: 10, y: 35).r < 50)
    }

    @Test func flipHorizontalMovesRedRight() async throws {
        let png = try helper.makePNG("ayna.png", width: 40, height: 20)
        let image = try #require(helper.image(at: try await one(.flip, .flip(horizontal: true), [png])))
        #expect(helper.pixel(image, x: 35, y: 10).r > 200 && helper.pixel(image, x: 5, y: 10).r < 50)
    }

    @Test func resizeNeverUpscales() async throws {
        let png = try helper.makePNG("boyut.png", width: 40, height: 20)
        let small = try #require(helper.image(at: try await one(.resize, .resize(.longEdge(10)), [png])))
        #expect(small.width == 10 && small.height == 5)
        let same = try #require(helper.image(at: try await one(.resize, .resize(.longEdge(4000)), [png])))
        #expect(same.width == 40)
        let half = try #require(helper.image(at: try await one(.resize, .resize(.percent(50)), [png])))
        #expect(half.width == 20 && half.height == 10)
    }

    @Test func compressingPNGGivesJPG() async throws {
        let png = try helper.makePNG("buyuk.png", width: 40, height: 20)
        let output = try await one(.compress, .compress(.medium), [png])
        // Saydam PNG → HEIC (saydamlık korunur).
        #expect(output.lastPathComponent == "buyuk - compressed.heic")
    }

    @Test func stripRemovesLocation() async throws {
        let png = try helper.makePNG("gps.png")
        // GPS'li bir JPG üret.
        let jpg = folder.appendingPathComponent("konum.jpg")
        let source = CGImageSourceCreateWithURL(png as CFURL, nil)!
        let destination = CGImageDestinationCreateWithURL(jpg as CFURL, "public.jpeg" as CFString, 1, nil)!
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 41.0, kCGImagePropertyGPSLatitudeRef: "N",
                                    kCGImagePropertyGPSLongitude: 29.0, kCGImagePropertyGPSLongitudeRef: "E"]
        CGImageDestinationAddImageFromSource(destination, source, 0,
                                             [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        func properties(_ url: URL) -> [CFString: Any] {
            CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
        }
        #expect(properties(jpg)[kCGImagePropertyGPSDictionary] != nil)

        let output = try await one(.strip, .none, [jpg])
        #expect(output.lastPathComponent == "konum - clean.jpg")
        let stripped = properties(output)
        #expect(stripped[kCGImagePropertyGPSDictionary] == nil)
        // Yön korunur, yoksa fotoğraf yan döner.
        #expect(stripped[kCGImagePropertyOrientation] as? Int == 6)
    }

    func makePDF(_ name: String, pages: Int) async throws -> URL {
        let images = try (0..<pages).map { try helper.makePNG("\(name)-\($0).png") }
        let pdf = try #require(await Converter.run(.combineIntoPDF(images)).first?.outputs.first)
        let renamed = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: pdf, to: renamed)
        return renamed
    }

    @Test func pdfTools() async throws {
        let pdf = try await makePDF("belge.pdf", pages: 3)
        let extracted = try await one(.extractPages, .pages("2-3"), [pdf])
        #expect(PDFDocument(url: extracted)?.pageCount == 2)

        let parts = try await run(.split, .none, [pdf])
        #expect(parts.map(\.lastPathComponent) == ["belge - sayfa 1.pdf", "belge - sayfa 2.pdf", "belge - sayfa 3.pdf"])

        let rotated = try await one(.rotate, .rotate(90), [pdf])
        #expect(PDFDocument(url: rotated)?.page(at: 0)?.rotation == 90)

        let other = try await makePDF("ek.pdf", pages: 2)
        let merged = try await one(.merge, .merge([other, pdf]), [pdf, other])
        #expect(merged.lastPathComponent == "Merged.pdf" && PDFDocument(url: merged)?.pageCount == 5)

        let compressed = try await one(.compress, .compress(.medium), [pdf])
        #expect(PDFDocument(url: compressed)?.pageCount == 3)
    }

    @Test func badPageRangeExplains() async throws {
        let pdf = try await makePDF("kisa.pdf", pages: 2)
        let outcomes = await ToolRunner.run(ToolRequest(tool: .extractPages, files: [pdf], options: .pages("5")))
        guard case .failed(let message) = outcomes.first?.result else { Issue.record("hata bekleniyordu"); return }
        #expect(message.contains("2 pages"))
    }
}

/// Gerçek ffmpeg ile video ve ses araçları.
@Suite(.enabled(if: vendorFFmpeg != nil, "Vendor/ffmpeg yok"))
struct MediaToolTests {
    let clips = try! FFmpegIntegrationTests()
    var registry: FormatRegistry { clips.registry }

    func run(_ tool: ToolID, _ options: ToolOptions = .none, _ files: [URL]) async throws -> [URL] {
        let outcomes = await ToolRunner.run(ToolRequest(tool: tool, files: files, options: options), registry: registry)
        for outcome in outcomes { if case .failed(let m) = outcome.result { Issue.record("\(tool): \(m)") } }
        return outcomes.flatMap(\.outputs)
    }

    func one(_ tool: ToolID, _ options: ToolOptions = .none, _ files: [URL]) async throws -> URL {
        try #require(try await run(tool, options, files).first)
    }

    @Test func trimRemoveAudioAndCompress() async throws {
        let clip = try await clips.makeClip("video.mov", seconds: 3)
        let trimmed = try await one(.trim, .trim(start: 1, end: 2), [clip])
        #expect(trimmed.lastPathComponent == "video - trimmed.mov")
        let info = try await clips.probe(trimmed)
        #expect(abs((info.duration ?? 0) - 1) < 0.15 && info.videoCodec == "h264")

        let silent = try await one(.removeAudio, .none, [clip])
        #expect(try await clips.probe(silent).audioCodec == nil)

        let small = try await one(.compress, .compress(.strong), [clip])
        #expect(try await clips.probe(small).videoCodec == "h264")

        for options: ToolOptions in [.crop(CropRect(x: 0.25, y: 0, width: 0.5, height: 1)), .rotate(90)] {
            #expect(try await run(options == .rotate(90) ? .rotate : .crop, options, [clip]).count == 1)
        }
    }

    @Test func splitIntoPartsAndMergeBack() async throws {
        let clip = try await clips.makeClip("uzun.mkv", seconds: 4, codec: ["-c:v", "mpeg4", "-g", "25"])
        let parts = try await run(.split, .split(.parts(2)), [clip])
        #expect(parts.map(\.lastPathComponent) == ["uzun - part 1.mkv", "uzun - part 2.mkv"])

        let merged = try await one(.merge, .merge(parts), parts)
        #expect(merged.lastPathComponent == "Merged.mkv")
        #expect(abs((try await clips.probe(merged).duration ?? 0) - 4) < 0.3)
    }

    @Test func mergeDifferentCodecsReencodes() async throws {
        let a = try await clips.makeClip("a.mov", seconds: 1)
        let b = try await clips.makeClip("b.mov", seconds: 1, codec: ["-c:v", "h264_videotoolbox", "-c:a", "aac_at"])
        let merged = try await one(.merge, .merge([a, b]), [a, b])
        #expect(abs((try await clips.probe(merged).duration ?? 0) - 2) < 0.3)
    }

    @Test func audioNormalizeAndExtract() async throws {
        let clip = try await clips.makeClip("konusma.mov", seconds: 2)
        let audio = try await one(.extractAudio, .none, [clip])
        #expect(audio.pathExtension == "m4a")
        let normalized = try await one(.normalize, .none, [audio])
        #expect(normalized.lastPathComponent == "konusma - normalized.m4a")
        #expect(try await clips.probe(normalized).audioCodec == "aac")
    }
}
