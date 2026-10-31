import Foundation

/// Araç isteklerini çalıştırır. Çıktı adı kaynağın adı + ne yapıldığı: `foto - kırpılmış.jpg`.
public enum ToolRunner {
    static func suffix(_ tool: ToolID) -> String {
        switch tool {
        case .compress: L("compressed", "sıkıştırılmış")
        case .resize: L("resized", "yeniden boyutlandırılmış")
        case .crop: L("cropped", "kırpılmış")
        case .rotate: L("rotated", "döndürülmüş")
        case .flip: L("flipped", "çevrilmiş")
        case .strip: L("clean", "bilgisiz")
        case .trim: L("trimmed", "kesilmiş")
        case .normalize: L("normalized", "normalize")
        case .removeAudio: L("muted", "sessiz")
        case .extractPages: L("pages", "seçilen sayfalar")
        case .removeBackground: L("no background", "arka plansız")
        case .extractText: L("text", "metin")
        case .frame: L("frame", "kare")
        case .protect: L("protected", "parolalı")
        case .unprotect: L("unlocked", "parolasız")
        case .split, .merge, .extractAudio: ""
        }
    }

    /// Panel için: medya süresi (saniye), okunamazsa `nil`.
    public static func duration(of file: URL, registry: FormatRegistry = .shared) async -> Double? {
        guard let toolkit = registry.ffmpeg else { return nil }
        return try? await MediaInfo.probe(file, with: toolkit).duration
    }

    /// Panel için: PDF sayfa sayısı.
    public static func pageCount(of file: URL) -> Int? {
        try? PDFTools.pageCount(file)
    }

    public static func run(_ request: ToolRequest, registry: FormatRegistry = .shared, outputDirectory: URL? = nil,
                           progress: (@Sendable (Double) -> Void)? = nil) async -> [ConversionOutcome] {
        let files = request.files
        func directory(for file: URL) -> URL? { outputDirectory ?? OutputLocation.directory(for: file) }

        // Birden çok dosyadan tek çıktı.
        if request.tool == .merge {
            let ordered = if case .merge(let order) = request.options { order } else { files }
            let result = await outcome(ordered) {
                try await merge(ordered, registry: registry, in: files.first.flatMap(directory), progress: progress)
            }
            progress?(1)
            return [result]
        }

        // Ses çıkarma bir dönüşüm: kaynak AAC ise kopya.
        if request.tool == .extractAudio, let m4a = registry.format(id: "m4a") {
            return await Converter.run(.convert(files, to: m4a), registry: registry, outputDirectory: outputDirectory,
                                       progress: progress)
        }

        var results: [ConversionOutcome] = []
        for (index, file) in files.enumerated() {
            if Task.isCancelled {
                results.append(ConversionOutcome(sources: [file], result: .cancelled))
                continue
            }
            let share: @Sendable (Double) -> Void = { fraction in
                progress?((Double(index) + fraction) / Double(files.count))
            }
            results.append(await outcome([file]) {
                try await apply(request.tool, options: request.options, to: file, registry: registry,
                                in: directory(for: file), progress: share)
            })
        }
        progress?(1)
        return results
    }

