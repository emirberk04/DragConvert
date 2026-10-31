import AppKit
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import DragConvertCore
@testable import DragConvertDrag
@testable import DragConvertUI

/// Renders the README images from the real views, off screen:
///
///     RENDER_SCREENSHOTS=1 swift test --filter Screenshots
///
/// Writes to `docs/images/`. Skipped in normal test runs.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["RENDER_SCREENSHOTS"] != nil), .serialized)
@MainActor
struct Screenshots {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let output = root.appendingPathComponent("docs/images", isDirectory: true)

    /// Every target available, without launching ffmpeg or Office.
    let registry = FormatRegistry(
        ffmpeg: FFmpegToolkit(ffmpeg: URL(fileURLWithPath: "/x"), ffprobe: URL(fileURLWithPath: "/y"),
                              encoders: ["h264_videotoolbox", "aac_at", "libvpx-vp9", "libopus", "gif", "libmp3lame",
                                         "pcm_s16le", "pcm_s16be", "flac", "libwebp"]),
        office: OfficeApps(word: true, powerpoint: true, excel: true))

    // MARK: Rings

    @Test func rings() throws {
        let scenes: [(String, RingMode, String, String)] = [
            ("ring-convert", .convert, "IMG_2048.HEIC", "convert.jpg"),
            ("ring-tools", .tools, "Holiday.mov", "tool.trim"),
            ("ring-actions", .actions, "Report.pdf", "action.airdrop"),
            ("ring-documents", .convert, "Thesis.docx", "convert.pdf"),
        ]
        for (name, mode, file, selected) in scenes {
            let url = URL(fileURLWithPath: "/tmp/\(file)")
            let targets = RingTargets.targets(for: mode, files: [url], registry: registry)
            let index = try #require(targets.firstIndex { $0.id == selected }, "\(selected) not in \(targets.map(\.id))")
            try save(ringScene(mode: mode, targets: targets, highlighted: index, file: url), name)
        }
    }

