import Foundation

/// Halkada seçilen iş.
public enum ConversionRequest: Sendable, Equatable {
    /// Her dosya ayrı ayrı hedef formata.
    case convert([URL], to: Format)
    /// Görüntüler sırasıyla tek bir PDF'te, her biri bir sayfa.
    case combineIntoPDF([URL])
}

/// Bir kaynağın (veya birleştirmede bütün kaynakların) sonucu.
public struct ConversionOutcome: Sendable {
    public enum Result: Sendable {
        case written([URL])
        /// Dosya zaten hedef formatta (karışık seçimde).
        case skipped
        case cancelled
        case failed(String)
    }

    public let sources: [URL]
    public let result: Result

    public init(sources: [URL], result: Result) {
        self.sources = sources
        self.result = result
    }

    public var outputs: [URL] {
        if case .written(let urls) = result { return urls }
        return []
    }
}

/// İstekleri motorlara dağıtır. Dosyalar paralel işlenir; iptal edilince süren ffmpeg sonlandırılır ve
/// bekleyen dosyalara başlanmaz. Yarım kalan çıktı geçici klasörde kalır ve silinir.
public enum Converter {
    /// - Parameters:
    ///   - outputDirectory: Çıktı klasörü; `nil` ise her dosyanın yanı (paket içindeyse İndirilenler,
    ///     bkz. `OutputLocation`).
    ///   - progress: Bütün işin 0...1 oranı. Herhangi bir kuyruktan çağrılır.
    public static func run(_ request: ConversionRequest, registry: FormatRegistry = .shared,
                           outputDirectory: URL? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async -> [ConversionOutcome] {
        switch request {
        case .combineIntoPDF(let files):
            let directory = outputDirectory ?? files.first.flatMap { OutputLocation.directory(for: $0) }
            let result = await outcome(files) { try [combine(files, in: directory)] }
            progress?(1)
            return [result]

        case .convert(let files, let target):
            let tracker = ProgressTracker(count: files.count, report: progress)
            let limit = parallelism(for: files, target: target, registry: registry)
            return await withTaskGroup(of: (Int, ConversionOutcome).self) { group in
                var results = [ConversionOutcome?](repeating: nil, count: files.count)
                var next = 0
                func enqueue() {
                    guard next < files.count, !Task.isCancelled else { return }
                    let index = next, file = files[index]
                    next += 1
                    group.addTask {
                        let directory = outputDirectory ?? OutputLocation.directory(for: file)
                        let result = await convert(file, to: target, registry: registry, in: directory) {
                            tracker.update(index, $0)
                        }
                        tracker.update(index, 1)
                        return (index, result)
                    }
                }
                for _ in 0..<min(limit, files.count) { enqueue() }
                for await (index, result) in group {
                    results[index] = result
                    enqueue()
                }
                // Hiç başlamamış dosyalar da sonuçta görünsün.
                return results.enumerated().map { index, result in
                    result ?? ConversionOutcome(sources: [files[index]], result: .cancelled)
                }
            }
        }
    }

    /// Video tek tek (donanım kodlayıcı ve disk zaten dolu), ses ikişer, görüntüler çekirdek sayısının yarısı.
    static func parallelism(for files: [URL], target: Format, registry: FormatRegistry) -> Int {
        let kinds = Set(files.compactMap { registry.format(for: $0)?.kind } + [target.kind])
        // Office uygulaması bir seferde bir belge açıp kaydeder.
        if kinds.contains(.movie) || !kinds.isDisjoint(with: [.document, .presentation, .spreadsheet]) { return 1 }
        if kinds.contains(.audio) { return 2 }
        return max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    }

    static func convert(_ file: URL, to target: Format, registry: FormatRegistry, in directory: URL? = nil,
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> ConversionOutcome {
        guard let source = registry.format(for: file) else {
            return ConversionOutcome(sources: [file], result: .failed(ConversionError.unreadable(file).localizedDescription))
        }
        if source.id == target.id { return ConversionOutcome(sources: [file], result: .skipped) }

        return await outcome([file]) {
            if let app = registry.officeApp(for: source, to: target) {
                return [try await AtomicOutput.write(beside: file, pathExtension: target.pathExtension, in: directory) {
                    try await OfficeEngine.convert(file, to: target, app: app, writingTo: $0)
                }]
            }
            if source.kind == .document {
                return [try await AtomicOutput.write(beside: file, pathExtension: target.pathExtension, in: directory) {
                    try await DocumentEngine.convert(file, to: target, writingTo: $0)
                }]
            }
            if source.kind == .pdf && target.id == "txt" {
                return [try AtomicOutput.write(beside: file, pathExtension: "txt", in: directory) {
                    try DocumentEngine.extractText(file, to: $0)
                }]
            }
            if source.kind == .movie || source.kind == .audio || !registry.imageIOWrites(target) && target.kind == .image {
                guard let toolkit = registry.ffmpeg else {
                    throw ConversionError.unsupported(file, target.label)
                }
                return [try await AtomicOutput.write(beside: file, pathExtension: target.pathExtension, in: directory) { output in
                    if source.kind == .image {
                        // ffmpeg EXIF yönünü uygulamaz; önce ImageIO ile yönü düzeltilmiş bir PNG ara dosya.
                        let oriented = output.deletingLastPathComponent().appendingPathComponent("ara.png")
                        try ImageEngine.convert(file, to: registry.format(id: "png")!, writingTo: oriented)
                        try await FFmpegEngine.convert(oriented, to: target, writingTo: output, toolkit: toolkit,
                                                       progress: progress)
                    } else {
                        try await FFmpegEngine.convert(file, to: target, writingTo: output, toolkit: toolkit,
                                                       progress: progress)
                    }
                }]
            }
            if source.kind == .pdf {
                let pages = try PDFEngine.pageCount(file)
                let stem = file.deletingPathExtension().lastPathComponent
                return try (0..<pages).map { index in
                    try Task.checkCancellation()
                    let image = try PDFEngine.renderPage(file, index: index)
                    defer { progress(Double(index + 1) / Double(pages)) }
                    return try AtomicOutput.write(beside: file,
                                                  stem: pages == 1 ? nil : L("\(stem) - page \(index + 1)", "\(stem) - sayfa \(index + 1)"),
                                                  pathExtension: target.pathExtension, in: directory) {
                        try ImageEngine.write(image, as: target, to: $0)
                    }
                }
            }
            if target.kind == .pdf {
                return [try AtomicOutput.write(beside: file, pathExtension: target.pathExtension, in: directory) {
                    try PDFEngine.writePDF(images: [file], to: $0)
                }]
            }
            return [try AtomicOutput.write(beside: file, pathExtension: target.pathExtension, in: directory) {
                try ImageEngine.convert(file, to: target, writingTo: $0)
            }]
        }
    }

    /// Tek PDF, ilk dosyanın klasöründe "Birleştirilmiş.pdf" (doluysa numaralı).
    static func combine(_ files: [URL], in directory: URL? = nil) throws -> URL {
        guard let first = files.first else { throw ConversionError.failed(L("No files.", "Dosya yok.")) }
        return try AtomicOutput.write(beside: first, stem: L("Merged", "Birleştirilmiş"), pathExtension: "pdf", in: directory) {
            try PDFEngine.writePDF(images: files, to: $0)
        }
    }

    private static func outcome(_ sources: [URL], _ work: () async throws -> [URL]) async -> ConversionOutcome {
        do {
            let outputs = try await work()
            Log.conversion.info("\(sources.map(\.lastPathComponent), privacy: .public) → \(outputs.map(\.lastPathComponent), privacy: .public)")
            return ConversionOutcome(sources: sources, result: .written(outputs))
        } catch is CancellationError {
            Log.conversion.info("İptal edildi: \(sources.map(\.lastPathComponent), privacy: .public)")
            return ConversionOutcome(sources: sources, result: .cancelled)
        } catch {
            Log.conversion.error("\(sources.map(\.lastPathComponent), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ConversionOutcome(sources: sources, result: .failed(error.localizedDescription))
        }
    }
}

/// Dosya başına ilerlemeleri tek orana çevirir.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [Double]
    private let report: (@Sendable (Double) -> Void)?

    init(count: Int, report: (@Sendable (Double) -> Void)?) {
        fractions = Array(repeating: 0, count: count)
        self.report = report
    }

    func update(_ index: Int, _ fraction: Double) {
        guard let report else { return }
        let total: Double = lock.withLock {
            fractions[index] = max(fractions[index], fraction)
            return fractions.reduce(0, +) / Double(max(fractions.count, 1))
        }
        report(total)
    }
}
