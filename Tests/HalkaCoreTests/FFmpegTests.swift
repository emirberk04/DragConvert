import Foundation
import Testing
@testable import HalkaCore

/// Saf kısımlar: kodlayıcı listesi, ffprobe çıktısı, argümanlar, hedeflerin kodlayıcıya göre gizlenmesi.
struct FFmpegArgumentTests {
    let all: Set<String> = ["h264_videotoolbox", "aac_at", "aac", "libvpx-vp9", "libopus", "gif", "libmp3lame",
                            "pcm_s16le", "pcm_s16be", "flac", "libwebp"]
    func toolkit(_ encoders: Set<String>) -> FFmpegToolkit {
        FFmpegToolkit(ffmpeg: URL(fileURLWithPath: "/x/ffmpeg"), ffprobe: URL(fileURLWithPath: "/x/ffprobe"),
                      encoders: encoders)
    }

    @Test func parsesEncoderList() {
        let text = """
        Encoders:
         V..... = Video
         ------
         V....D h264_videotoolbox    VideoToolbox H.264 Encoder (codec h264)
         A....D libmp3lame           libmp3lame MP3
        """
        #expect(FFmpegToolkit.parseEncoders(text) == ["h264_videotoolbox", "libmp3lame"])
    }

    @Test func probeIgnoresCoverArt() {
        let json = """
        {"streams":[{"codec_type":"audio","codec_name":"mp3"},
                    {"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}],
         "format":{"duration":"12.5"}}
        """
        #expect(MediaInfo.parse(json) == MediaInfo(duration: 12.5, videoCodec: nil, audioCodec: "mp3"))
    }

    @Test func remuxesCompatibleStreams() {
        let media = MediaInfo(duration: 1, videoCodec: "hevc", audioCodec: "aac")
        let args = FFmpegArguments.build(input: URL(fileURLWithPath: "/a.mov"), output: URL(fileURLWithPath: "/a.mp4"),
                                         target: "mp4", media: media, encoders: all, remux: true)
        #expect(args.contains("copy") && args.contains("hvc1") && !args.contains("h264_videotoolbox"))
        let reencode = FFmpegArguments.build(input: URL(fileURLWithPath: "/a.mov"), output: URL(fileURLWithPath: "/a.mp4"),
                                             target: "mp4", media: media, encoders: all, remux: false)
        #expect(reencode.contains("h264_videotoolbox") && reencode.contains("aac_at") == false)
        // Ses zaten AAC: yeniden kodlanmaz.
        #expect(reencode.contains("-c:a") && reencode[reencode.firstIndex(of: "-c:a")! + 1] == "copy")
    }

    @Test func incompatibleCodecIsNotRemuxed() {
        #expect(!FFmpegArguments.canRemux(MediaInfo(duration: 1, videoCodec: "mpeg4", audioCodec: "pcm_s16le"), into: "mp4"))
        #expect(FFmpegArguments.canRemux(MediaInfo(duration: 1, videoCodec: "mpeg4", audioCodec: nil), into: "mkv"))
        #expect(!FFmpegArguments.canRemux(MediaInfo(duration: 1, videoCodec: nil, audioCodec: "aac"), into: "mkv"))
    }

    @Test func targetsFollowEncoders() {
        let full = FormatRegistry(readable: [], writable: [], ffmpeg: toolkit(all))
        #expect(full.targets(from: full.format(id: "mov")!).map(\.id) == ["mp4", "mkv", "webm", "gif", "m4a", "mp3", "wav"])
        #expect(full.targets(from: full.format(id: "mp3")!).map(\.id) == ["m4a", "wav", "flac", "opus", "aiff"])

        let noLame = FormatRegistry(readable: [], writable: [], ffmpeg: toolkit(all.subtracting(["libmp3lame"])))
        #expect(!noLame.targets(from: noLame.format(id: "mov")!).map(\.id).contains("mp3"))

        let none = FormatRegistry(readable: [], writable: [], ffmpeg: nil)
        #expect(none.targets(from: none.format(id: "mov")!).isEmpty)
    }

    @Test func webpComesFromFFmpegWhenImageIOCannotWrite() {
        let registry = FormatRegistry(readable: ["public.png"], writable: ["public.png", "public.jpeg"],
                                      ffmpeg: toolkit(["libwebp"]))
        #expect(registry.targets(from: registry.format(id: "png")!).map(\.id).contains("webp"))
        #expect(!registry.imageIOWrites(registry.format(id: "webp")!))
    }
}

/// Bu depoda derlenmiş ffmpeg (`scripts/build-ffmpeg.sh`); yoksa entegrasyon testleri atlanır.
let vendorFFmpeg: FFmpegToolkit? = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let bin = root.appendingPathComponent("Vendor/ffmpeg/bin")
    let ffmpeg = bin.appendingPathComponent("ffmpeg"), ffprobe = bin.appendingPathComponent("ffprobe")
    guard FileManager.default.isExecutableFile(atPath: ffmpeg.path) else { return nil }
    return FFmpegToolkit(ffmpeg: ffmpeg, ffprobe: ffprobe, encoders: FFmpegToolkit.listEncoders(ffmpeg))
}()

