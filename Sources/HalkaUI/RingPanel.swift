import AppKit
import HalkaCore
import HalkaDrag

/// İmlecin etrafında açılan halka. Odak çalmayan, tüm Space'lerde görünen şeffaf bir panel; içindeki
/// görünüm sürüklenen dosyaların bırakma hedefi olur, böylece bırakılan dilimi kaynak uygulama değil biz alırız.
@MainActor
public final class RingPanelController {
    /// Bir dilime bırakıldı.
    public var onSelect: ((_ target: RingTarget, _ payload: DropPayload) -> Void)?

    private let geometry = RingGeometry()
    private lazy var ringView = RingView(geometry: geometry)
    private lazy var panel = makePanel()

    public init() {}

    public var isVisible: Bool { panel.isVisible }

    /// Halkayı `point` (ekran koordinatı, alt-sol orijin) merkezli açar.
    public func show(mode: RingMode, targets: [RingTarget], fileCount: Int, at point: NSPoint) {
        update(mode: mode, targets: targets, fileCount: fileCount)
        let side = panel.frame.width
        panel.setFrameOrigin(NSPoint(x: (point.x - side / 2).rounded(), y: (point.y - side / 2).rounded()))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            panel.animator().alphaValue = 1
        }
    }

    /// Açıkken modu değiştirir; halka yerinde kalır.
    public func update(mode: RingMode, targets: [RingTarget], fileCount: Int) {
        ringView.mode = mode
        ringView.targets = targets
        ringView.fileCount = fileCount
        ringView.highlighted = nil
        ringView.onDrop = { [weak self] index, payload in
            guard let self, targets.indices.contains(index) else { return }
            self.onSelect?(targets[index], payload)
        }
    }

    public func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        ringView.highlighted = nil
    }

    private func makePanel() -> NSPanel {
        let side = (geometry.outerRadius + 14) * 2
        let frame = NSRect(x: 0, y: 0, width: side, height: side)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let container = NSView(frame: frame)
        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let radius = geometry.outerRadius + 6
        blur.maskImage = NSImage(size: frame.size, flipped: false) { rect in
            NSBezierPath(ovalIn: NSRect(x: rect.midX - radius, y: rect.midY - radius,
                                        width: radius * 2, height: radius * 2)).fill()
            return true
        }
        blur.autoresizingMask = [.width, .height]
        ringView.frame = frame
        ringView.autoresizingMask = [.width, .height]
        container.addSubview(blur)
        container.addSubview(ringView)
        panel.contentView = container
        return panel
    }
}

/// Dilimleri çizer ve sürükleme hedefi olarak davranır.
final class RingView: NSView {
    let geometry: RingGeometry
    var mode: RingMode = .convert { didSet { needsDisplay = true } }
    var targets: [RingTarget] = [] { didSet { needsDisplay = true } }
    var fileCount = 0 { didSet { needsDisplay = true } }
    var highlighted: Int? { didSet { if highlighted != oldValue { needsDisplay = true } } }
    var onDrop: ((Int, DropPayload) -> Void)?

    init(geometry: RingGeometry) {
        self.geometry = geometry
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) kullanılmıyor") }

    private var middle: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    private func index(at windowPoint: NSPoint) -> Int? {
        let point = convert(windowPoint, from: nil)
        return geometry.index(dx: point.x - middle.x, dy: point.y - middle.y, count: targets.count)
    }

    // MARK: Sürükleme hedefi

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        highlighted = index(at: sender.draggingLocation)
        // Ölü bölgede "bırakılamaz": orada bırakmak iptal, dosyaya hiçbir şey olmaz.
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        highlighted = nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let index = index(at: sender.draggingLocation) else { return false }
        let pasteboard = sender.draggingPasteboard
        // Sözü verilen dosyalar önce: Fotoğraflar yanına bir önizleme JPEG'inin yolunu da koyuyor, o değil.
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        if !receivers.isEmpty {
            onDrop?(index, PromisedFiles.receive(receivers))
            return true
        }
        let files = DragMonitor.fileURLs(on: pasteboard)
        guard !files.isEmpty else { return false }
        onDrop?(index, .files(files))
        return true
    }

    // MARK: Çizim

    override func draw(_ dirtyRect: NSRect) {
        let count = targets.count
        for (i, target) in targets.enumerated() {
            let selected = i == highlighted
            wedge(i, count: count).fill(with: selected
                ? NSColor.controlAccentColor
                : NSColor.labelColor.withAlphaComponent(0.08))
            drawLabel(target, at: geometry.center(of: i, count: count),
                      color: selected ? .white : .labelColor)
        }
        drawCentre()
    }

    private func wedge(_ index: Int, count: Int) -> NSBezierPath {
        let inner = geometry.innerRadius, outer = geometry.outerRadius
        let path = NSBezierPath()
        if count == 1 {
            path.appendOval(in: NSRect(x: middle.x - outer, y: middle.y - outer, width: outer * 2, height: outer * 2))
            path.appendOval(in: NSRect(x: middle.x - inner, y: middle.y - inner, width: inner * 2, height: inner * 2))
            path.windingRule = .evenOdd
            return path
        }
        // Geometri saat yönünde ve tepeden; NSBezierPath saat yönünün tersine ve +x'ten ölçer.
        let span = geometry.span(of: index, count: count)
        path.appendArc(withCenter: middle, radius: outer,
                       startAngle: 90 - span.start, endAngle: 90 - span.end, clockwise: true)
        path.appendArc(withCenter: middle, radius: inner,
                       startAngle: 90 - span.end, endAngle: 90 - span.start, clockwise: false)
        path.close()
        return path
    }

    private func drawLabel(_ target: RingTarget, at offset: (x: Double, y: Double), color: NSColor) {
        let point = NSPoint(x: middle.x + offset.x, y: middle.y + offset.y)
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        if let icon = NSImage(systemSymbolName: target.symbol, accessibilityDescription: target.label)?
            .withSymbolConfiguration(config) {
            let size = icon.size
            icon.draw(in: NSRect(x: point.x - size.width / 2, y: point.y + 2,
                                 width: size.width, height: size.height))
        }
        drawText(target.label, centredAt: NSPoint(x: point.x, y: point.y - 10),
                 font: .systemFont(ofSize: 11, weight: .medium), color: color)
    }

    private func drawCentre() {
        let subtitle = targets.isEmpty ? L("Nothing here", "Hedef yok") : (fileCount == 1 ? L("1 file", "1 dosya") : L("\(fileCount) files", "\(fileCount) dosya"))
        drawText(mode.title, centredAt: NSPoint(x: middle.x, y: middle.y + 7),
                 font: .systemFont(ofSize: 12, weight: .semibold), color: .labelColor)
        drawText(subtitle, centredAt: NSPoint(x: middle.x, y: middle.y - 8),
                 font: .systemFont(ofSize: 10), color: .secondaryLabelColor)
    }

    private func drawText(_ text: String, centredAt point: NSPoint, font: NSFont, color: NSColor) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let size = string.size()
        string.draw(at: NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
    }
}

private extension NSBezierPath {
    func fill(with color: NSColor) {
        color.setFill()
        fill()
    }
}
