import Foundation
import os

/// Uygulama genelindeki sabitler.
public enum DragConvert {
    public static let bundleIdentifier = "io.github.emirberk04.DragConvert"

    /// Paketlenmiş .app içinden çalışırken Info.plist'teki sürüm, `swift run` ile "dev" / "geliştirme".
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("dev", "geliştirme")
    }
}

/// `log stream --predicate 'subsystem == "io.github.emirberk04.DragConvert"'` ile izlenir.
public enum Log {
    public static let app = Logger(subsystem: DragConvert.bundleIdentifier, category: "app")
    public static let conversion = Logger(subsystem: DragConvert.bundleIdentifier, category: "conversion")
    public static let drag = Logger(subsystem: DragConvert.bundleIdentifier, category: "drag")
}
