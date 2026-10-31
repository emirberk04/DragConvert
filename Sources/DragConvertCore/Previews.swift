import CoreGraphics
import Foundation
import ImageIO
import PDFKit

/// Panellerin önizlemeleri: görüntünün kendisi, videodan kare, film şeridi. Hepsi küçük ve yönü düzeltilmiş.
public enum Previews {
    /// Görüntü dosyası, PDF'in ilk sayfası veya videonun `seconds` anındaki karesi.
    public static func image(of file: URL, at seconds: Double = 0, maxEdge: Int = 900,
                             registry: FormatRegistry = .shared) async -> CGImage? {
        guard let format = registry.format(for: file) else { return nil }
        switch format.kind {
        case .image:
            guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxEdge,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .pdf:
            return try? PDFEngine.renderPage(file, index: 0, scale: 1)
        case .movie:
            return await videoFrame(file, at: seconds, maxEdge: maxEdge, registry: registry)
        default:
            return nil
        }
    }

    /// Eşit aralıklı kareler (kes ve kare al panellerinin şeridi).
    public static func filmstrip(of file: URL, duration: Double, count: Int, maxEdge: Int = 160,
                                 registry: FormatRegistry = .shared) async -> [CGImage] {
        var frames: [CGImage] = []
        for index in 0..<count {
            let time = duration * (Double(index) + 0.5) / Double(count)
            if let frame = await videoFrame(file, at: time, maxEdge: maxEdge, registry: registry) { frames.append(frame) }
        }
        return frames
    }

    static func videoFrame(_ file: URL, at seconds: Double, maxEdge: Int, registry: FormatRegistry) async -> CGImage? {
        guard let toolkit = registry.ffmpeg else { return nil }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("dragconvert-kare-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }
        let scale = "scale='if(gte(iw,ih),min(iw,\(maxEdge)),-2)':'if(gte(iw,ih),-2,min(ih,\(maxEdge)))'"
        let args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-ss", MediaTools.seconds(seconds),
                    "-i", file.path, "-frames:v", "1", "-update", "1", "-vf", scale, "-q:v", "4", output.path]
        // Dosya hemen siliniyor: ImageIO pikselleri tembel (çizilirken) okur, dosyadan okursa silinmiş dosyanın sadece
        // önceden okunan üst şeridi gelir, gerisi gri kalırdı. Önce bütün veri belleğe, sonra hemen çözülür.
        guard let result = try? await ProcessRunner.run(toolkit.ffmpeg, args), result.status == 0,
              let data = try? Data(contentsOf: output),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Sıkıştırmadan önce "ne kadar küçülür" tahmini.
public enum SizeEstimate {
    public struct Result: Sendable, Equatable {
        public let before: Int64
        public let after: Int64
    }

    public static func compress(_ file: URL, level: CompressLevel, registry: FormatRegistry = .shared) async -> Result? {
        guard let format = registry.format(for: file),
              let before = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        else { return nil }
        switch format.kind {
        case .image:
            // Gerçekten kodlar (bellekte); görüntüler hızlı.
            guard let result = try? ImageTools.process(file, options: .compress(level), registry: registry) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, result.format.typeIdentifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, result.image,
                                       [kCGImageDestinationLossyCompressionQuality: result.quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            return Result(before: before, after: Int64(data.length))
        case .audio:
            guard let duration = await ToolRunner.duration(of: file, registry: registry) else { return nil }
            let kbps: Double = switch level {
            case .light: 192
            case .medium: 128
            case .strong: 96
            }
            return Result(before: before, after: Int64(kbps * 1000 / 8 * duration))
        case .movie:
            return await sampleVideo(file, level: level, before: before, registry: registry)
        case .pdf:
            let output = FileManager.default.temporaryDirectory.appendingPathComponent("dragconvert-tahmin-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: output) }
            guard (try? PDFTools.compress(file, to: output)) != nil,
                  let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
            return Result(before: before, after: Int64(size))
        default:
            return nil
        }
    }

    /// Ortadan 3 saniyeyi aynı ayarlarla kodlar, süreye oranlar. Donanım kodlayıcıyla ~1 sn.
    static func sampleVideo(_ file: URL, level: CompressLevel, before: Int64, registry: FormatRegistry) async -> Result? {
        guard let toolkit = registry.ffmpeg, let source = registry.format(for: file),
              let duration = await ToolRunner.duration(of: file, registry: registry), duration > 0 else { return nil }
        let sample = min(3, duration)
        let start = max(0, duration / 2 - sample / 2)
        let format = MediaTools.outputFormat(for: source, registry: registry)
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("dragconvert-tahmin-\(UUID().uuidString).\(format.pathExtension)")
        defer { try? FileManager.default.removeItem(at: output) }
        guard var args = MediaTools.arguments(tool: .compress, options: .compress(level), input: file, output: output,
                                              source: source, outputFormat: format, encoders: toolkit.encoders),
              let input = args.firstIndex(of: "-i") else { return nil }
        args.insert(contentsOf: ["-ss", MediaTools.seconds(start)], at: input)
        args.insert(contentsOf: ["-t", MediaTools.seconds(sample)], at: input + 4)
        guard let result = try? await ProcessRunner.run(toolkit.ffmpeg, args), result.status == 0,
              let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Result(before: before, after: Int64(Double(size) * duration / sample))
    }
}
