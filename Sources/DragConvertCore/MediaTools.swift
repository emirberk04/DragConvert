import Foundation

/// Video ve ses araçları için ffmpeg argümanları. Saf; testler gerçek dosya olmadan denetler.
enum MediaTools {
    /// Video araçlarının çıktısı: kaynağın kapsayıcısı H.264 taşıyabiliyorsa o, değilse MP4.
    static func outputFormat(for source: Format, registry: FormatRegistry) -> Format {
        if source.kind == .audio {
            return source
        }
        return ["mp4", "mov", "m4v", "mkv"].contains(source.id) ? source : registry.format(id: "mp4")!
    }

    /// Ses kodlayıcısı, çıktı formatına göre.
    static func audioCodec(for format: String, encoders: Set<String>, bitrate: String? = nil) -> [String] {
        let aac = encoders.contains("aac_at") ? "aac_at" : "aac"
        switch format {
        case "mp3": return bitrate.map { ["-c:a", "libmp3lame", "-b:a", $0] } ?? ["-c:a", "libmp3lame", "-q:a", "2"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "aiff": return ["-c:a", "pcm_s16be"]
        case "flac": return ["-c:a", "flac"]
        case "opus", "ogg", "webm": return ["-c:a", "libopus", "-b:a", bitrate ?? "128k"]
        default: return ["-c:a", aac, "-b:a", bitrate ?? "192k"]
        }
    }

    /// H.264 kodlama; `filters` video filtre zincirinin başına, ardından çift boyut + 4:2:0.
    /// VERIFY: VideoToolbox `-q:v` ölçeği (yüksek = daha iyi); 65 ≈ kaynağa yakın, 35 belirgin küçük.
    static func h264(quality: Int, filters: [String] = [], encoders: Set<String>) -> [String] {
        let chain = (filters + ["scale=trunc(iw/2)*2:trunc(ih/2)*2", "format=yuv420p"]).joined(separator: ",")
        if encoders.contains("h264_videotoolbox") {
            return ["-c:v", "h264_videotoolbox", "-q:v", String(quality), "-vf", chain, "-tag:v", "avc1"]
        }
        // libx264 CRF ölçeği ters: düşük = daha iyi.
        let crf = max(18, min(35, 51 - quality / 2))
        return ["-c:v", "libx264", "-crf", String(crf), "-preset", "medium", "-vf", chain]
    }

    static func longEdgeFilter(_ edge: Int) -> String {
        "scale=w='if(gte(iw,ih),min(iw,\(edge)),-2)':h='if(gte(iw,ih),-2,min(ih,\(edge)))'"
    }

    /// Tek dosyalık araçların argümanları (bölme ve birleştirme ayrı).
    static func arguments(tool: ToolID, options: ToolOptions, input: URL, output: URL, source: Format,
                          outputFormat: Format, encoders: Set<String>) -> [String]? {
        var pre: [String] = [], body: [String] = []
        let isVideo = source.kind == .movie
        let container = outputFormat.id
        let audio = audioCodec(for: container, encoders: encoders)

        switch (tool, options) {
        case (.compress, .compress(let level)) where isVideo:
            let (quality, edge, bitrate): (Int, Int?, String) = switch level {
            case .light: (55, nil, "160k")
            case .medium: (45, 1920, "128k")
            case .strong: (35, 1280, "96k")
            }
            body = ["-map", "0:v:0", "-map", "0:a?"]
                + h264(quality: quality, filters: edge.map { [longEdgeFilter($0)] } ?? [], encoders: encoders)
                + audioCodec(for: container, encoders: encoders, bitrate: bitrate)
        case (.compress, .compress(let level)):
            let bitrate = switch level {
            case .light: "192k"
            case .medium: "128k"
            case .strong: "96k"
            }
            body = ["-vn", "-map", "0:a:0"] + audioCodec(for: container, encoders: encoders, bitrate: bitrate)
        case (.trim, .trim(let start, let end)):
            pre = ["-ss", seconds(start)]
            body = ["-t", seconds(end - start)]
                + (isVideo ? ["-map", "0:v:0", "-map", "0:a?"] + h264(quality: 65, encoders: encoders) : ["-vn", "-map", "0:a:0"])
                + audio
        case (.crop, .crop(let rect)) where isVideo:
            let f = { (value: Double) in String(format: "%.5f", locale: Locale(identifier: "en_US_POSIX"), value) }
            let filter = "crop=iw*\(f(rect.width)):ih*\(f(rect.height)):iw*\(f(rect.x)):ih*\(f(rect.y))"
            body = ["-map", "0:v:0", "-map", "0:a?"]
                + h264(quality: 65, filters: [filter], encoders: encoders)
                + ["-c:a", "copy"]
        case (.frame, .frame(let seconds)) where isVideo:
            pre = ["-ss", Self.seconds(seconds)]
            body = ["-map", "0:v:0", "-frames:v", "1", "-update", "1"]
            return ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + pre + ["-i", input.path] + body + [output.path]
        case (.rotate, .rotate(let degrees)) where isVideo:
            let filters = switch ((degrees % 360) + 360) % 360 {
            case 90: ["transpose=1"]
            case 270: ["transpose=2"]
            default: ["transpose=1", "transpose=1"]
            }
            body = ["-map", "0:v:0", "-map", "0:a?"] + h264(quality: 65, filters: filters, encoders: encoders)
                + ["-c:a", "copy"]
        case (.removeAudio, _) where isVideo:
            body = ["-map", "0:v:0", "-c", "copy", "-an"]
        case (.normalize, _) where !isVideo:
            // EBU R128, tek geçiş: podcast/yayın seviyesi (-16 LUFS).
            body = ["-vn", "-map", "0:a:0", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", "-ar", "48000"] + audio
        default:
            return nil
        }
        if ["mp4", "mov", "m4v", "m4a"].contains(container) { body += ["-movflags", "+faststart"] }
        return ["-hide_banner", "-nostdin", "-loglevel", "error", "-y"] + pre + ["-i", input.path] + body
            + ["-map_metadata", "0", "-progress", "pipe:1", "-nostats", output.path]
    }

    /// Anahtar karelerden bölme (yeniden kodlama yok, hızlı); parçalar `pattern`'deki `%03d` ile numaralanır.
    static func splitArguments(input: URL, pattern: URL, segmentSeconds: Double) -> [String] {
        ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", input.path,
         "-map", "0", "-c", "copy", "-f", "segment", "-segment_time", seconds(segmentSeconds),
         "-reset_timestamps", "1", "-progress", "pipe:1", "-nostats", pattern.path]
    }

    /// concat demuxer: önce akış kopyası (aynı kodlayıcıdan dosyalar), olmazsa yeniden kodlama.
    static func mergeArguments(list: URL, output: URL, outputFormat: Format, reencode: Bool, isVideo: Bool,
                               encoders: Set<String>) -> [String] {
        var args = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0", "-i", list.path]
        if reencode {
            args += isVideo
                ? ["-map", "0:v:0", "-map", "0:a?"] + h264(quality: 65, encoders: encoders)
                    + audioCodec(for: outputFormat.id, encoders: encoders)
                : ["-vn"] + audioCodec(for: outputFormat.id, encoders: encoders)
        } else {
            args += ["-c", "copy"]
        }
        if ["mp4", "mov", "m4v", "m4a"].contains(outputFormat.id) { args += ["-movflags", "+faststart"] }
        return args + ["-progress", "pipe:1", "-nostats", output.path]
    }

    /// concat listesi satırı; tek tırnaklar kaçırılır.
    static func concatLine(_ url: URL) -> String {
        "file '\(url.path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    static func seconds(_ value: Double) -> String {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), max(value, 0))
    }
}
