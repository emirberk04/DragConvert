import AppKit
import DragConvertCore

/// ⌃ halkasındaki işlemleri yapar.
@MainActor
public enum FileActionPerformer {
    /// Bilinen terminaller, tercih sırasıyla: ayarlarda seçilmemişse kurulu olan ilki.
    static let terminals = ["dev.warp.Warp-Stable", "com.googlecode.iterm2", "com.apple.Terminal"]

    public static var terminal: URL? {
        if let chosen = Preferences.terminal, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) {
            return app
        }
        return terminals.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    /// Hata olursa kullanıcıya gösterilecek açıklama, yoksa `nil`.
    public static func perform(_ action: FileAction, on files: [URL]) async -> String? {
        switch action {
        case .airdrop:
            guard let service = NSSharingService(named: .sendViaAirDrop) else { return L("AirDrop is not available on this Mac.", "AirDrop bu Mac'te yok.") }
            guard service.canPerform(withItems: files) else { return L("These files cannot be sent with AirDrop.", "Bu dosyalar AirDrop ile gönderilemiyor.") }
            NSApp.activate()
            service.perform(withItems: files)
        case .shelf:
            ShelfController.shared.add(files)
        case .copy:
            // Finder'da ⌘V ile yapıştırılabilir; metin alanlarına dosya adı olarak gider.
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(files as [NSURL])
            NSSound(named: "Pop")?.play()
        case .copyPath:
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(files.map(\.path).joined(separator: "\n"), forType: .string)
            NSSound(named: "Pop")?.play()
        case .move:
            return await move(files)
        case .zip, .unzip:
            do {
                var outputs: [URL] = []
                if action == .zip {
                    outputs.append(try await ArchiveTools.zip(files, in: Preferences.outputFolder))
                } else {
                    for file in files { outputs.append(try await ArchiveTools.unzip(file, in: Preferences.outputFolder)) }
                }
                NSWorkspace.shared.activateFileViewerSelecting(outputs)
                NSSound(named: "Glass")?.play()
            } catch is CancellationError {
            } catch {
                return error.localizedDescription
            }
        case .terminal:
            guard let app = terminal else { return L("No terminal app was found.", "Terminal uygulaması bulunamadı.") }
            // Klasörse kendisi, dosyaysa bulunduğu klasör; birden çok seçimde ortak olanlar tekrar açılmaz.
            var folders: [URL] = []
            for file in files {
                let isFolder = (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let folder = isFolder ? file : file.deletingLastPathComponent()
                if !folders.contains(folder) { folders.append(folder) }
            }
            do {
                try await NSWorkspace.shared.open(folders, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
            } catch {
                return L("Could not open the terminal: \(error.localizedDescription)", "Terminal açılamadı: \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// Klasör seçtirir ve taşır; adı dolu olan dosyalar numaralanır, üzerine yazılmaz.
    static func move(_ files: [URL]) async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Move Here", "Buraya taşı")
        panel.message = files.count == 1 ? L("Where should “\(files[0].lastPathComponent)” go?", "“\(files[0].lastPathComponent)” nereye taşınsın?") : L("Where should these \(files.count) files go?", "\(files.count) dosya nereye taşınsın?")
        panel.directoryURL = files.first?.deletingLastPathComponent()
        NSApp.activate()
        guard await panel.begin() == .OK, let folder = panel.url else { return nil }

        var failures: [String] = []
        var moved: [URL] = []
        for file in files {
            let ext = file.pathExtension
            let destination = OutputNaming.destination(for: file, pathExtension: ext, in: folder)
            guard destination.deletingLastPathComponent().standardizedFileURL != file.deletingLastPathComponent().standardizedFileURL
            else { continue }
            do {
                try FileManager.default.moveItem(at: file, to: destination)
                moved.append(destination)
            } catch {
                failures.append("“\(file.lastPathComponent)”: \(error.localizedDescription)")
            }
        }
        if !moved.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(moved) }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
}

