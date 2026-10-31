import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bilinen bir dosya formatı.
public struct Format: Sendable, Equatable, Hashable, Identifiable {
    /// Kısa ad; aynı zamanda varsayılan uzantı (`"jpg"`).
    public let id: String
    public let label: String
    /// İlki çıktıda kullanılır.
    public let extensions: [String]
    /// Uniform Type Identifier (`"public.jpeg"`).
    public let typeIdentifier: String
    public let kind: FileKind
    /// Halkada gösterilen SF Symbol.
    public let symbol: String

    public var pathExtension: String { extensions[0] }
}

/// Formatlar ve aralarındaki dönüşümler. Halka, motorlar ve testler aynı kaynaktan beslenir.
///
/// Görüntü formatlarının okunup yazılabildiği sabit değil, ImageIO'ya sorulur
/// (`CGImageSourceCopyTypeIdentifiers` / `CGImageDestinationCopyTypeIdentifiers`): macOS sürümüne göre değişir.
/// Video, ses ve ImageIO'nun yazamadığı görüntüler (WebP) ffmpeg'le; hangi hedefin mümkün olduğu bulunan
/// ffmpeg'in kodlayıcı listesine bakılarak belirlenir. Metin belgeleri birbirine macOS'un `textutil`'iyle;
/// PDF'e ve Office formatlarına kurulu Word/PowerPoint/Excel ile. Yapılamayan bir hedef halkada hiç görünmez.
public struct FormatRegistry: Sendable {
    public let formats: [Format]
    public let ffmpeg: FFmpegToolkit?
    public let office: OfficeApps
    private let readable: Set<String>
    private let writable: Set<String>

    /// İlk kullanımda ffmpeg'i arar ve kodlayıcılarını sorar (bir alt süreç); uygulama açılışta arka planda ısıtır.
    public static let shared = FormatRegistry(ffmpeg: FFmpegToolkit.locate(), office: .installed())

    public init(
        formats: [Format] = FormatRegistry.builtIn,
        readable: Set<String> = Set(CGImageSourceCopyTypeIdentifiers() as? [String] ?? []),
        writable: Set<String> = Set(CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []),
        ffmpeg: FFmpegToolkit? = nil,
        office: OfficeApps = OfficeApps()
    ) {
        self.formats = formats
        self.readable = readable
        self.writable = writable
        self.ffmpeg = ffmpeg
        self.office = office
    }

