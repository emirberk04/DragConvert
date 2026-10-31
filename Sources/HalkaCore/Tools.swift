import Foundation

/// ⌥ halkasındaki araçlar.
public enum ToolID: String, Sendable, CaseIterable {
    case compress, resize, crop, rotate, flip, strip
    case trim, split, merge, normalize
    case extractAudio = "extract-audio"
    case removeAudio = "remove-audio"
    case extractPages = "extract-pages"
    case removeBackground = "remove-background"
    case extractText = "extract-text"
    case frame
    case protect, unprotect
}

public struct Tool: Sendable, Equatable, Identifiable {
    public let id: ToolID
    public let label: String
    public let symbol: String
    /// Çalışmadan önce bir ayar paneli açılır mı.
    public let needsOptions: Bool
}

/// Araçların ayarları. Panel üretir, `ToolRunner` tüketir.
public enum ToolOptions: Sendable, Equatable {
    case none
    case compress(CompressLevel)
    case resize(ResizeMode)
    /// Kırpılacak bölge, görüntüye oranla (0...1, sol üst köşe başlangıç). Panelde çerçeveyle seçilir.
    case crop(CropRect)
    /// Saat yönünde derece: 90, 180, 270.
    case rotate(Int)
    case flip(horizontal: Bool)
    /// Saniye.
    case trim(start: Double, end: Double)
    case split(SplitMode)
    /// Birleştirme sırası.
    case merge([URL])
    /// "1-3, 5" gibi; 1'den başlar.
    case pages(String)
    /// Videodan alınacak karenin saniyesi.
    case frame(at: Double)
    case password(String)
}

public struct CropRect: Sendable, Equatable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Belirli bir oranda, ortalanmış en büyük bölge.
    public static func centred(aspect: Double, imageAspect: Double) -> CropRect {
        if imageAspect > aspect {
            let width = aspect / imageAspect
            return CropRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = imageAspect / aspect
        return CropRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }

    public var isWhole: Bool { width >= 0.999 && height >= 0.999 }
}

public enum CompressLevel: String, Sendable, CaseIterable {
    case light, medium, strong

    public var label: String {
        switch self {
        case .light: L("Light", "Hafif")
        case .medium: L("Medium", "Orta")
        case .strong: L("Strong", "Güçlü")
        }
    }
}

public enum ResizeMode: Sendable, Equatable {
    case percent(Int)
    /// Uzun kenar piksel; küçük görüntüler büyütülmez.
    case longEdge(Int)
}

public enum SplitMode: Sendable, Equatable {
    case parts(Int)
    case every(seconds: Double)
}

public struct ToolRequest: Sendable, Equatable {
    public let tool: ToolID
    public let files: [URL]
    public let options: ToolOptions

    public init(tool: ToolID, files: [URL], options: ToolOptions) {
        self.tool = tool
        self.files = files
        self.options = options
    }
}

