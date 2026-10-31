import Foundation

/// ffmpeg komut satırı üretimi. Saf; testler bütün hedefleri gerçek dosya olmadan denetler.
enum FFmpegArguments {
    /// Bir hedef için gereken kodlayıcılar: her iç küme "bunlardan biri" demek.
    static func requiredEncoders(for target: String) -> [[String]] {
        let h264 = ["h264_videotoolbox", "libx264"], aac = ["aac_at", "aac"]
        switch target {
        case "mp4", "mov", "m4v", "mkv": return [h264, aac]
        case "webm": return [["libvpx-vp9"], ["libopus"]]
        case "gif": return [["gif"]]
        case "m4a", "aac": return [aac]
        case "mp3": return [["libmp3lame"]]
        case "wav": return [["pcm_s16le"]]
        case "aiff": return [["pcm_s16be"]]
        case "flac": return [["flac"]]
        case "opus", "ogg": return [["libopus"]]
        case "webp": return [["libwebp"]]
        default: return [["__yok__"]]
        }
    }

    /// Video kodlayıcısı yeniden kodlamadan (akış kopyası) taşınabiliyor mu: hızlı ve kayıpsız.
    static func canRemux(_ media: MediaInfo, into target: String) -> Bool {
        guard let video = media.videoCodec else { return false }
        let audioOK: (Set<String>) -> Bool = { allowed in media.audioCodec.map(allowed.contains) ?? true }
        switch target {
        case "mp4", "m4v": return ["h264", "hevc"].contains(video) && audioOK(["aac", "alac", "mp3", "ac3"])
        case "mov": return ["h264", "hevc", "prores", "mjpeg"].contains(video) && audioOK(["aac", "alac", "pcm_s16le", "pcm_s24le", "mp3"])
        case "mkv": return true
        case "webm": return ["vp8", "vp9", "av1"].contains(video) && audioOK(["opus", "vorbis"])
        default: return false
        }
    }