    public static let builtIn: [Format] = [
        // Görüntü
        Format(id: "jpg", label: "JPG", extensions: ["jpg", "jpeg"], typeIdentifier: "public.jpeg", kind: .image, symbol: "photo"),
        Format(id: "png", label: "PNG", extensions: ["png"], typeIdentifier: "public.png", kind: .image, symbol: "photo"),
        Format(id: "heic", label: "HEIC", extensions: ["heic", "heif"], typeIdentifier: "public.heic", kind: .image, symbol: "photo"),
        Format(id: "tiff", label: "TIFF", extensions: ["tiff", "tif"], typeIdentifier: "public.tiff", kind: .image, symbol: "photo"),
        Format(id: "webp", label: "WebP", extensions: ["webp"], typeIdentifier: "org.webmproject.webp", kind: .image, symbol: "photo"),
        Format(id: "avif", label: "AVIF", extensions: ["avif"], typeIdentifier: "public.avif", kind: .image, symbol: "photo"),
        Format(id: "gif", label: "GIF", extensions: ["gif"], typeIdentifier: "com.compuserve.gif", kind: .image, symbol: "photo.stack"),
        Format(id: "bmp", label: "BMP", extensions: ["bmp"], typeIdentifier: "com.microsoft.bmp", kind: .image, symbol: "photo"),
        Format(id: "psd", label: "PSD", extensions: ["psd"], typeIdentifier: "com.adobe.photoshop-image", kind: .image, symbol: "photo"),
        // Belge
        Format(id: "pdf", label: "PDF", extensions: ["pdf"], typeIdentifier: "com.adobe.pdf", kind: .pdf, symbol: "doc.richtext"),
        Format(id: "docx", label: "Word", extensions: ["docx"], typeIdentifier: "org.openxmlformats.wordprocessingml.document", kind: .document, symbol: "doc.text"),
        Format(id: "doc", label: "DOC", extensions: ["doc"], typeIdentifier: "com.microsoft.word.doc", kind: .document, symbol: "doc.text"),
        Format(id: "rtf", label: "RTF", extensions: ["rtf"], typeIdentifier: "public.rtf", kind: .document, symbol: "doc.text"),
        Format(id: "odt", label: "ODT", extensions: ["odt"], typeIdentifier: "org.oasis-open.opendocument.text", kind: .document, symbol: "doc.text"),
        Format(id: "txt", label: "TXT", extensions: ["txt", "text"], typeIdentifier: "public.plain-text", kind: .document, symbol: "text.alignleft"),
        Format(id: "html", label: "HTML", extensions: ["html", "htm"], typeIdentifier: "public.html", kind: .document, symbol: "chevron.left.forwardslash.chevron.right"),
        Format(id: "pptx", label: "PowerPoint", extensions: ["pptx"], typeIdentifier: "org.openxmlformats.presentationml.presentation", kind: .presentation, symbol: "rectangle.on.rectangle"),
        Format(id: "ppt", label: "PPT", extensions: ["ppt"], typeIdentifier: "com.microsoft.powerpoint.ppt", kind: .presentation, symbol: "rectangle.on.rectangle"),
        Format(id: "xlsx", label: "Excel", extensions: ["xlsx"], typeIdentifier: "org.openxmlformats.spreadsheetml.sheet", kind: .spreadsheet, symbol: "tablecells"),
        Format(id: "xls", label: "XLS", extensions: ["xls"], typeIdentifier: "com.microsoft.excel.xls", kind: .spreadsheet, symbol: "tablecells"),
        Format(id: "csv", label: "CSV", extensions: ["csv"], typeIdentifier: "public.comma-separated-values-text", kind: .spreadsheet, symbol: "tablecells"),
        // Video
        Format(id: "mp4", label: "MP4", extensions: ["mp4"], typeIdentifier: "public.mpeg-4", kind: .movie, symbol: "film"),
        Format(id: "mov", label: "MOV", extensions: ["mov", "qt"], typeIdentifier: "com.apple.quicktime-movie", kind: .movie, symbol: "film"),
        Format(id: "mkv", label: "MKV", extensions: ["mkv"], typeIdentifier: "org.matroska.mkv", kind: .movie, symbol: "film"),
        Format(id: "webm", label: "WebM", extensions: ["webm"], typeIdentifier: "org.webmproject.webm", kind: .movie, symbol: "film"),
        Format(id: "m4v", label: "M4V", extensions: ["m4v"], typeIdentifier: "com.apple.m4v-video", kind: .movie, symbol: "film"),
        Format(id: "avi", label: "AVI", extensions: ["avi"], typeIdentifier: "public.avi", kind: .movie, symbol: "film"),
        // Ses
        Format(id: "mp3", label: "MP3", extensions: ["mp3"], typeIdentifier: "public.mp3", kind: .audio, symbol: "waveform"),
        Format(id: "m4a", label: "M4A", extensions: ["m4a"], typeIdentifier: "com.apple.m4a-audio", kind: .audio, symbol: "waveform"),
        Format(id: "wav", label: "WAV", extensions: ["wav"], typeIdentifier: "com.microsoft.waveform-audio", kind: .audio, symbol: "waveform"),
        Format(id: "flac", label: "FLAC", extensions: ["flac"], typeIdentifier: "org.xiph.flac", kind: .audio, symbol: "waveform"),
        Format(id: "opus", label: "Opus", extensions: ["opus"], typeIdentifier: "org.xiph.opus", kind: .audio, symbol: "waveform"),
        Format(id: "aiff", label: "AIFF", extensions: ["aiff", "aif"], typeIdentifier: "public.aiff-audio", kind: .audio, symbol: "waveform"),
        Format(id: "aac", label: "AAC", extensions: ["aac"], typeIdentifier: "public.aac-audio", kind: .audio, symbol: "waveform"),
        Format(id: "ogg", label: "OGG", extensions: ["ogg", "oga"], typeIdentifier: "org.xiph.ogg-audio", kind: .audio, symbol: "waveform"),
    ]

    /// PDF sayfalarının dönüştürülebildiği görüntü formatları.
    static let pdfPageTargets = ["png", "jpg", "tiff", "heic"]
    /// Videonun dönüştürülebildiği formatlar, gösterim sırasıyla. Ses hedefleri "sesi al" demek.
    static let movieTargets = ["mp4", "mov", "mkv", "webm", "gif", "m4a", "mp3", "wav"]
    static let audioTargets = ["mp3", "m4a", "wav", "flac", "opus", "aiff"]
    /// `textutil`'in birbirine dönüştürebildiği metin belgeleri.
    static let textutilFormats = ["docx", "doc", "rtf", "odt", "txt", "html"]
    static let documentTargets = ["pdf", "docx", "doc", "rtf", "odt", "txt", "html"]
    static let presentationTargets = ["pdf", "pptx", "ppt"]
    static let spreadsheetTargets = ["pdf", "xlsx", "xls", "csv"]

