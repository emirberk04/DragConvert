// Halka'nın uygulama ikonunu çizer: 1024 px PNG.
//   swift scripts/make-icon.swift <çıktı.png>
// build-app.sh bundan .icns üretir (sips + iconutil). Tasarım: koyu çivit zemin, ortada nokta, etrafında
// boşluklu altı dilimlik halka; biri vurgulu (seçilen hedef).
import AppKit

let size = 1024.0
let output = URL(fileURLWithPath: CommandLine.arguments[1])

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    // macOS ikon ızgarası: 824 px'lik yuvarlak kare, kenarda 100 px boşluk.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSGradient(colors: [NSColor(red: 0.33, green: 0.30, blue: 0.95, alpha: 1),
                        NSColor(red: 0.16, green: 0.12, blue: 0.45, alpha: 1)])!.draw(in: shape, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    let centre = NSPoint(x: 512, y: 512)
    let inner = 150.0, outer = 300.0, count = 6, gap = 7.0
    for index in 0..<count {
        let step = 360.0 / Double(count)
        let mid = 90.0 - Double(index) * step
        let path = NSBezierPath()
        path.appendArc(withCenter: centre, radius: outer, startAngle: mid + step / 2 - gap, endAngle: mid - step / 2 + gap, clockwise: true)
        path.appendArc(withCenter: centre, radius: inner, startAngle: mid - step / 2 + gap * 2, endAngle: mid + step / 2 - gap * 2, clockwise: false)
        path.close()
        (index == 1 ? NSColor(red: 1, green: 0.78, blue: 0.30, alpha: 1) : NSColor.white.withAlphaComponent(0.88)).setFill()
        path.fill()
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: centre.x - 46, y: centre.y - 46, width: 92, height: 92)).fill()
    return true
}

guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("ikon çizilemedi") }
try png.write(to: output)
