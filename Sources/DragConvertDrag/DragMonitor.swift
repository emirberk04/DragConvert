import AppKit
import DragConvertCore
import UniformTypeIdentifiers

/// Başka bir uygulamadan (çoğunlukla Finder) dosya sürüklendiğini ve sürükleme sırasında tetik tuşlarını izler.
///
/// Yaklaşım:
/// - Global `leftMouseDown` monitörü fare basıldığını haber verir. Fare olayları için global monitör
///   Erişilebilirlik izni istemez (klavye olayları ister); bu yüzden tuşlar olayla değil
///   `NSEvent.modifierFlags` okunarak alınır.
/// - Fare basılıyken (ve sadece o sırada) 60 Hz'lik bir zamanlayıcı sürükleme panosunun
///   (`NSPasteboard(name: .drag)`) `changeCount`'una bakar. Değiştiyse ve içinde dosya URL'leri varsa
///   bir dosya sürüklemesi başlamıştır. Fare bırakılınca zamanlayıcı durur; boşta hiçbir şey çalışmaz.
/// - Taban `changeCount` bir önceki fare bırakılışında alınır, basılışta değil: global monitör asenkron
///   olduğundan kaynak uygulama panoya bizim basılış olayımızdan önce yazmış olabilir.
@MainActor
public final class DragMonitor {
    public var onDragBegan: ((_ files: [URL], _ modifiers: TriggerModifiers) -> Void)?
    public var onModifiersChanged: ((TriggerModifiers) -> Void)?
    public var onDragEnded: (() -> Void)?

    private let pasteboard = NSPasteboard(name: .drag)
    private var mouseDownMonitor: Any?
    private var timer: Timer?
    private var baselineChangeCount: Int
    private var dragging = false
    private var lastModifiers: TriggerModifiers = []

    public init() {
        baselineChangeCount = pasteboard.changeCount
    }

    public func start() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseWentDown() }
        }
    }

    public func stop() {
        if let mouseDownMonitor { NSEvent.removeMonitor(mouseDownMonitor) }
        mouseDownMonitor = nil
        stopPolling()
    }

    /// Şu anki tetik tuşları; sadece ⇧ ⌥ ⌃ (⌘ sürüklemede Finder'ın kendi anlamını taşır, dokunulmaz).
    public static var currentModifiers: TriggerModifiers {
        let flags = NSEvent.modifierFlags
        var result: TriggerModifiers = []
        if flags.contains(.shift) { result.insert(.shift) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        return result
    }

    private func mouseWentDown() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Sürükleme sırasında ana döngü olay izleme modunda dönebilir; .common ile orada da çalışır.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if NSEvent.pressedMouseButtons & 1 == 0 {
            if dragging {
                dragging = false
                onDragEnded?()
            }
            stopPolling()
            return
        }

        if !dragging {
            guard pasteboard.changeCount != baselineChangeCount else { return }
            baselineChangeCount = pasteboard.changeCount
            let files = Self.draggedNames(on: pasteboard)
            guard !files.isEmpty else { return }
            dragging = true
            lastModifiers = Self.currentModifiers
            Log.drag.debug("Sürükleme başladı: \(files.count) dosya")
            onDragBegan?(files, lastModifiers)
            return
        }

        let modifiers = Self.currentModifiers
        if modifiers != lastModifiers {
            lastModifiers = modifiers
            onModifiersChanged?(modifiers)
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        baselineChangeCount = pasteboard.changeCount
    }

    static let promisedName = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-suggested-file-name")
    static let promisedType = NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-content-type")

    /// Halkanın hedeflerini seçmek için sürüklenen her öğenin adı.
    ///
    /// Finder gerçek dosya yolunu verir. Fotoğraflar gibi uygulamalar ise dosyayı bırakınca oluşturmayı
    /// "söz verir" (file promise) ve yanına küçük bir önizleme JPEG'inin yolunu koyar: o yol kullanılırsa video
    /// resim sanılır. Sözü verilen öğede önerilen ad (`IMG_1234.MOV`) esas alınır; dönen URL gerçek bir dosya
    /// değil, sadece adı taşıyan geçici bir yoldur.
    public static func draggedNames(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { item -> URL? in
            if let type = item.string(forType: promisedType) {
                var name = item.string(forType: promisedName) ?? ""
                if name.isEmpty {
                    let ext = UTType(type)?.preferredFilenameExtension ?? ""
                    name = ext.isEmpty ? L("file", "dosya") : L("file.\(ext)", "dosya.\(ext)")
                }
                return FileManager.default.temporaryDirectory.appendingPathComponent(name)
            }
            guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL
            else { return nil }
            return url
        }
    }

    public static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        )
        return (objects as? [URL]) ?? []
    }
}
