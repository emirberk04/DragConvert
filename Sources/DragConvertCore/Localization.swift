import Foundation

/// Interface language: Turkish when the user's first preferred language is Turkish, English otherwise.
///
/// Strings live next to the code as `L("English", "Türkçe")` instead of a String Catalog: SwiftPM resource
/// bundles are not found inside a hand-assembled `.app` (`Bundle.module` looks in the bundle root, which code
/// signing does not allow), and two languages do not need more machinery than this.
public enum L10n {
    public static let isTurkish: Bool = {
        if let forced = ProcessInfo.processInfo.environment["DRAGCONVERT_LANGUAGE"] { return forced.hasPrefix("tr") }
        // Tests compare messages; keep them independent of the machine's language.
        let process = ProcessInfo.processInfo.processName
        if Bundle.main.bundlePath.hasSuffix(".xctest") || process.contains("xctest") || process.contains("swiftpm-testing") {
            return false
        }
        return Locale.preferredLanguages.first?.hasPrefix("tr") ?? false
    }()
}

/// `L("Convert", "Dönüştür")`
@inline(__always)
public func L(_ english: String, _ turkish: String) -> String {
    L10n.isTurkish ? turkish : english
}