@Suite(.enabled(if: vendorFFmpeg != nil, "Vendor/ffmpeg yok: scripts/build-ffmpeg.sh"))
struct FFmpegIntegrationTests {
    static var toolkit: FFmpegToolkit? { vendorFFmpeg }

    let folder: URL
    let registry: FormatRegistry

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("HalkaFFmpeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        registry = FormatRegistry(ffmpeg: Self.toolkit)
    }

    /// Kaynak filtrelerle (lavfi aygıtı derlenmedi) test videosu: MPEG-4 Part 2 + PCM, yani MP4'e kopyalanamaz.
    func makeClip(_ name: String, seconds: Int = 1, audio: Bool = true, codec: [String] = ["-c:v", "mpeg4"]) async throws -> URL {
        let url = folder.appendingPathComponent(name)
        var graph = "testsrc=size=320x240:rate=25:duration=\(seconds)[v]"
        var maps = ["-map", "[v]"]
        if audio {
            graph += ";sine=frequency=440:duration=\(seconds)[a]"
            maps += ["-map", "[a]", "-c:a", "pcm_s16le"]
        }
        let output = try await ProcessRunner.run(Self.toolkit!.ffmpeg,
            ["-hide_banner", "-loglevel", "error", "-filter_complex", graph] + maps + codec + [url.path])
        #expect(output.status == 0, "\(output.stderr)")
        return url
    }

    func probe(_ url: URL) async throws -> MediaInfo { try await MediaInfo.probe(url, with: Self.toolkit!) }

    @Test func movToMP4ReencodesWithHardwareH264() async throws {
        let clip = try await makeClip("klip.mov")
        let progress = Recorder()
        let outcomes = await Converter.run(.convert([clip], to: registry.format(id: "mp4")!), registry: registry) {
            progress.add($0)
        }
        let output = try #require(outcomes.first?.outputs.first)
        #expect(output.lastPathComponent == "klip.mp4")
        let info = try await probe(output)
        #expect(info.videoCodec == "h264" && info.audioCodec == "aac")
        #expect(abs((info.duration ?? 0) - 1) < 0.2)
        #expect(progress.values.last == 1)
    }

    @Test func h264RemuxesWithoutReencoding() async throws {
        let source = try await makeClip("kaynak.mov", codec: ["-c:v", "h264_videotoolbox", "-c:a", "aac_at"])
        let outcomes = await Converter.run(.convert([source], to: registry.format(id: "mp4")!), registry: registry)
        let output = try #require(outcomes.first?.outputs.first)
        #expect(try await probe(output).videoCodec == "h264")
    }

    @Test func videoToAudioAndGIF() async throws {
        let clip = try await makeClip("ses.mov")
        for (target, codec) in [("mp3", "mp3"), ("m4a", "aac"), ("wav", "pcm_s16le")] {
            let outcomes = await Converter.run(.convert([clip], to: registry.format(id: target)!), registry: registry)
            let output = try #require(outcomes.first?.outputs.first, "\(target): \(String(describing: outcomes.first?.result))")
            let info = try await probe(output)
            #expect(info.audioCodec == codec && info.videoCodec == nil, "\(target)")
        }
        let gif = try #require(await Converter.run(.convert([clip], to: registry.format(id: "gif")!),
                                                   registry: registry).first?.outputs.first)
        #expect(try await probe(gif).videoCodec == "gif")
    }

    @Test func videoWithoutAudioToMP3ExplainsWhy() async throws {
        let clip = try await makeClip("sessiz.mov", audio: false)
        let outcomes = await Converter.run(.convert([clip], to: registry.format(id: "mp3")!), registry: registry)
        guard case .failed(let message) = outcomes.first?.result else {
            Issue.record("hata bekleniyordu: \(String(describing: outcomes.first?.result))")
            return
        }
        #expect(message.contains("sessiz.mov") && message.contains("audio"))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("sessiz.mp3").path))
    }

    @Test func imageToWebPThroughFFmpeg() async throws {
        let png = try ConverterTests().makePNG("resim.png")
        let outcomes = await Converter.run(.convert([png], to: registry.format(id: "webp")!), registry: registry)
        let output = try #require(outcomes.first?.outputs.first, "\(String(describing: outcomes.first?.result))")
        let header = try Data(contentsOf: output).prefix(12)
        #expect(header.prefix(4) == Data("RIFF".utf8) && header.suffix(4) == Data("WEBP".utf8))
    }

    @Test func cancellingStopsFFmpegAndLeavesNothing() async throws {
        let clip = try await makeClip("uzun.mov", seconds: 30)
        let task = Task { await Converter.run(.convert([clip], to: registry.format(id: "webm")!), registry: registry) }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        let outcomes = await task.value
        guard case .cancelled = outcomes.first?.result else {
            Issue.record("iptal bekleniyordu: \(String(describing: outcomes.first?.result))")
            return
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("uzun.") }
        #expect(left == ["uzun.mov"])
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.withLock { stored.append(value) } }
    var values: [Double] { lock.withLock { stored } }
}
