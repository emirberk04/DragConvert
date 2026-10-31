import CoreGraphics
import Foundation
import ImageIO

/// Core Graphics ile PDF okuma/yazma. PDFKit AppKit'e bağlı olduğu için HalkaCore'da kullanılmıyor.
enum PDFEngine {
    /// Sayfaların görüntüye dönüştürülme ölçeği: 2 = 144 dpi. VERIFY: H6'da ayarlara taşınabilir.
    static let renderScale = 2.0

    /// Görüntülerden, her biri kendi boyutunda (dikey/yatay korunur) birer sayfalık bir PDF.
    static func writePDF(images: [URL], to destination: URL) throws {
        guard let context = CGContext(destination as CFURL, mediaBox: nil, nil) else {
            throw ConversionError.writeFailed(destination, L("Could not create the PDF.", "PDF oluşturulamadı."))
        }
        for url in images {
            guard let input = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(input) > 0
            else { throw ConversionError.unreadable(url) }
            let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any] ?? [:]
            let image = try ImageEngine.orientedImage(input, source: url)
            var box = CGRect(origin: .zero, size: ImageEngine.pointSize(of: image, properties: properties))
            context.beginPage(mediaBox: &box)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }

    static func pageCount(_ url: URL) throws -> Int {
        guard let document = CGPDFDocument(url as CFURL) else { throw ConversionError.unreadable(url) }
        guard !document.isEncrypted || document.isUnlocked else {
            throw ConversionError.unsupported(url, L("an image (the PDF is password-protected)", "görüntü (PDF parolalı)"))
        }
        return document.numberOfPages
    }

    /// `index` sıfırdan başlar. Beyaz zemin, sayfanın döndürmesi uygulanır.
    static func renderPage(_ url: URL, index: Int, scale: Double = renderScale) throws -> CGImage {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: index + 1)
        else { throw ConversionError.unreadable(url) }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        let width = Int((size.width * scale).rounded()), height = Int((size.height * scale).rounded())
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError.unreadable(url) }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // getDrawingTransform büyütmez, sadece döndürür ve sığdırır; büyütmeyi yukarıdaki ölçek yapar.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ConversionError.unreadable(url) }
        return image
    }
}
