import AppKit
import HalkaCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuBar: MenuBarController?
    private let drag = DragCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menuBar = MenuBarController()
        self.menuBar = menuBar
        drag.onProgress = { [weak menuBar] fraction in menuBar?.setProgress(fraction) }
        menuBar.onCancel = { [weak drag] in drag?.cancelAll() }
        drag.onConverted = { [weak menuBar] urls in menuBar?.addRecent(urls) }
        drag.start()
        // ffmpeg'i bulmak ve kodlayıcılarını sormak bir alt süreç; ilk halka açılışını bekletmesin.
        Task.detached(priority: .utility) { _ = FormatRegistry.shared }
        Log.app.info("Halka \(Halka.version, privacy: .public) başladı")
    }
}