    static func apply(_ tool: ToolID, options: ToolOptions, to file: URL, registry: FormatRegistry,
                      in directory: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard let source = registry.format(for: file) else { throw ConversionError.unreadable(file) }
        let stem = file.deletingPathExtension().lastPathComponent
        let named = "\(stem) - \(suffix(tool))"

        switch source.kind {
        case .image:
            if tool == .removeBackground {
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "png", in: directory) {
                    try VisionTools.removeBackground(file, to: $0, registry: registry)
                }]
            }
            if tool == .extractText {
                let text = try VisionTools.recognizeText(in: file)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ConversionError.failed(L("No readable text found in “\(file.lastPathComponent)”.", "“\(file.lastPathComponent)” içinde okunabilir metin bulunamadı."))
                }
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "txt", in: directory) {
                    try text.write(to: $0, atomically: true, encoding: .utf8)
                }]
            }
            if tool == .strip {
                let format = registry.imageIOWrites(source) ? source : registry.format(id: "png")!
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: format.pathExtension, in: directory) {
                    try ImageTools.stripMetadata(file, to: $0, format: format)
                }]
            }
            let result = try ImageTools.process(file, options: options, registry: registry)
            return [try AtomicOutput.write(beside: file, stem: named, pathExtension: result.format.pathExtension,
                                           in: directory) {
                try ImageTools.write(result, from: file, to: $0)
            }]

        case .pdf:
            switch (tool, options) {
            case (.compress, _):
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "pdf", in: directory) {
                    try PDFTools.compress(file, to: $0)
                }]
            case (.rotate, .rotate(let degrees)):
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "pdf", in: directory) {
                    try PDFTools.rotate(file, degrees: degrees, to: $0)
                }]
            case (.extractText, _):
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "txt", in: directory) {
                    try DocumentEngine.extractText(file, to: $0)
                }]
            case (.protect, .password(let password)):
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "pdf", in: directory) {
                    try PDFTools.protect(file, password: password, to: $0)
                }]
            case (.unprotect, .password(let password)):
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "pdf", in: directory) {
                    try PDFTools.unprotect(file, password: password, to: $0)
                }]
            case (.extractPages, .pages(let text)):
                let count = try PDFTools.pageCount(file)
                guard let pages = PageRange.parse(text, pageCount: count) else {
                    throw ConversionError.failed(L("“\(text)” is not a valid page range (the document has \(count) pages).", "“\(text)” geçerli bir sayfa aralığı değil (belge \(count) sayfa)."))
                }
                return [try AtomicOutput.write(beside: file, stem: named, pathExtension: "pdf", in: directory) {
                    try PDFTools.extract(file, pages: pages, to: $0)
                }]
            case (.split, _):
                let count = try PDFTools.pageCount(file)
                return try (0..<count).map { index in
                    try Task.checkCancellation()
                    defer { progress(Double(index + 1) / Double(count)) }
                    return try AtomicOutput.write(beside: file, stem: "\(stem) - sayfa \(index + 1)",
                                                  pathExtension: "pdf", in: directory) {
                        try PDFTools.extract(file, pages: [index], to: $0)
                    }
                }
            default:
                throw ConversionError.failed(L("This tool does not work on PDFs.", "Bu araç PDF'lere uygulanamıyor."))
            }

        case .movie, .audio:
            guard let toolkit = registry.ffmpeg else { throw ConversionError.unsupported(file, ToolCatalog.tool(tool).label) }
            let media = try await MediaInfo.probe(file, with: toolkit)
            if tool == .split {
                return try await split(file, options: options, media: media, source: source, toolkit: toolkit,
                                       in: directory, progress: progress)
            }
            let output = tool == .frame ? registry.format(id: "png")! : MediaTools.outputFormat(for: source, registry: registry)
            var duration = media.duration
            if case .trim(let start, let end) = options {
                guard end > start else { throw ConversionError.failed(L("The end must come after the start.", "Bitiş başlangıçtan sonra olmalı.")) }
                duration = end - start
            }
            return [try await AtomicOutput.write(beside: file, stem: named, pathExtension: output.pathExtension,
                                                 in: directory) { destination in
                guard let args = MediaTools.arguments(tool: tool, options: options, input: file, output: destination,
                                                      source: source, outputFormat: output, encoders: toolkit.encoders)
                else { throw ConversionError.failed(L("This tool does not work on this file.", "Bu araç bu dosyaya uygulanamıyor.")) }
                try await runFFmpeg(args, toolkit: toolkit, duration: duration, file: file, progress: progress)
            }]

        case .document, .presentation, .spreadsheet, .other:
            throw ConversionError.unreadable(file)
        }
    }

    static func split(_ file: URL, options: ToolOptions, media: MediaInfo, source: Format, toolkit: FFmpegToolkit,
                      in directory: URL?, progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        guard let duration = media.duration, duration > 0 else {
            throw ConversionError.failed(L("Could not read the duration of “\(file.lastPathComponent)”.", "“\(file.lastPathComponent)” süresi okunamadı."))
        }
        let segment: Double = switch options {
        case .split(.parts(let parts)): duration / Double(max(parts, 2))
        case .split(.every(let seconds)): seconds
        default: duration / 2
        }
        let scratch = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: directory ?? file.deletingLastPathComponent(),
                                                  create: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ext = source.pathExtension
        let pattern = scratch.appendingPathComponent("parca%03d.\(ext)")
        try await runFFmpeg(MediaTools.splitArguments(input: file, pattern: pattern, segmentSeconds: segment),
                            toolkit: toolkit, duration: duration, file: file, progress: progress)
        let parts = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("parca") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let stem = file.deletingPathExtension().lastPathComponent
        return try parts.enumerated().map { index, part in
            try AtomicOutput.write(beside: file, stem: L("\(stem) - part \(index + 1)", "\(stem) - parça \(index + 1)"), pathExtension: ext, in: directory) {
                try FileManager.default.moveItem(at: part, to: $0)
            }
        }
    }

    static func merge(_ files: [URL], registry: FormatRegistry, in directory: URL?,
                      progress: (@Sendable (Double) -> Void)?) async throws -> [URL] {
        guard let first = files.first, let source = registry.format(for: first) else {
            throw ConversionError.failed(L("Nothing to merge.", "Birleştirilecek dosya yok."))
        }
        switch source.kind {
        case .image:
            return [try Converter.combine(files, in: directory)]
        case .pdf:
            return [try AtomicOutput.write(beside: first, stem: L("Merged", "Birleştirilmiş"), pathExtension: "pdf", in: directory) {
                try PDFTools.merge(files, to: $0)
            }]
        case .movie, .audio:
            guard let toolkit = registry.ffmpeg else { throw ConversionError.unsupported(first, L("merging", "birleştirme")) }
            let output = MediaTools.outputFormat(for: source, registry: registry)
            var total = 0.0
            for file in files { total += try await MediaInfo.probe(file, with: toolkit).duration ?? 0 }
            let duration = total
            return [try await AtomicOutput.write(beside: first, stem: L("Merged", "Birleştirilmiş"), pathExtension: output.pathExtension,
                                                 in: directory) { destination in
                let list = destination.deletingLastPathComponent().appendingPathComponent("liste.txt")
                try files.map(MediaTools.concatLine).joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
                let report: @Sendable (Double) -> Void = { progress?($0) }
                do {
                    try await runFFmpeg(MediaTools.mergeArguments(list: list, output: destination, outputFormat: output,
                                                                  reencode: false, isVideo: source.kind == .movie,
                                                                  encoders: toolkit.encoders),
                                        toolkit: toolkit, duration: duration, file: first, progress: report)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Farklı kodlayıcı/boyuttaki dosyalar kopyalanarak birleşmez; yeniden kodla.
                    Log.conversion.info("Birleştirmede akış kopyası olmadı, yeniden kodlanıyor")
                    try await runFFmpeg(MediaTools.mergeArguments(list: list, output: destination, outputFormat: output,
                                                                  reencode: true, isVideo: source.kind == .movie,
                                                                  encoders: toolkit.encoders),
                                        toolkit: toolkit, duration: duration, file: first, progress: report)
                }
            }]
        case .document, .presentation, .spreadsheet, .other:
            throw ConversionError.unreadable(first)
        }
    }

    static func runFFmpeg(_ args: [String], toolkit: FFmpegToolkit, duration: Double?, file: URL,
                          progress: @escaping @Sendable (Double) -> Void) async throws {
        let tracker = FFmpegProgress(duration: duration, report: progress)
        Log.conversion.debug("ffmpeg \(args.joined(separator: " "), privacy: .public)")
        let output = try await ProcessRunner.run(toolkit.ffmpeg, args) { tracker.consume($0) }
        guard output.status == 0 else {
            throw ConversionError.failed(FFmpegArguments.explain(output.stderr, file: file))
        }
    }

    private static func outcome(_ sources: [URL], _ work: () async throws -> [URL]) async -> ConversionOutcome {
        do {
            let outputs = try await work()
            Log.conversion.info("Araç: \(sources.map(\.lastPathComponent), privacy: .public) → \(outputs.map(\.lastPathComponent), privacy: .public)")
            return ConversionOutcome(sources: sources, result: .written(outputs))
        } catch is CancellationError {
            return ConversionOutcome(sources: sources, result: .cancelled)
        } catch {
            Log.conversion.error("Araç: \(sources.map(\.lastPathComponent), privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ConversionOutcome(sources: sources, result: .failed(error.localizedDescription))
        }
    }
}
