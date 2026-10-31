import CoreImage
import Foundation
import ImageIO
import Vision

/// macOS'un Vision çatısıyla, cihazda: arka plan silme ve metin tanıma (OCR). İnternet yok, model indirme yok.
enum VisionTools {
    /// Ön plandaki kişi/nesneler kalır, arka plan saydam; çıktı PNG.
    static func removeBackground(_ file: URL, to destination: URL, registry: FormatRegistry) throws {
        guard let input = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(input) > 0
        else { throw ConversionError.unreadable(file) }
        let image = try ImageEngine.orientedImage(input, source: file)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw ConversionError.failed(L("No person or object to separate was found in “\(file.lastPathComponent)”.", "“\(file.lastPathComponent)” içinde ayrılabilecek bir kişi ya da nesne bulunamadı."))
        }
        let masked = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: masked)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let output = CIContext().createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: space)
        else { throw ConversionError.unreadable(file) }
        try ImageEngine.write(output, as: registry.format(id: "png")!, to: destination)
    }

    /// Görüntüdeki metin, satır satır. Türkçe ve İngilizce.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["tr-TR", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func recognizeText(in file: URL) throws -> String {
        guard let input = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(input) > 0
        else { throw ConversionError.unreadable(file) }
        return try recognizeText(in: ImageEngine.orientedImage(input, source: file))
    }
}
