import Foundation

/// Kullanıcı ayarları (`UserDefaults`, `io.github.emirberk04.Halka`). Herhangi bir iş parçacığından okunabilir.
public enum Preferences {
    nonisolated(unsafe) public static var store: UserDefaults = .standard

    enum Key {
        static let convertModifier = "convertModifier"
        static let toolsModifier = "toolsModifier"
        static let actionsModifier = "actionsModifier"
        static let outputFolder = "outputFolder"
        static let imageQuality = "imageQuality"
        static let terminal = "terminal"
        static let ffmpegFolder = "ffmpegFolder"
        static let notifyWhenDone = "notifyWhenDone"
        static let recents = "recents"
    }

    /// Tetik tuşu: "shift", "option", "control" ya da "none" (o halka kapalı).
    public static func modifier(for mode: RingMode) -> String {
        let key = switch mode {
        case .convert: Key.convertModifier
        case .tools: Key.toolsModifier
        case .actions: Key.actionsModifier
        }
        let fallback = switch mode {
        case .convert: "shift"
        case .tools: "option"
        case .actions: "control"
        }
        return store.string(forKey: key) ?? fallback
    }

    public static func setModifier(_ value: String, for mode: RingMode) {
        let key = switch mode {
        case .convert: Key.convertModifier
        case .tools: Key.toolsModifier
        case .actions: Key.actionsModifier
        }
        store.set(value, forKey: key)
    }

    /// Bütün çıktılar için sabit klasör; `nil` = kaynağın yanı.
    public static var outputFolder: URL? {
        get { nonEmpty(Key.outputFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { store.set(newValue?.path, forKey: Key.outputFolder) }
    }

    /// Kayıplı görüntü formatlarında (JPG, HEIC, AVIF) kalite, 0.5...1.
    public static var imageQuality: Double {
        get { store.object(forKey: Key.imageQuality) as? Double ?? 0.9 }
        set { store.set(min(max(newValue, 0.5), 1), forKey: Key.imageQuality) }
    }

    /// Terminal uygulamasının bundle kimliği; `nil` = kurulu olanlardan ilki.
    public static var terminal: String? {
        get { nonEmpty(Key.terminal) }
        set { store.set(newValue, forKey: Key.terminal) }
    }

    /// Elle seçilmiş ffmpeg klasörü (içinde ffmpeg ve ffprobe); `nil` = paket içi.
    public static var ffmpegFolder: URL? {
        get { nonEmpty(Key.ffmpegFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { store.set(newValue?.path, forKey: Key.ffmpegFolder) }
    }

    /// Ayarlar penceresi "seçilmedi"yi boş metin olarak yazar.
    private static func nonEmpty(_ key: String) -> String? {
        guard let value = store.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }

    public static var notifyWhenDone: Bool {
        get { store.bool(forKey: Key.notifyWhenDone) }
        set { store.set(newValue, forKey: Key.notifyWhenDone) }
    }

    /// Son çıktılar, en yeni başta. Silinmiş olanlar okunurken atlanır.
    public static var recents: [URL] {
        get {
            (store.stringArray(forKey: Key.recents) ?? [])
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        set { store.set(newValue.map(\.path), forKey: Key.recents) }
    }
}
