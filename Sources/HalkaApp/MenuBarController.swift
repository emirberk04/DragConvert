import AppKit
import HalkaCore
import HalkaUI

/// Menü çubuğundaki simge ve menüsü.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var settings = SettingsWindowController()
    private let recentsMenu = NSMenu()
    private let progressItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let hintItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var cancelItem = item(L("Stop", "Durdur"), #selector(cancelJobs))
    /// Süren işleri durdurmak için.
    var onCancel: (() -> Void)?
    /// En yeni başta; ayarlarda saklanır, silinmiş dosyalar açılışta düşer.
    private var recents: [URL] = Preferences.recents
    private static let recentLimit = 10

    override init() {
        super.init()
        statusItem.menu = makeMenu()
        setProgress(nil)
        rebuildRecents()
    }

    /// İş sürerken simge değişir ve menünün başında yüzde ile "Durdur" görünür. `nil` = iş yok.
    func setProgress(_ fraction: Double?) {
        let busy = fraction != nil
        progressItem.isHidden = !busy
        cancelItem.isHidden = !busy
        if let fraction {
            progressItem.title = L("Working… \(Int((fraction * 100).rounded()))%", "Dönüştürülüyor… %\(Int((fraction * 100).rounded()))")
        }
        guard let button = statusItem.button else { return }
        let name = busy ? "circle.dotted.circle" : "circle.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: busy ? "Halka çalışıyor" : "Halka")
            ?? NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Halka")
        button.image?.isTemplate = true
    }

    func addRecent(_ urls: [URL]) {
        recents.removeAll { urls.contains($0) }
        recents.insert(contentsOf: urls.reversed(), at: 0)
        recents = Array(recents.prefix(Self.recentLimit))
        Preferences.recents = recents
        rebuildRecents()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        progressItem.isEnabled = false
        menu.addItem(progressItem)
        menu.addItem(cancelItem)

        hintItem.isEnabled = false
        menu.addItem(hintItem)
        menu.delegate = self

        let recentsItem = NSMenuItem(title: L("Recent Files", "Son dönüşümler"), action: nil, keyEquivalent: "")
        recentsItem.submenu = recentsMenu
        menu.addItem(recentsItem)

        menu.addItem(item(L("Show Shelf", "Rafı göster"), #selector(toggleShelf)))
        menu.addItem(.separator())
        menu.addItem(item(L("Settings…", "Ayarlar…"), #selector(openSettings), key: ","))
        menu.addItem(item(L("About Halka", "Halka Hakkında"), #selector(openAbout)))
        menu.addItem(.separator())
        menu.addItem(item(L("Quit Halka", "Halka'dan Çık"), #selector(quit), key: "q"))
        return menu
    }

    /// İpucu ayarlardaki tuşu göstersin.
    func menuWillOpen(_ menu: NSMenu) {
        let symbols = ["shift": "⇧", "option": "⌥", "control": "⌃"]
        if let key = symbols[Preferences.modifier(for: .convert)] {
            hintItem.title = L("Drag a file and press \(key)", "Bir dosyayı sürüklerken \(key) tuşuna basın")
        } else {
            hintItem.title = L("Drag a file and press a trigger key", "Bir dosyayı sürükleyip tetik tuşuna basın")
        }
    }

    private func rebuildRecents() {
        recentsMenu.removeAllItems()
        guard !recents.isEmpty else {
            let empty = NSMenuItem(title: L("Nothing yet", "Henüz yok"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentsMenu.addItem(empty)
            return
        }
        for url in recents {
            let entry = item(url.lastPathComponent, #selector(revealRecent(_:)))
            entry.representedObject = url
            entry.toolTip = url.path
            entry.image = NSWorkspace.shared.icon(forFile: url.path)
            entry.image?.size = NSSize(width: 16, height: 16)
            recentsMenu.addItem(entry)
        }
        recentsMenu.addItem(.separator())
        recentsMenu.addItem(item(L("Clear List", "Listeyi temizle"), #selector(clearRecents)))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func toggleShelf() {
        ShelfController.shared.toggle()
    }

    @objc private func cancelJobs() {
        onCancel?()
    }

    @objc private func clearRecents() {
        recents.removeAll()
        Preferences.recents = []
        rebuildRecents()
    }

    @objc private func openSettings() {
        settings.present()
    }

    @objc private func openAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Halka",
            .applicationVersion: Halka.version,
            .credits: NSAttributedString(string: L("Convert, edit and share files from the drag itself.", "Finder'dan çıkmadan dosya dönüştürücü. Kişisel kullanım için.")),
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