/// Hangi dosyaya hangi araçlar uygulanabilir.
public enum ToolCatalog {
    static let all: [ToolID: Tool] = Dictionary(uniqueKeysWithValues: [
        Tool(id: .compress, label: L("Compress", "Sıkıştır"), symbol: "arrow.down.right.and.arrow.up.left", needsOptions: true),
        Tool(id: .resize, label: L("Resize", "Boyut"), symbol: "arrow.up.left.and.arrow.down.right", needsOptions: true),
        Tool(id: .crop, label: L("Crop", "Kırp"), symbol: "crop", needsOptions: true),
        Tool(id: .rotate, label: L("Rotate", "Döndür"), symbol: "rotate.right", needsOptions: true),
        Tool(id: .flip, label: L("Flip", "Çevir"), symbol: "flip.horizontal", needsOptions: true),
        Tool(id: .strip, label: L("Strip metadata", "Bilgileri sil"), symbol: "eye.slash", needsOptions: false),
        Tool(id: .trim, label: L("Trim", "Kes"), symbol: "scissors", needsOptions: true),
        Tool(id: .split, label: L("Split", "Böl"), symbol: "square.split.2x1", needsOptions: true),
        Tool(id: .merge, label: L("Merge", "Birleştir"), symbol: "square.stack", needsOptions: true),
        Tool(id: .normalize, label: L("Normalize", "Ses seviyesi"), symbol: "speaker.wave.2", needsOptions: false),
        Tool(id: .extractAudio, label: L("Extract audio", "Sesi çıkar"), symbol: "waveform", needsOptions: false),
        Tool(id: .removeAudio, label: L("Remove audio", "Sesi kaldır"), symbol: "speaker.slash", needsOptions: false),
        Tool(id: .extractPages, label: L("Extract pages", "Sayfa çıkar"), symbol: "doc.on.doc", needsOptions: true),
        Tool(id: .removeBackground, label: L("Remove background", "Arka planı sil"), symbol: "person.crop.rectangle", needsOptions: false),
        Tool(id: .extractText, label: L("Extract text", "Metni çıkar"), symbol: "text.viewfinder", needsOptions: false),
        Tool(id: .frame, label: L("Grab frame", "Kare al"), symbol: "camera.viewfinder", needsOptions: true),
        Tool(id: .protect, label: L("Add password", "Parola koy"), symbol: "lock", needsOptions: true),
        Tool(id: .unprotect, label: L("Remove password", "Parolayı kaldır"), symbol: "lock.open", needsOptions: true),
    ].map { ($0.id, $0) })

    /// Türe göre araçlar, halkadaki sırasıyla.
    static func tools(for kind: FileKind) -> [ToolID] {
        switch kind {
        case .image: [.compress, .resize, .crop, .rotate, .flip, .removeBackground, .extractText, .strip, .merge]
        case .movie: [.compress, .trim, .crop, .rotate, .frame, .split, .merge, .extractAudio, .removeAudio]
        case .audio: [.compress, .trim, .normalize, .split, .merge]
        case .pdf: [.compress, .extractPages, .extractText, .split, .rotate, .protect, .unprotect, .merge]
        case .document, .presentation, .spreadsheet, .other: []
        }
    }

    /// Tek dosya isteyen araçlar (aralık veya süre o dosyaya özgü).
    static let singleOnly: Set<ToolID> = [.trim, .split, .extractPages, .frame, .crop]

    public static func tools(for files: [URL], registry: FormatRegistry = .shared) -> [Tool] {
        var kinds: [FileKind] = []
        for file in files {
            guard let format = registry.format(for: file), registry.canRead(format) else { return [] }
            kinds.append(format.kind)
        }
        guard let first = kinds.first else { return [] }
        var ids = tools(for: first)
        for kind in kinds.dropFirst() {
            let other = Set(tools(for: kind))
            ids.removeAll { !other.contains($0) }
        }
        // Birleştirme aynı türden en az iki dosya ister; görüntülerin birleşimi PDF (⇧ halkasında da var).
        if files.count < 2 || Set(kinds).count > 1 { ids.removeAll { $0 == .merge } }
        if files.count > 1 { ids.removeAll { singleOnly.contains($0) } }
        if (first == .movie || first == .audio) && registry.ffmpeg == nil { return [] }
        return ids.compactMap { all[$0] }
    }

    public static func tool(_ id: ToolID) -> Tool { all[id]! }
}

/// Sayfa aralığı ayrıştırma: "1-3, 5, 8-" → [0, 1, 2, 4, 7, 8, ...] (sıfırdan, sırayla, tekrarsız).
public enum PageRange {
    public static func parse(_ text: String, pageCount: Int) -> [Int]? {
        var pages: [Int] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }) where !part.isEmpty {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard bounds.count <= 2 else { return nil }
            guard let start = bounds[0].isEmpty ? 1 : Int(bounds[0]) else { return nil }
            let end: Int
            if bounds.count == 2 {
                guard let value = bounds[1].isEmpty ? pageCount : Int(bounds[1]) else { return nil }
                end = value
            } else {
                end = start
            }
            guard start >= 1, end >= start, end <= pageCount else { return nil }
            for page in start...end where !pages.contains(page - 1) { pages.append(page - 1) }
        }
        return pages.isEmpty ? nil : pages
    }
}