    @Test func hero() throws {
        let scenes: [(RingMode, String, String, String)] = [
            (.convert, "IMG_2048.HEIC", "convert.jpg", "⇧  Convert"),
            (.tools, "Holiday.mov", "tool.trim", "⌥  Tools"),
            (.actions, "Report.pdf", "action.airdrop", "⌃  Actions"),
        ]
        let geometry = RingGeometry()
        let side = (geometry.outerRadius + 14) * 2
        var rings: [NSImage] = []
        for (mode, file, selected, _) in scenes {
            let targets = RingTargets.targets(for: mode, files: [URL(fileURLWithPath: "/tmp/\(file)")], registry: registry)
            let view = RingView(geometry: geometry)
            view.frame = NSRect(x: 0, y: 0, width: side, height: side)
            view.mode = mode
            view.targets = targets
            view.fileCount = 1
            view.highlighted = targets.firstIndex { $0.id == selected }
            rings.append(snapshot(view))
        }
        let size = NSSize(width: 1280, height: 520)
        let image = NSImage(size: size, flipped: false) { rect in
            Self.wallpaper(rect)
            for (index, ring) in rings.enumerated() {
                let centre = NSPoint(x: rect.width * (Double(index) + 0.5) / 3, y: rect.midY + 30)
                let radius = geometry.outerRadius + 6
                let disk = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = .black.withAlphaComponent(0.45)
                shadow.shadowBlurRadius = 30
                shadow.shadowOffset = NSSize(width: 0, height: -10)
                shadow.set()
                NSColor(white: 0.11, alpha: 0.86).setFill()
                disk.fill()
                NSGraphicsContext.restoreGraphicsState()
                ring.draw(in: NSRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side))
                Self.drawText(scenes[index].3, at: NSPoint(x: centre.x, y: centre.y - radius - 34), size: 20,
                              color: .white, centred: true, bold: true)
            }
            return true
        }
        try save(image, "hero")
    }

    func ringScene(mode: RingMode, targets: [RingTarget], highlighted: Int, file: URL) -> NSImage {
        let size = NSSize(width: 760, height: 600)
        let geometry = RingGeometry()
        let view = RingView(geometry: geometry)
        let side = (geometry.outerRadius + 14) * 2
        view.frame = NSRect(x: 0, y: 0, width: side, height: side)
        view.mode = mode
        view.targets = targets
        view.fileCount = 1
        view.highlighted = highlighted
        let ring = snapshot(view)

        return NSImage(size: size, flipped: false) { rect in
            Self.wallpaper(rect)
            let centre = NSPoint(x: rect.midX, y: rect.midY + 40)
            // The live panel uses a blurred HUD material; a dark translucent disk stands in for it here.
            let radius = geometry.outerRadius + 6
            let disk = NSBezierPath(ovalIn: NSRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2))
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.45)
            shadow.shadowBlurRadius = 30
            shadow.shadowOffset = NSSize(width: 0, height: -10)
            shadow.set()
            NSColor(white: 0.11, alpha: 0.86).setFill()
            disk.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            disk.lineWidth = 1
            disk.stroke()
            ring.draw(in: NSRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side))

            // Cursor on the selected wedge, just past the dead zone, and the dragged file under the ring.
            let mid = geometry.center(of: highlighted, count: targets.count)
            let length = (mid.x * mid.x + mid.y * mid.y).squareRoot()
            let reach = (geometry.innerRadius + 16) / length
            let pointer = NSPoint(x: centre.x + mid.x * reach, y: centre.y + mid.y * reach)
            let icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: file.pathExtension) ?? .data)
            let below = centre.y - geometry.outerRadius - 30
            icon.draw(in: NSRect(x: centre.x - 22, y: below - 44, width: 44, height: 44))
            Self.drawText(file.lastPathComponent, at: NSPoint(x: centre.x, y: below - 58), size: 12,
                          color: .white, centred: true, background: true)
            let cursor = NSCursor.arrow.image
            cursor.draw(in: NSRect(x: pointer.x - 4, y: pointer.y - cursor.size.height + 4,
                                   width: cursor.size.width, height: cursor.size.height))
            return true
        }
    }

    // MARK: Panels

    @Test func panels() async throws {
        let photo = try Self.samplePhoto()
        let crop = ToolContext(tool: ToolCatalog.tool(.crop), files: [photo])
        var cropView = ToolOptionsView(context: crop) { _ in }
        cropView.previewCrop = CropRect(x: 0.42, y: 0.12, width: 0.42, height: 0.7)
        try save(await windowScene(title: "Crop", cropView), "panel-crop")
        let compress = ToolContext(tool: ToolCatalog.tool(.compress), files: [photo])
        try save(await windowScene(title: "Compress", ToolOptionsView(context: compress) { _ in }), "panel-compress")
        let settings = SettingsView(previewVersion: "1.0.0", previewFFmpeg: L("Using the bundled one", "Pakettekini kullanıyor"))
        try save(await windowScene(title: "DragConvert Settings", settings, wait: 0.3), "settings")
    }

    func windowScene<V: View>(title: String, _ content: V, wait: Double = 2.5) async throws -> NSImage {
        let hosting = NSHostingView(rootView: content.environment(\.colorScheme, .dark))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        // Let `.task` load previews and estimates, then size to the final layout.
        try await Task.sleep(for: .seconds(wait))
        hosting.setFrameSize(hosting.fittingSize)
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        let body = snapshot(hosting)

        let titleBar = 30.0, margin = 46.0
        let windowSize = NSSize(width: body.size.width, height: body.size.height + titleBar)
        let size = NSSize(width: windowSize.width + margin * 2, height: windowSize.height + margin * 2)
        return NSImage(size: size, flipped: false) { rect in
            Self.wallpaper(rect)
            let frame = NSRect(x: margin, y: margin, width: windowSize.width, height: windowSize.height)
            let shape = NSBezierPath(roundedRect: frame, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = .black.withAlphaComponent(0.5)
            shadow.shadowBlurRadius = 28
            shadow.shadowOffset = NSSize(width: 0, height: -12)
            shadow.set()
            NSColor(red: 0.16, green: 0.16, blue: 0.17, alpha: 1).setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            body.draw(in: NSRect(x: frame.minX, y: frame.minY, width: body.size.width, height: body.size.height))
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.12).setStroke()
            shape.stroke()
            for (index, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: NSRect(x: frame.minX + 14 + Double(index) * 20, y: frame.maxY - 21, width: 12, height: 12)).fill()
            }
            Self.drawText(title, at: NSPoint(x: frame.midX, y: frame.maxY - 22), size: 13, color: .secondaryLabelColor,
                          centred: true, bold: true)
            return true
        }
    }

    // MARK: Helpers

    func snapshot(_ view: NSView) -> NSImage {
        var image = NSImage()
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            view.appearance = NSAppearance(named: .darkAqua)
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            image = NSImage(size: view.bounds.size)
            image.addRepresentation(rep)
        }
        return image
    }

    func save(_ image: NSImage, _ name: String) throws {
        try FileManager.default.createDirectory(at: Self.output, withIntermediateDirectories: true)
        // Render at 2x for retina displays.
        let scale = 2.0
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
                                         pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return }
        rep.size = image.size
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        try rep.representation(using: .jpeg, properties: [.compressionFactor: 0.88])!.write(to: Self.output.appendingPathComponent("\(name).jpg"))
    }

    static func wallpaper(_ rect: NSRect) {
        NSGradient(colors: [NSColor(red: 0.20, green: 0.16, blue: 0.45, alpha: 1),
                            NSColor(red: 0.10, green: 0.25, blue: 0.48, alpha: 1),
                            NSColor(red: 0.05, green: 0.38, blue: 0.45, alpha: 1)])!.draw(in: rect, angle: -30)
        for (x, y, r, color) in [(0.15, 0.85, 0.45, NSColor.systemPink), (0.9, 0.1, 0.5, NSColor.systemTeal)] {
            let centre = NSPoint(x: rect.width * x, y: rect.height * y)
            let radius = max(rect.width, rect.height) * r
            NSGradient(colors: [color.withAlphaComponent(0.35), color.withAlphaComponent(0)])!
                .draw(fromCenter: centre, radius: 0, toCenter: centre, radius: radius, options: [])
        }
    }

    static func drawText(_ text: String, at point: NSPoint, size: Double, color: NSColor, centred: Bool,
                         bold: Bool = false, background: Bool = false) {
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .medium), .foregroundColor: color])
        let textSize = string.size()
        let origin = NSPoint(x: centred ? point.x - textSize.width / 2 : point.x, y: point.y - textSize.height / 2)
        if background {
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(origin: origin, size: textSize).insetBy(dx: -6, dy: -2), xRadius: 5, yRadius: 5).fill()
        }
        string.draw(at: origin)
    }

    /// A made-up landscape (no personal photos in the README).
    static func samplePhoto() throws -> URL {
        let width = 1800, height = 1200
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.40, alpha: 1),
                            NSColor(red: 0.55, green: 0.42, blue: 0.75, alpha: 1),
                            NSColor(red: 0.18, green: 0.24, blue: 0.52, alpha: 1)])!.draw(in: rect, angle: 90)
        NSColor(red: 1, green: 0.85, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 1150, y: 520, width: 260, height: 260)).fill()
        for (index, shade) in [0.30, 0.20, 0.12].enumerated() {
            let path = NSBezierPath()
            let base = Double(index) * 140
            path.move(to: NSPoint(x: 0, y: 0))
            path.line(to: NSPoint(x: 0, y: 420 - base))
            for step in 0...12 {
                let x = Double(step) * 150
                path.line(to: NSPoint(x: x, y: 380 - base + (step % 2 == 0 ? 120 : -40) + Double(index) * 30))
            }
            path.line(to: NSPoint(x: Double(width), y: 0))
            path.close()
            NSColor(red: shade, green: shade * 0.9, blue: shade * 1.6, alpha: 1).setFill()
            path.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Sunset.jpg")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        CGImageDestinationFinalize(destination)
        return url
    }
}
