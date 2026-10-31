import Foundation

/// Kurulu Microsoft Office uygulamaları.
public struct OfficeApps: Sendable, Equatable {
    public enum App: String, Sendable {
        case word = "Microsoft Word"
        case powerpoint = "Microsoft PowerPoint"
        case excel = "Microsoft Excel"
    }

    public var word = false
    public var powerpoint = false
    public var excel = false

    public init(word: Bool = false, powerpoint: Bool = false, excel: Bool = false) {
        self.word = word
        self.powerpoint = powerpoint
        self.excel = excel
    }

    public static func installed() -> OfficeApps {
        func exists(_ app: App) -> Bool {
            ["/Applications", NSHomeDirectory() + "/Applications"].contains {
                FileManager.default.fileExists(atPath: "\($0)/\(app.rawValue).app")
            }
        }
        return OfficeApps(word: exists(.word), powerpoint: exists(.powerpoint), excel: exists(.excel))
    }
}

/// Word, PowerPoint ve Excel'e AppleScript ile "aç, farklı kaydet, kapat" yaptırır; en doğru düzen budur.
///
/// Office uygulamaları sandbox'ta: Apple Event'le gönderilen dosyayı açabilirler ama rastgele bir klasöre
/// kaydetmek "erişim izni ver" penceresi açar. Bu yüzden çıktı uygulamanın kendi geçici klasörüne
/// (`path to temporary items`, Office'e gönderildiği için onun kapsayıcısı) yazılır, Halka oradan alır.
/// İlk kullanımda macOS iki izin sorar: Halka'nın Office'i denetlemesi (Otomasyon) ve başka uygulamanın
/// verisine erişmesi. VERIFY: PDF → Word dönüşümünde Word'ün "PDF'i dönüştürecek" uyarısı tıklama isteyebilir.
enum OfficeEngine {
    static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")

    /// Hedef formatın uygulamadaki kayıt biçimi.
    static func saveFormat(app: OfficeApps.App, target: String) -> String? {
        switch (app, target) {
        case (.word, "pdf"): "format PDF"
        case (.word, "docx"): "format document"
        case (.powerpoint, "pdf"): "save as PDF"
        case (.powerpoint, "pptx"): "save as Open XML presentation"
        case (.powerpoint, "ppt"): "save as presentation"
        case (.excel, "pdf"): "PDF file format"
        case (.excel, "xlsx"): "workbook normal file format"
        case (.excel, "xls"): "Excel98to2004 file format"
        case (.excel, "csv"): "CSV file format"
        default: nil
        }
    }

    static func script(app: OfficeApps.App, format: String) -> String {
        let body = switch app {
        case .word: """
                open (POSIX file inPath)
                set theDoc to missing value
                -- Uygulama kapalıyken açılış sürer; belge yüklenmeden "active document" boş gelir.
                repeat 240 times
                    try
                        set theDoc to active document
                    end try
                    if theDoc is not missing value then exit repeat
                    delay 0.25
                end repeat
                if theDoc is missing value then error "Belge açılamadı."
                save as theDoc file name (outFolder & outName) file format \(format)
                close theDoc saving no
            """
        case .powerpoint: """
                open (POSIX file inPath)
                set thePres to missing value
                -- Uygulama kapalıyken açılış sürer; belge yüklenmeden "active presentation" boş gelir.
                repeat 240 times
                    try
                        set thePres to active presentation
                    end try
                    if thePres is not missing value then exit repeat
                    delay 0.25
                end repeat
                if thePres is missing value then error "Belge açılamadı."
                save thePres in (outFolder & outName) as \(format)
                close thePres
            """
        case .excel: """
                open (POSIX file inPath)
                set theBook to missing value
                -- Uygulama kapalıyken açılış sürer; belge yüklenmeden "active workbook" boş gelir.
                repeat 240 times
                    try
                        set theBook to active workbook
                    end try
                    if theBook is not missing value then exit repeat
                    delay 0.25
                end repeat
                if theBook is missing value then error "Belge açılamadı."
                save workbook as theBook filename (outFolder & outName) file format \(format)
                close theBook saving no
            """
        }
        return """
        on run argv
            set inPath to item 1 of argv
            set outName to item 2 of argv
            set wasRunning to running of application "\(app.rawValue)"
            tell application "\(app.rawValue)"
                with timeout of 900 seconds
                    set outFolder to (path to temporary items) as text
        \(body)
                    if not wasRunning then quit
                end timeout
            end tell
            return POSIX path of (outFolder & outName)
        end run
        """
    }

    static func convert(_ file: URL, to target: Format, app: OfficeApps.App, writingTo destination: URL) async throws {
        guard let format = saveFormat(app: app, target: target.id) else {
            throw ConversionError.unsupported(file, target.label)
        }
        // Benzersiz ad: aynı anda iki iş aynı geçici klasörü kullanabilir.
        let name = "halka-\(UUID().uuidString).\(target.pathExtension)"
        let output = try await ProcessRunner.run(osascript, ["-e", script(app: app, format: format), file.path, name])
        guard output.status == 0 else {
            throw ConversionError.failed(explain(output.stderr, app: app, file: file))
        }
        let produced = URL(fileURLWithPath: output.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConversionError.failed(L("\(app.rawValue) did not save “\(file.lastPathComponent)”.", "\(app.rawValue) “\(file.lastPathComponent)” dosyasını kaydetmedi."))
        }
        try FileManager.default.moveItem(at: produced, to: destination)
    }

    static func explain(_ stderr: String, app: OfficeApps.App, file: URL) -> String {
        if stderr.contains("-1743") || stderr.contains("Not authorized") {
            return L("Allow Halka to control \(app.rawValue): System Settings › Privacy & Security › Automation › Halka.", "Halka'nın \(app.rawValue)'ı kullanmasına izin verin: Sistem Ayarları › Gizlilik ve Güvenlik › Otomasyon › Halka.")
        }
        if stderr.contains("-1712") || stderr.contains("timed out") {
            return L("\(app.rawValue) did not respond; a dialog may be waiting for you.", "\(app.rawValue) yanıt vermedi; açık bir pencere onay bekliyor olabilir.")
        }
        let last = stderr.split(separator: "\n").last.map(String.init) ?? ""
        return L("Could not convert “\(file.lastPathComponent)” with \(app.rawValue) (\(last.trimmingCharacters(in: .whitespaces))).", "“\(file.lastPathComponent)” \(app.rawValue) ile dönüştürülemedi (\(last.trimmingCharacters(in: .whitespaces))).")
    }
}
