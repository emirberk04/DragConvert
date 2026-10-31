import Foundation

/// Çıktının yazılacağı klasör.
///
/// Varsayılan kaynağın klasörü. Ama kaynak bir paketin içindeyse (Fotoğraflar kütüphanesi, bir `.app`, bir
/// `.bundle`) oraya yazmak paketi bozar ya da kullanıcı çıktıyı hiç bulamaz; o zaman İndirilenler.
public enum OutputLocation {
    public static var downloads: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
    }

    /// `nil` = kaynağın yanına. Ayarlarda sabit bir çıktı klasörü seçildiyse o.
    public static func directory(for source: URL, preferred: URL? = Preferences.outputFolder,
                                 isPackage: (URL) -> Bool = OutputLocation.isPackage) -> URL? {
        if let preferred { return preferred }
        var folder = source.deletingLastPathComponent()
        while folder.path != "/" && !folder.path.isEmpty {
            if isPackage(folder) { return downloads }
            folder = folder.deletingLastPathComponent()
        }
        return nil
    }

    public static func isPackage(_ url: URL) -> Bool {
        // Erişim izni olmayan klasörlerde (Fotoğraflar kütüphanesi) kaynak değerleri okunamayabilir; uzantı yedeği.
        if let value = try? url.resourceValues(forKeys: [.isPackageKey]).isPackage, value { return true }
        return ["photoslibrary", "app", "bundle", "framework", "musiclibrary", "tvlibrary"]
            .contains(url.pathExtension.lowercased())
    }
}