    /// - Parameters:
    ///   - remux: `canRemux` doğruysa önce akış kopyası denenir; başarısız olursa çağıran `false` ile tekrar dener.
    static func build(input: URL, output: URL, target: String, media: MediaInfo,
                      encoders: Set<String>, remux: Bool) -> [String] {
        let aac = encoders.contains("aac_at") ? "aac_at" : "aac"
        let h264 = encoders.contains("h264_videotoolbox") ? "h264_videotoolbox" : "libx264"
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", input.path]

        // Video kodlarken: çift boyut (H.264 4:2:0 şartı) ve 8 bit 4:2:0 (her oynatıcı açsın).
        let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
        func h264Video() -> [String] {
            // VERIFY: -q:v VideoToolbox'ta Apple Silicon'da sabit kalite; 65 telefondaki kaynaklara yakın boyut veriyor.
            var video = ["-c:v", h264, "-vf", "\(evenSize),format=yuv420p"]
            video += h264 == "h264_videotoolbox" ? ["-q:v", "65"] : ["-crf", "20", "-preset", "medium"]
            return video
        }
        let audioAAC = ["-c:a", media.audioCodec == "aac" ? "copy" : aac, "-b:a", "192k"]

        switch target {
        case "mp4", "mov", "m4v", "mkv":
            if remux && canRemux(media, into: target) {
                args += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
                if media.videoCodec == "hevc" && target != "mkv" { args += ["-tag:v", "hvc1"] }
            } else {
                args += ["-map", "0:v:0", "-map", "0:a?"] + h264Video() + audioAAC
                if target != "mkv" { args += ["-tag:v", "avc1"] }
            }
            if target != "mkv" { args += ["-movflags", "+faststart"] }
        case "webm":
            if remux && canRemux(media, into: target) {
                args += ["-map", "0:v:0", "-map", "0:a?", "-c", "copy"]
            } else {
                args += ["-map", "0:v:0", "-map", "0:a?", "-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0",
                         "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-vf", "format=yuv420p",
                         "-c:a", "libopus", "-b:a", "128k"]
            }
        case "gif":
            // İki geçiş yerine tek filtre grafiğinde palet üretimi: 256 renge en iyi uyan palet.
            args += ["-an", "-vf",
                     "fps=15,scale='min(640,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                     "-loop", "0"]
        case "m4a", "aac":
            args += ["-vn", "-map", "0:a:0"] + audioAAC
        case "mp3":
            args += ["-vn", "-map", "0:a:0", "-c:a", "libmp3lame", "-q:a", "2"]
        case "wav":
            args += ["-vn", "-map", "0:a:0", "-c:a", "pcm_s16le"]
        case "aiff":
            args += ["-vn", "-map", "0:a:0", "-c:a", "pcm_s16be"]
        case "flac":
            args += ["-vn", "-map", "0:a:0", "-c:a", "flac"]
        case "opus", "ogg":
            args += ["-vn", "-map", "0:a:0", "-c:a", "libopus", "-b:a", "128k"]
        case "webp":
            args += ["-frames:v", "1", "-c:v", "libwebp", "-quality", "85"]
        default:
            break
        }
        args += ["-map_metadata", "0", "-progress", "pipe:1", "-nostats", output.path]
        return args
    }

    /// ffmpeg'in son hata satırından kullanıcıya gösterilecek açıklama.
    static func explain(_ stderr: String, file: URL) -> String {
        let last = stderr.split(separator: "\n").last.map(String.init) ?? ""
        if stderr.contains("matches no streams") || stderr.contains("does not contain any stream") {
            return L("“\(file.lastPathComponent)” has no audio or video stream for this conversion.", "“\(file.lastPathComponent)” içinde bu dönüşüm için gereken ses ya da görüntü yok.")
        }
        if stderr.contains("Invalid data found") {
            return ConversionError.unreadable(file).localizedDescription
        }
        return L("Could not convert “\(file.lastPathComponent)” (ffmpeg: \(last.trimmingCharacters(in: .whitespaces))).", "“\(file.lastPathComponent)” dönüştürülemedi (ffmpeg: \(last.trimmingCharacters(in: .whitespaces))).")
    }
}

/// ffmpeg ile dönüştürme.
enum FFmpegEngine {
    /// `progress`: 0...1, süre biliniyorsa.
    static func convert(_ file: URL, to target: Format, writingTo destination: URL, toolkit: FFmpegToolkit,
                        progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let media = try await MediaInfo.probe(file, with: toolkit)
        let tracker = FFmpegProgress(duration: media.duration, report: progress)

        func attempt(remux: Bool) async throws -> ProcessRunner.Output {
            let args = FFmpegArguments.build(input: file, output: destination, target: target.id, media: media,
                                             encoders: toolkit.encoders, remux: remux)
            Log.conversion.debug("ffmpeg \(args.joined(separator: " "), privacy: .public)")
            return try await ProcessRunner.run(toolkit.ffmpeg, args) { tracker.consume($0) }
        }

        var output = try await attempt(remux: true)
        if output.status != 0 && FFmpegArguments.canRemux(media, into: target.id) {
            // Akış kopyası bazı kapsayıcı/kodlayıcı birleşimlerinde reddedilir; o zaman yeniden kodla.
            Log.conversion.info("Akış kopyası olmadı, yeniden kodlanıyor: \(file.lastPathComponent, privacy: .public)")
            output = try await attempt(remux: false)
        }
        guard output.status == 0 else {
            throw ConversionError.failed(FFmpegArguments.explain(output.stderr, file: file))
        }
    }
}

/// `-progress pipe:1` satırlarından (`out_time_us=...`) ilerleme oranı.
final class FFmpegProgress: @unchecked Sendable {
    private let duration: Double?
    private let report: (@Sendable (Double) -> Void)?

    init(duration: Double?, report: (@Sendable (Double) -> Void)?) {
        self.duration = duration
        self.report = report
    }

    func consume(_ line: String) {
        guard let report, let duration, duration > 0 else { return }
        if line.hasPrefix("out_time_us="), let micros = Double(line.dropFirst("out_time_us=".count)) {
            report(min(max(micros / 1_000_000 / duration, 0), 1))
        } else if line == "progress=end" {
            report(1)
        }
    }
}
