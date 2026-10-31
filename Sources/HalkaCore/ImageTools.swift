import CoreGraphics
import Foundation
import ImageIO

/// Görüntü araçları: yönü düzeltilmiş görüntü üzerinde Core Graphics ile, metadata (yön hariç) korunarak.
enum ImageTools {
    struct Result {
        let image: CGImage
        let format: Format
        let quality: Double
    }

    /// Çıktı formatı ve kalitesi; sıkıştırmada kayıpsız kaynaklar JPG'ye (saydamsa HEIC'e) geçer.
    static func process(_ file: URL, options: ToolOptions, registry: FormatRegistry) throws -> Result {
        guard let input = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(input) > 0,
              let source = registry.format(for: file) else { throw ConversionError.unreadable(file) }
        var image = try ImageEngine.orientedImage(input, source: file)
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        var format = registry.imageIOWrites(source) ? source : registry.format(id: "png")!
        var quality = ImageEngine.defaultQuality

        switch options {
        case .compress(let level):
            let (q, edge): (Double, Int?) = switch level {
            case .light: (0.8, nil)
            case .medium: (0.6, 3000)
            case .strong: (0.45, 1920)
            }
            quality = q
            if let edge { image = try scaled(image, longEdge: edge, file: file) }
            if !["jpg", "heic", "avif", "webp"].contains(format.id) {
                format = registry.format(id: hasAlpha ? "heic" : "jpg")!
            }
        case .resize(.percent(let percent)):
            let edge = Int(Double(max(image.width, image.height)) * Double(percent) / 100)
            image = try scaled(image, longEdge: max(edge, 1), file: file)
        case .resize(.longEdge(let edge)):
            image = try scaled(image, longEdge: edge, file: file)
        case .crop(let rect):
            image = try cropped(image, to: rect, file: file)
        case .rotate(let degrees):
            image = try rotated(image, degrees: degrees, file: file)
        case .flip(let horizontal):
            image = try flipped(image, horizontal: horizontal, file: file)
        default:
            throw ConversionError.failed(L("This tool does not work on images.", "Bu araç görüntülere uygulanamıyor."))
        }
        return Result(image: image, format: format, quality: quality)
    }

    /// Sonucu, kaynağın metadata'sını (EXIF, GPS, renk profili) taşıyarak yazar; yön artık piksellerde.
    static func write(_ result: Result, from file: URL, to destination: URL) throws {
        guard let input = CGImageSourceCreateWithURL(file as CFURL, nil),
              let output = CGImageDestinationCreateWithURL(destination as CFURL,
                                                           result.format.typeIdentifier as CFString, 1, nil)
        else { throw ConversionError.unsupported(file, result.format.label) }
        var properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        properties[kCGImagePropertyOrientation] = 1
        properties[kCGImagePropertyPixelWidth] = nil
        properties[kCGImagePropertyPixelHeight] = nil
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = result.image.width
            exif[kCGImagePropertyExifPixelYDimension] = result.image.height
            properties[kCGImagePropertyExifDictionary] = exif
        }
        properties[kCGImageDestinationLossyCompressionQuality] = result.quality
        let image = ["jpg", "bmp"].contains(result.format.id)
            ? try ImageEngine.flattened(result.image, source: file) : result.image
        CGImageDestinationAddImage(output, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw ConversionError.writeFailed(destination, L("Could not encode the image.", "Görüntü kodlanamadı."))
        }
    }

    /// Konum, kamera, tarih gibi bütün metadata'yı siler; mümkünse pikselleri yeniden kodlamadan.
    static func stripMetadata(_ file: URL, to destination: URL, format: Format) throws {
        guard let input = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(input) > 0
        else { throw ConversionError.unreadable(file) }
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1

        if let output = CGImageDestinationCreateWithURL(destination as CFURL, format.typeIdentifier as CFString, 1, nil) {
            // Boş metadata, yön etiketi hariç: yoksa telefon fotoğrafı yan döner.
            let metadata = CGImageMetadataCreateMutable()
            if orientation != 1 {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary,
                                                             kCGImagePropertyTIFFOrientation, orientation as CFNumber)
            }
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: metadata,
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
            ]
            var error: Unmanaged<CFError>?
            if CGImageDestinationCopyImageSource(output, input, options as CFDictionary, &error) { return }
            try? FileManager.default.removeItem(at: destination)
        }
        // Kayıpsız kopya bu formatta desteklenmiyor: yeniden kodla, sadece piksel ve renk profili.
        let image = try ImageEngine.orientedImage(input, source: file)
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, format.typeIdentifier as CFString, 1, nil)
        else { throw ConversionError.unsupported(file, format.label) }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw ConversionError.writeFailed(destination, L("Could not encode the image.", "Görüntü kodlanamadı."))
        }
    }

    // MARK: Dönüşümler

    static func scaled(_ image: CGImage, longEdge: Int, file: URL) throws -> CGImage {
        let current = max(image.width, image.height)
        guard longEdge < current else { return image }
        let scale = Double(longEdge) / Double(current)
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)
        return try draw(width: width, height: height, like: image, file: file) { context in
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    /// `CGImage.cropping` sol üst köşeden ölçer, `CropRect` de öyle.
    static func cropped(_ image: CGImage, to crop: CropRect, file: URL) throws -> CGImage {
        let width = Double(image.width), height = Double(image.height)
        let rect = CGRect(x: (crop.x * width).rounded(), y: (crop.y * height).rounded(),
                          width: max((crop.width * width).rounded(), 1), height: max((crop.height * height).rounded(), 1))
        guard let result = image.cropping(to: rect) else { throw ConversionError.unreadable(file) }
        return result
    }

    static func rotated(_ image: CGImage, degrees: Int, file: URL) throws -> CGImage {
        let quarter = ((degrees % 360) + 360) % 360
        let swaps = quarter == 90 || quarter == 270
        let width = swaps ? image.height : image.width, height = swaps ? image.width : image.height
        return try draw(width: width, height: height, like: image, file: file) { context in
            context.translateBy(x: Double(width) / 2, y: Double(height) / 2)
            // Core Graphics açıları saat yönünün tersine.
            context.rotate(by: -Double(quarter) * .pi / 180)
            context.draw(image, in: CGRect(x: -Double(image.width) / 2, y: -Double(image.height) / 2,
                                           width: Double(image.width), height: Double(image.height)))
        }
    }

    static func flipped(_ image: CGImage, horizontal: Bool, file: URL) throws -> CGImage {
        try draw(width: image.width, height: image.height, like: image, file: file) { context in
            if horizontal {
                context.translateBy(x: Double(image.width), y: 0)
                context.scaleBy(x: -1, y: 1)
            } else {
                context.translateBy(x: 0, y: Double(image.height))
                context.scaleBy(x: 1, y: -1)
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
    }

    private static func draw(width: Int, height: Int, like image: CGImage, file: URL,
                             _ body: (CGContext) -> Void) throws -> CGImage {
        let space = image.colorSpace.flatMap { $0.supportsOutput ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.unreadable(file) }
        body(context)
        guard let result = context.makeImage() else { throw ConversionError.unreadable(file) }
        return result
    }
}
