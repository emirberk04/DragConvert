import Foundation
import os

/// Uygulama genelindeki sabitler.
public enum Halka {
    public static let bundleIdentifier = "io.github.emirberk04.Halka"

    /// Paketlenmiş .app içinden çalışırken Info.plist'teki sürüm, `swift run` ile "dev" / "geliştirme".
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("dev", "geliştirme")
    }
}

/// `log stream --predicate 'subsystem == "io.github.emirberk04.Halka"'` ile izlenir.
public enum Log {
    public static let app = Logger(subsystem: Halka.bundleIdentifier, category: "app")
    public static let conversion = Logger(subsystem: Halka.bundleIdentifier, category: "conversion")
    public static let drag = Logger(subsystem: Halka.bundleIdentifier, category: "drag")
}