    public func format(id: String) -> Format? {
        formats.first { $0.id == id }
    }

    /// Dosyanın formatı; uzantıdan, bulunamazsa UTType uyumluluğundan.
    public func format(for url: URL) -> Format? {
        let ext = url.pathExtension.lowercased()
        if let match = formats.first(where: { $0.extensions.contains(ext) }) { return match }
        guard let type = UTType(filenameExtension: ext) else { return nil }
        // Sistemde tanımlı olmayan tür adları (ör. bazı sürümlerde Opus) eşleşmeye katılmaz; yoksa her şey
        // `public.data`'ya uyduğu için bilinmeyen dosyalar o formata düşerdi.
        return formats.first { format in
            guard let known = UTType(format.typeIdentifier) else { return false }
            return type.conforms(to: known)
        }
    }

    public func canRead(_ format: Format) -> Bool {
        switch format.kind {
        case .pdf: true
        case .image: readable.contains(format.typeIdentifier)
        case .movie, .audio: ffmpeg != nil
        case .document: Self.textutilFormats.contains(format.id)
        case .presentation: office.powerpoint
        case .spreadsheet: office.excel
        case .other: false
        }
    }

    /// ImageIO bu formatı kendisi yazabiliyor mu (yoksa ffmpeg gerekir).
    func imageIOWrites(_ format: Format) -> Bool {
        format.kind == .image && writable.contains(format.typeIdentifier)
    }

    public func canWrite(_ format: Format) -> Bool {
        if format.kind == .pdf || imageIOWrites(format) { return true }
        guard let ffmpeg else { return false }
        return FFmpegArguments.requiredEncoders(for: format.id).allSatisfy { group in
            group.contains { ffmpeg.encoders.contains($0) }
        }
    }

    /// Bir formatın dönüştürülebildiği hedefler, gösterim sırasıyla.
    public func targets(from source: Format) -> [Format] {
        guard canRead(source) else { return [] }
        let ids: [String] = switch source.kind {
        case .image: formats.filter { $0.kind == .image || $0.kind == .pdf }.map(\.id)
        case .pdf: Self.pdfPageTargets + ["docx", "txt"]
        case .movie: Self.movieTargets
        case .audio: Self.audioTargets
        case .document: Self.documentTargets
        case .presentation: Self.presentationTargets
        case .spreadsheet: Self.spreadsheetTargets
        case .other: []
        }
        return ids.filter { $0 != source.id }.compactMap(format(id:)).filter { canConvert(source, to: $0) }
    }

    /// Kaynaktan hedefe giden yolun bu Mac'te olup olmadığı.
    func canConvert(_ source: Format, to target: Format) -> Bool {
        switch (source.kind, target.kind) {
        case (.pdf, .document):
            // Metin her zaman (PDFKit); Word belgesi için Word gerekir.
            return target.id == "txt" || (target.id == "docx" && office.word)
        case (.document, .pdf):
            return office.word
        case (.document, .document):
            return Self.textutilFormats.contains(target.id)
        case (.presentation, _):
            return office.powerpoint
        case (.spreadsheet, _):
            return office.excel
        default:
            return canWrite(target)
        }
    }

    /// Bu dönüşümü Office uygulamalarından biri mi yapıyor.
    func officeApp(for source: Format, to target: Format) -> OfficeApps.App? {
        switch (source.kind, target.kind) {
        case (.pdf, .document) where target.id == "docx": .word
        case (.document, .pdf): .word
        case (.presentation, _): .powerpoint
        case (.spreadsheet, _): .excel
        default: nil
        }
    }

    /// Birden çok dosya için ortak hedefler. Formatı bilinmeyen bir dosya varsa boş.
    ///
    /// Karışık seçimde (ör. JPG + PNG) bir dosyanın kendi formatı da hedef olabilir: "hepsi PNG olsun".
    /// O durumda zaten PNG olan dosyalar dönüştürmede atlanır. Bütün dosyalar aynı formattaysa o format hedef değil.
    /// Sıra ilk dosyanın hedef sırası, ardından diğerlerinden gelenler.
    public func commonTargets(for files: [URL]) -> [Format] {
        var sources: [Format] = []
        for file in files {
            guard let source = format(for: file) else { return [] }
            sources.append(source)
        }
        guard let first = sources.first else { return [] }
        let candidates = targets(from: first) + [first] + sources.flatMap { targets(from: $0) }
        var seen: Set<String> = []
        return candidates.filter { target in
            guard seen.insert(target.id).inserted else { return false }
            return sources.contains { $0.id != target.id } && sources.allSatisfy { source in
                source.id == target.id || targets(from: source).contains(target)
            }
        }
    }
}
