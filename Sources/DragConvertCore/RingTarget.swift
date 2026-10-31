import Foundation
import UniformTypeIdentifiers

/// Halkanın hangi soruyu sorduğu: dosya ne olsun, dosyaya ne yapılsın, dosyayla ne yapılsın.
public enum RingMode: String, Sendable, CaseIterable {
    case convert
    case tools
    case actions

    public var title: String {
        switch self {
        case .convert: L("Convert", "Dönüştür")
        case .tools: L("Tools", "Araçlar")
        case .actions: L("Actions", "İşlemler")
        }
    }
}

/// Halkadaki bir dilim.
public struct RingTarget: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// SF Symbol adı.
    public let symbol: String

    public init(id: String, label: String, symbol: String) {
        self.id = id
        self.label = label
        self.symbol = symbol
    }
}

/// Dosyanın kaba türü; hedef ve araç listelerini seçmek için.
public enum FileKind: Sendable, Equatable {
    case image, movie, audio, pdf, document, presentation, spreadsheet, other

    public init(url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            self = .other
            return
        }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) { self = .movie }
        else if type.conforms(to: .audio) { self = .audio }
        else if type.conforms(to: .presentation) { self = .presentation }
        else if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) { self = .spreadsheet }
        else if type.conforms(to: .text) || type.conforms(to: .rtf) || type.conforms(to: .html)
                    || ["docx", "doc", "odt"].contains(url.pathExtension.lowercased()) { self = .document }
        else { self = .other }
    }
}

/// Halkadaki hedefler: dönüştürme format kayıt defterinden, araçlar `ToolCatalog`'dan, işlemler sabit.
public enum RingTargets {
    public static func targets(for mode: RingMode, files: [URL],
                               registry: FormatRegistry = .shared) -> [RingTarget] {
        switch mode {
        case .convert:
            return registry.commonTargets(for: files).map {
                RingTarget(id: "convert.\($0.id)", label: $0.label, symbol: $0.symbol)
            }
        case .tools:
            return ToolCatalog.tools(for: files, registry: registry).map {
                RingTarget(id: "tool.\($0.id.rawValue)", label: $0.label, symbol: $0.symbol)
            }
        case .actions:
            guard !files.isEmpty else { return [] }
            let allZip = files.allSatisfy { $0.pathExtension.lowercased() == "zip" }
            return FileAction.allCases.filter { action in
                switch action {
                case .unzip: allZip
                case .zip: !allZip
                default: true
                }
            }.map { RingTarget(id: "action.\($0.rawValue)", label: $0.label, symbol: $0.symbol) }
        }
    }
}

/// ⌃ halkası: dosyaya değil dosyayla yapılanlar; türden bağımsız.
public enum FileAction: String, Sendable, CaseIterable {
    case airdrop, shelf, copy
    case copyPath = "copy-path"
    case move, zip, unzip, terminal

    public var label: String {
        switch self {
        case .airdrop: "AirDrop"
        case .shelf: L("Shelf", "Raf")
        case .copy: L("Copy", "Kopyala")
        case .copyPath: L("Copy path", "Yolu kopyala")
        case .move: L("Move to…", "Taşı…")
        case .zip: L("Zip", "ZIP'le")
        case .unzip: L("Unzip", "ZIP'i aç")
        case .terminal: "Terminal"
        }
    }

    public var symbol: String {
        switch self {
        case .airdrop: "wave.3.right"
        case .shelf: "tray"
        case .copy: "doc.on.doc"
        case .copyPath: "link"
        case .move: "folder"
        case .zip: "archivebox"
        case .unzip: "archivebox.fill"
        case .terminal: "terminal"
        }
    }
}
