import CoreGraphics
import Foundation
import ImageIO

public enum ConversionError: Error, Sendable, LocalizedError {
    case unreadable(URL)
    case unsupported(URL, String)
    case writeFailed(URL, String)
    /// Açıklaması hazır bir hata (ör. ffmpeg çıktısından).
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message):
            message
        case .unreadable(let url):
            L("Could not read “\(url.lastPathComponent)”. The file may be damaged or of an unsupported type.", "“\(url.lastPathComponent)” okunamadı. Dosya bozuk ya da bu tür desteklenmiyor olabilir.")
        case .unsupported(let url, let target):
            L("“\(url.lastPathComponent)” cannot be converted to \(target).", "“\(url.lastPathComponent)” \(target) biçimine dönüştürülemiyor.")
        case .writeFailed(let url, let reason):
            L("Could not write “\(url.lastPathComponent)”. \(reason)", "“\(url.lastPathComponent)” yazılamadı. \(reason)")
        }
    }
}

/// ImageIO ile görüntü dönüştürme.
enum ImageEngine {
    /// Kayıplı formatların kalitesi; ayarlardan (varsayılan 0,9).
    static var defaultQuality: Double { Preferences.imageQuality }

    /// EXIF yön etiketini okuyup doğru gösteren formatlar. Diğerlerine piksel olarak döndürülmüş görüntü yazılır.
    private static let keepsOrientationTag: Set<String> = ["jpg", "heic", "tiff", "avif"]
    /// Saydamlık taşıyamayan formatlar; saydam alanlar beyaza düzleştirilir (yoksa siyah çıkar).
    private static let opaqueOnly: Set<String> = ["jpg", "bmp"]

    static func convert(_ source: URL, to target: Format, writingTo destination: URL,
                        quality: Double = defaultQuality) throws {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(input) > 0 else { throw ConversionError.unreadable(source) }

        var properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let hasAlpha = properties[kCGImagePropertyHasAlpha] as? Bool ?? false
        let flatten = hasAlpha && opaqueOnly.contains(target.id)
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]

        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, target.typeIdentifier as CFString, 1, nil)
        else { throw ConversionError.unsupported(source, target.label) }

        if !flatten && keepsOrientationTag.contains(target.id) {
            // Pikselleri yeniden kodlar ama metadata'yı (EXIF, GPS, renk profili, yön) olduğu gibi taşır.
            CGImageDestinationAddImageFromSource(output, input, 0, options as CFDictionary)
        } else {
            var image = try orientedImage(input, source: source)
            if flatten { image = try flattened(image, source: source) }
            // Yön artık piksellerde; etiketi bırakmak görüntüyü bir kez daha döndürürdü.
            properties[kCGImagePropertyOrientation] = 1
            if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                properties[kCGImagePropertyTIFFDictionary] = tiff
            }
            properties.merge(options) { $1 }
            CGImageDestinationAddImage(output, image, properties as CFDictionary)
        }

        guard CGImageDestinationFinalize(output) else {
            throw ConversionError.writeFailed(destination, L("Could not encode the image.", "Görüntü kodlanamadı."))
        }
    }

    /// Bir `CGImage`'i (ör. PDF sayfası) hedef formatta yazar.
    static func write(_ image: CGImage, as target: Format, to destination: URL,
                      quality: Double = defaultQuality) throws {
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, target.typeIdentifier as CFString, 1, nil)
        else { throw ConversionError.unsupported(destination, target.label) }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(output, image, options as CFDictionary)
        guard CGImageDestinationFinalize(output) else {
            throw ConversionError.writeFailed(destination, L("Could not encode the image.", "Görüntü kodlanamadı."))
        }
    }

    /// İlk karenin tam boyutlu, EXIF yönü uygulanmış hali.
    static func orientedImage(_ input: CGImageSource, source: URL) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
        let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
        else { throw ConversionError.unreadable(source) }
        return image
    }

    /// Saydam alanları beyaz zemine oturtur.
    static func flattened(_ image: CGImage, source: URL) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError.unreadable(source) }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ConversionError.unreadable(source) }
        return result
    }

    /// Görüntünün nokta (1/72 inç) cinsinden boyutu; DPI bilgisi yoksa 72.
    static func pointSize(of image: CGImage, properties: [CFString: Any]) -> CGSize {
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        let scale = 72 / (dpi > 0 ? dpi : 72)
        return CGSize(width: Double(image.width) * scale, height: Double(image.height) * scale)
    }
}
