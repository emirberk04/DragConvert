import AppKit
import DragConvertCore
import DragConvertDrag
import DragConvertUI
import UserNotifications

/// Sürükleme izleyicisini, tetik durum makinesini ve halka panelini birbirine bağlar; seçilen işi çalıştırır.
@MainActor
final class DragCoordinator {
    /// Süren işlerin toplam ilerlemesi (0...1), iş yoksa `nil`; menü çubuğu için.
    var onProgress: ((Double?) -> Void)?
    /// Üretilen dosyalar (son dönüşümler için).
    var onConverted: (([URL]) -> Void)?

    private let monitor = DragMonitor()
    private let ring = RingPanelController()
    private let registry = FormatRegistry.shared
    private var machine = TriggerMachine()
    private var files: [URL] = []
    /// Her sürüklemede artar; gecikmeli kapatma yeni bir sürüklemenin halkasını kapatmasın diye.
    private var generation = 0
    /// Süren işler ve her birinin ilerlemesi; iptal ve toplam ilerleme için.
    private var jobs: [UUID: (task: Task<Void, Never>, fraction: Double)] = [:]

    init() {
        monitor.onDragBegan = { [weak self] files, modifiers in
            guard let self else { return }
            generation += 1
            self.files = files
            // Ayarlar penceresinde değişen tuşlar bir sonraki sürüklemede geçerli.
            machine.bindings = TriggerMachine.bindingsFromPreferences()
            apply(machine.dragBegan(modifiers: modifiers))
        }
        monitor.onModifiersChanged = { [weak self] modifiers in
            guard let self else { return }
            apply(machine.modifiersChanged(modifiers))
        }
        monitor.onDragEnded = { [weak self] in
            guard let self, machine.dragEnded() != nil else { return }
            // Fare bırakılışını bizim zamanlayıcımız, halkaya bırakma mesajından (performDragOperation)
            // önce görebilir. Panel hemen gizlenirse bırakma kaynak uygulamaya düşer; kısa bir bekleme.
            let current = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, generation == current else { return }
                ring.hide()
            }
        }
        ring.onSelect = { [weak self] target, payload in
            // performDragOperation içindeyiz ve kaynak uygulamanın sürükleme döngüsü bizi bekliyor;
            // soru penceresi veya uzun iş burada çalışırsa Finder takılır. Bir sonraki tura bırak.
            DispatchQueue.main.async { self?.perform(target, on: payload) }
        }
    }

    func start() {
        monitor.start()
    }

    private func apply(_ action: TriggerMachine.Action?) {
        switch action {
        case .open(let mode):
            ring.show(mode: mode, targets: RingTargets.targets(for: mode, files: files),
                      fileCount: files.count, at: NSEvent.mouseLocation)
            Log.drag.info("DragConvert açıldı: \(mode.rawValue, privacy: .public), \(self.files.count) dosya")
        case .switchMode(let mode):
            ring.update(mode: mode, targets: RingTargets.targets(for: mode, files: files),
                        fileCount: files.count)
        case .close:
            ring.hide()
        case nil:
            break
        }
    }

    private func perform(_ target: RingTarget, on payload: DropPayload) {
        ring.hide()
        // Sözü verilen dosyalar henüz yok; sayı sürükleme başındaki adlardan.
        let count = files.count
        Log.drag.info("Seçildi: \(target.id, privacy: .public) ← \(count) dosya")

        let job: Job
        if target.id.hasPrefix("convert."),
           let format = registry.format(id: String(target.id.dropFirst("convert.".count))) {
            var combine = false
            if format.kind == .pdf && count > 1 {
                switch askHowToMakePDF(count: count) {
                case .combine: combine = true
                case .separate: break
                case nil:
                    discard(payload)
                    return
                }
            }
            job = .convert(format, combine: combine)
        } else if target.id.hasPrefix("tool."), let tool = ToolID(rawValue: String(target.id.dropFirst("tool.".count))) {
            job = .tool(ToolCatalog.tool(tool))
        } else if target.id.hasPrefix("action."),
                  let action = FileAction(rawValue: String(target.id.dropFirst("action.".count))) {
            job = .action(action)
        } else {
            discard(payload)
            NSSound.beep()
            return
        }
        start(job, on: payload)
    }

    private enum Job {
        case convert(Format, combine: Bool)
        case tool(Tool)
        case action(FileAction)
    }

    /// Dosyaları klasöre taşır; adı doluysa numaralar.
    private static func export(_ files: [URL], to folder: URL) throws -> [URL] {
        try files.map { file in
            let destination = OutputNaming.destination(for: file, pathExtension: file.pathExtension, in: folder)
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
    }

    private func discard(_ payload: DropPayload) {
        if case .promised(let folder, let files) = payload {
            files.cancel()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func start(_ job: Job, on payload: DropPayload) {
        let id = UUID()
        let names = files
        let task = Task { [weak self, registry] in
            // Galeriden gelen dosyalar bırakınca teslim edilir; çıktı yanlarına yazılamaz, İndirilenler.
            let temporary: URL?, outputDirectory: URL?
            let resolve: @MainActor () async throws -> [URL]
            switch payload {
            case .files(let files):
                (temporary, outputDirectory) = (nil, nil)
                resolve = { files }
            case .promised(let folder, let files):
                (temporary, outputDirectory) = (folder, Preferences.outputFolder ?? OutputLocation.downloads)
                resolve = { try await files.value }
            }
            let cleanUp = {
                if case .promised(_, let files) = payload { files.cancel() }
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
            }
            let report: @Sendable (Double) -> Void = { fraction in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.jobProgressed(id, fraction) } }
            }
            let failed: (any Error) -> [ConversionOutcome] = { error in
                let reason = error is CancellationError ? ConversionOutcome.Result.cancelled
                    : .failed(L("Could not get the file from the source app: \(error.localizedDescription)", "Dosya kaynak uygulamadan alınamadı: \(error.localizedDescription)"))
                return [ConversionOutcome(sources: [], result: reason)]
            }

            let outcomes: [ConversionOutcome]
            switch job {
            case .tool(let tool) where tool.needsOptions:
                // Panel hemen açılır, dosya gelene kadar bekleme gösterir (iCloud'dan inmesi sürebilir).
                let waiting = temporary == nil ? L("Preparing…", "Hazırlanıyor…") : L("Getting the file from the source app…", "Kaynak uygulamadan alınıyor…")
                let answer = await ToolOptionsPrompt.ask(tool: tool, names: names, waitingMessage: waiting) {
                    let urls = try await resolve()
                    guard let first = urls.first else { throw ConversionError.failed(L("No file arrived.", "Dosya gelmedi.")) }
                    let duration = [.trim, .split, .frame, .crop].contains(tool.id)
                        ? await ToolRunner.duration(of: first, registry: registry) : nil
                    let pages = tool.id == .extractPages ? ToolRunner.pageCount(of: first) : nil
                    return ToolContext(tool: tool, files: urls, duration: duration, pageCount: pages)
                }
                guard let (context, options) = answer else {
                    cleanUp()
                    self?.jobFinished(id, [])
                    return
                }
                outcomes = await ToolRunner.run(ToolRequest(tool: tool.id, files: context.files, options: options),
                                                registry: registry, outputDirectory: outputDirectory, progress: report)
            case .tool(let tool):
                do {
                    let urls = try await resolve()
                    outcomes = await ToolRunner.run(ToolRequest(tool: tool.id, files: urls, options: .none),
                                                    registry: registry, outputDirectory: outputDirectory, progress: report)
                } catch {
                    outcomes = failed(error)
                }
            case .action(let action):
                do {
                    var urls = try await resolve()
                    // Galeriden gelen dosya geçici klasörde ve iş bitince silinecek; raf, pano ve AirDrop
                    // ona sonra da erişebilsin diye önce İndirilenler'e çıkarılır.
                    if temporary != nil { urls = try Self.export(urls, to: OutputLocation.downloads) }
                    let message = await FileActionPerformer.perform(action, on: urls)
                    outcomes = message.map { [ConversionOutcome(sources: urls, result: .failed($0))] } ?? []
                } catch {
                    outcomes = failed(error)
                }
            case .convert(let format, let combine):
                do {
                    let urls = try await resolve()
                    let request: ConversionRequest = combine ? .combineIntoPDF(urls) : .convert(urls, to: format)
                    outcomes = await Converter.run(request, registry: registry, outputDirectory: outputDirectory,
                                                   progress: report)
                } catch {
                    outcomes = failed(error)
                }
            }

            cleanUp()
            if case .tool(let tool) = job, tool.id == .extractText {
                // Okunan metin hemen yapıştırılabilsin; dosyası da yanında.
                let texts = outcomes.flatMap(\.outputs).compactMap { try? String(contentsOf: $0, encoding: .utf8) }
                if !texts.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(texts.joined(separator: "\n\n"), forType: .string)
                }
            }
            if temporary != nil {
                // Çıktı kaynağın yanında değil; nereye gittiği görünsün.
                let outputs = outcomes.flatMap(\.outputs)
                if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
            }
            // Galeriden gelen dosyalar silindi; tekrar denemek sadece Finder'daki dosyalarla mümkün.
            let canRetry = temporary == nil
            self?.jobFinished(id, outcomes, retry: canRetry ? job : nil)
        }
        jobs[id] = (task, 0)
        reportProgress()
    }

    /// Süren bütün işleri durdurur; tamamlanmış çıktılar kalır, yarım kalanlar silinir.
    func cancelAll() {
        jobs.values.forEach { $0.task.cancel() }
    }

    private func jobProgressed(_ id: UUID, _ fraction: Double) {
        guard jobs[id] != nil else { return }
        jobs[id]?.fraction = fraction
        reportProgress()
    }

    private func jobFinished(_ id: UUID, _ outcomes: [ConversionOutcome], retry: Job? = nil) {
        jobs[id] = nil
        reportProgress()
        finish(outcomes, retry: retry)
    }

    private func reportProgress() {
        onProgress?(jobs.isEmpty ? nil : jobs.values.map(\.fraction).reduce(0, +) / Double(jobs.count))
    }

    private enum PDFChoice { case combine, separate }

    /// Birden çok görüntü PDF'e giderken iki anlam da mümkün; sadece o zaman sorulur.
    private func askHowToMakePDF(count: Int) -> PDFChoice? {
        let alert = NSAlert()
        alert.messageText = L("Converting \(count) images to PDF", "\(count) görüntü PDF'e dönüştürülüyor")
        alert.informativeText = L("Put them all into one PDF in order, or make a separate PDF for each?", "Hepsi sırasıyla tek bir PDF'te mi olsun, yoksa her biri ayrı bir PDF mi?")
        alert.addButton(withTitle: L("One PDF", "Tek PDF"))
        alert.addButton(withTitle: L("Separate PDFs", "Ayrı ayrı"))
        alert.addButton(withTitle: L("Cancel", "Vazgeç"))
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .combine
        case .alertSecondButtonReturn: return .separate
        default: return nil
        }
    }

    /// Ayarlarda açıksa bildirim; uzun işlerde başka bir uygulamadayken haber verir.
    private func notify(outputs: [URL], failures: Int) {
        guard Preferences.notifyWhenDone, !outputs.isEmpty || failures > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = failures == 0 ? L("Done", "Hazır") : L("Some files failed", "Bazı dosyalar olmadı")
        content.body = outputs.count == 1 ? outputs[0].lastPathComponent
            : L("\(outputs.count) files ready", "\(outputs.count) dosya hazır") + (failures > 0 ? L(", \(failures) failed", ", \(failures) hata") : "")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func finish(_ outcomes: [ConversionOutcome], retry: Job? = nil) {
        guard !outcomes.isEmpty else { return }
        let outputs = outcomes.flatMap(\.outputs)
        if !outputs.isEmpty { onConverted?(outputs) }

        let failures = outcomes.compactMap { outcome -> String? in
            if case .failed(let message) = outcome.result { return message }
            return nil
        }
        let cancelled = outcomes.contains { if case .cancelled = $0.result { true } else { false } }
        notify(outputs: outputs, failures: failures.count)
        guard !failures.isEmpty else {
            if cancelled { return }
            NSSound(named: "Glass")?.play()
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? L("A file could not be processed", "Bir dosya dönüştürülemedi")
            : L("\(failures.count) files could not be processed", "\(failures.count) dosya dönüştürülemedi")
        alert.informativeText = failures.prefix(5).joined(separator: "\n")
            + (failures.count > 5 ? L("\n… and \(failures.count - 5) more.", "\n… ve \(failures.count - 5) tane daha.") : "")
        alert.addButton(withTitle: L("OK", "Tamam"))
        let failedSources = outcomes.filter { if case .failed = $0.result { true } else { false } }
            .flatMap(\.sources).filter { FileManager.default.fileExists(atPath: $0.path) }
        let retryButton = retry != nil && !failedSources.isEmpty
        if retryButton { alert.addButton(withTitle: L("Try Again", "Tekrar dene")) }
        if !failedSources.isEmpty { alert.addButton(withTitle: L("Show in Finder", "Finder'da göster")) }
        NSApp.activate()
        let response = alert.runModal()
        let second = NSApplication.ModalResponse.alertSecondButtonReturn
        let third = NSApplication.ModalResponse.alertThirdButtonReturn
        if retryButton && response == second, let retry {
            files = failedSources
            start(retry, on: .files(failedSources))
        } else if response == (retryButton ? third : second) {
            NSWorkspace.shared.activateFileViewerSelecting(failedSources)
        }
    }
}
