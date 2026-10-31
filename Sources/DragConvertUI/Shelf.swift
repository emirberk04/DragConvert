import AppKit
import DragConvertCore
import SwiftUI
import UniformTypeIdentifiers

/// Raf: dosyaları, gidecekleri yeri bulana kadar bekletmek için küçük, her şeyin üstünde duran pencere.
///
/// Odak çalmaz (altındaki uygulama imlecini ve seçimini korur), bütün Space'lerde görünür. Dosya içeri
/// sürüklenir veya ⌃ halkasından eklenir, istenen yere dışarı sürüklenir. Kapatınca boşalır: bir klasör değil,
/// geçici bir bekleme yeri. Dosyalar taşınmaz; raf sadece onlara işaret eder.
@MainActor
public final class ShelfController {
    public static let shared = ShelfController()

    private let model = ShelfModel()
    private lazy var panel = makePanel()
    private let delegate = ShelfWindowDelegate()

    public func add(_ urls: [URL]) {
        model.add(urls)
        show()
    }

    public func show() {
        if !panel.isVisible {
            // İlk açılışta imlecin yanında; sonra kullanıcının bıraktığı yerde.
            if panel.frame.origin == .zero {
                let mouse = NSEvent.mouseLocation
                panel.setFrameTopLeftPoint(NSPoint(x: mouse.x + 24, y: mouse.y + 24))
            }
            panel.orderFrontRegardless()
        }
    }

    public func toggle() {
        panel.isVisible ? panel.close() : show()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: true)
        panel.title = L("Shelf", "Raf")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        let hosting = NSHostingView(rootView: ShelfView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentView = hosting
        delegate.onClose = { [model] in model.clear() }
        panel.delegate = delegate
        return panel
    }
}

private final class ShelfWindowDelegate: NSObject, NSWindowDelegate {
    var onClose: (() -> Void)?
    func windowWillClose(_ notification: Notification) { onClose?() }
}

@MainActor
final class ShelfModel: ObservableObject {
    @Published private(set) var files: [URL] = []

    func add(_ urls: [URL]) {
        for url in urls where !files.contains(url) { files.append(url) }
    }

    func remove(_ url: URL) { files.removeAll { $0 == url } }
    func clear() { files.removeAll() }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @State private var targeted = false

    /// Bu kadar satıra kadar büyür, sonra kaydırılır.
    private let visibleRows = 10

    var body: some View {
        VStack(spacing: 0) {
            if model.files.isEmpty {
                Text(L("Drop files here", "Dosyaları buraya sürükleyin"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 70)
            } else {
                if model.files.count > 1 {
                    Label(L("Drag all (\(model.files.count))", "Hepsini sürükle (\(model.files.count))"), systemImage: "square.stack.3d.up")
                        .font(.callout)
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.12)))
                        .overlay(MultiFileDragSource(urls: model.files))
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                        .help(L("Drag every file on the shelf at once", "Raftaki bütün dosyaları birlikte sürükleyin"))
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.files, id: \.self) { url in
                            ShelfRow(url: url) { model.remove(url) }
                        }
                    }
                    .padding(6)
                }
                .frame(height: CGFloat(min(model.files.count, visibleRows)) * 34 + 12)
            }
        }
        .padding(.top, 28)
        .frame(width: 260)
        .background(targeted ? Color.accentColor.opacity(0.12) : .clear)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in model.add([url]) }
                }
            }
            return true
        }
    }
}

struct ShelfRow: View {
    let url: URL
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().frame(width: 24, height: 24)
            Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(L("Remove from the shelf (the file is not deleted)", "Raftan kaldır (dosya silinmez)"))
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider(object: url as NSURL) }
    }
}

/// Birden çok dosyayı tek sürüklemede taşıyan AppKit kaynağı (SwiftUI `onDrag` tek öğe taşır).
struct MultiFileDragSource: NSViewRepresentable {
    let urls: [URL]

    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ view: DragSourceView, context: Context) { view.urls = urls }

    final class DragSourceView: NSView, NSDraggingSource {
        var urls: [URL] = []

        // Raf odak almayan bir panel; ilk tıklama da sürüklemeyi başlatabilsin.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {}

        override func mouseDragged(with event: NSEvent) {
            let origin = convert(event.locationInWindow, from: nil)
            let items = urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: 32, height: 32)
                // Simgeler hafifçe kaydırılmış bir deste gibi.
                let offset = Double(min(index, 4)) * 4
                item.setDraggingFrame(NSRect(x: origin.x - 16 + offset, y: origin.y - 16 - offset, width: 32, height: 32),
                                      contents: icon)
                return item
            }
            beginDraggingSession(with: items, event: event, source: self)
        }

        func draggingSession(_ session: NSDraggingSession,
                             sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .move, .generic] : []
        }
    }
}
