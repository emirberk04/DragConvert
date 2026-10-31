import Foundation

/// Bulunmuş bir ffmpeg/ffprobe çifti ve ffmpeg'in kodlayabildikleri.
public struct FFmpegToolkit: Sendable, Equatable {
    public let ffmpeg: URL
    public let ffprobe: URL
    /// `ffmpeg -encoders` çıktısındaki adlar (`h264_videotoolbox`, `libmp3lame`, ...).
    public let encoders: Set<String>

    public init(ffmpeg: URL, ffprobe: URL, encoders: Set<String>) {
        self.ffmpeg = ffmpeg
        self.ffprobe = ffprobe
        self.encoders = encoders
    }

    /// Arama sırası: `HALKA_FFMPEG_DIR` ortam değişkeni (testler, `swift run`), paket içi `Contents/Helpers`,
    /// Homebrew yolları. Ayarlardaki elle yol H6'da önce gelecek. Bulunamazsa video/ses hedefleri gizlenir.
    public static func locate() -> FFmpegToolkit? {
        var folders: [URL] = []
        if let chosen = Preferences.ffmpegFolder { folders.append(chosen) }
        if let dir = ProcessInfo.processInfo.environment["HALKA_FFMPEG_DIR"] {
            folders.append(URL(fileURLWithPath: dir, isDirectory: true))
        }
        folders.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true))
        folders += ["/opt/homebrew/bin", "/usr/local/bin"].map { URL(fileURLWithPath: $0, isDirectory: true) }

        let manager = FileManager.default
        for folder in folders {
            let ffmpeg = folder.appendingPathComponent("ffmpeg"), ffprobe = folder.appendingPathComponent("ffprobe")
            guard manager.isExecutableFile(atPath: ffmpeg.path), manager.isExecutableFile(atPath: ffprobe.path)
            else { continue }
            let encoders = listEncoders(ffmpeg)
            guard !encoders.isEmpty else {
                Log.conversion.error("ffmpeg kodlayıcı bildirmedi, kullanılmıyor: \(ffmpeg.path, privacy: .public)")
                continue
            }
            Log.conversion.info("ffmpeg: \(ffmpeg.path, privacy: .public), \(encoders.count) kodlayıcı")
            return FFmpegToolkit(ffmpeg: ffmpeg, ffprobe: ffprobe, encoders: encoders)
        }
        Log.conversion.info("ffmpeg bulunamadı; video ve ses dönüşümleri gizli")
        return nil
    }

    /// Senkron; uygulama açılışında bir kez, arka planda çağrılır.
    static func listEncoders(_ ffmpeg: URL) -> Set<String> {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-encoders"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseEncoders(String(decoding: data, as: UTF8.self))
    }

    /// ` V....D h264_videotoolbox    VideoToolbox H.264 Encoder` → `h264_videotoolbox`. Başlık `------` ile biter.
    static func parseEncoders(_ text: String) -> Set<String> {
        var names: Set<String> = []
        var inList = false
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            if !inList {
                if fields.first?.hasPrefix("---") == true { inList = true }
                continue
            }
            if fields.count >= 2, let flags = fields.first, flags.count == 6 {
                names.insert(String(fields[1]))
            }
        }
        return names
    }
}

/// ffprobe'un bir medya dosyası hakkında söyledikleri.
struct MediaInfo: Sendable, Equatable {
    var duration: Double?
    var videoCodec: String?
    var audioCodec: String?

    static func probe(_ file: URL, with toolkit: FFmpegToolkit) async throws -> MediaInfo {
        let output = try await ProcessRunner.run(toolkit.ffprobe, [
            "-v", "error", "-show_entries", "format=duration:stream=codec_type,codec_name,disposition",
            "-of", "json", file.path,
        ])
        guard output.status == 0 else { throw ConversionError.unreadable(file) }
        return parse(output.stdout)
    }

    static func parse(_ json: String) -> MediaInfo {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            return MediaInfo()
        }
        var info = MediaInfo()
        if let format = object["format"] as? [String: Any], let duration = format["duration"] as? String {
            info.duration = Double(duration)
        }
        for stream in object["streams"] as? [[String: Any]] ?? [] {
            let type = stream["codec_type"] as? String, codec = stream["codec_name"] as? String
            // Kapak resmi (MP3/M4A içindeki JPEG) video akışı sayılmaz.
            let attachedPicture = (stream["disposition"] as? [String: Any])?["attached_pic"] as? Int == 1
            if type == "video", !attachedPicture, info.videoCodec == nil { info.videoCodec = codec }
            if type == "audio", info.audioCodec == nil { info.audioCodec = codec }
        }
        return info
    }
}
