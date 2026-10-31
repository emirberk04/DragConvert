import AppKit
import HalkaCore
import ServiceManagement
import SwiftUI
import UserNotifications

/// Ayarlar penceresi. Tek örnek; kapatılınca gizlenir, tekrar açılınca öne gelir.
@MainActor
public final class SettingsWindowController: NSWindowController {
    public convenience init() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
        window.title = L("Halka Settings", "Halka Ayarları")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        self.init(window: window)
    }

    public func present() {
        // Dock'ta olmayan (accessory) bir uygulama pencereyi ancak kendini etkinleştirirse öne getirebilir.
        NSApp.activate()
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    /// Fixed values for the README images (the test bundle has no version and no bundled ffmpeg).
    var previewVersion: String?
    var previewFFmpeg: String?

    // Anahtarlar `Preferences.Key` ile aynı; ikisi aynı UserDefaults'u okur.
    @AppStorage("convertModifier") private var convertModifier = "shift"
    @AppStorage("toolsModifier") private var toolsModifier = "option"
    @AppStorage("actionsModifier") private var actionsModifier = "control"
    @AppStorage("outputFolder") private var outputFolder = ""
    @AppStorage("imageQuality") private var imageQuality = 0.9
    @AppStorage("terminal") private var terminal = ""
    @AppStorage("ffmpegFolder") private var ffmpegFolder = ""
    @AppStorage("notifyWhenDone") private var notifyWhenDone = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private let modifiers = [("shift", L("⇧ Shift", "⇧ Shift")), ("option", "⌥ Option"), ("control", "⌃ Control"), ("none", "Kapalı")]
    private let terminals = [("dev.warp.Warp-Stable", "Warp"), ("com.googlecode.iterm2", "iTerm2"), ("com.apple.Terminal", "Terminal")]
        .filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.0) != nil }

    private var clash: Bool {
        let used = [convertModifier, toolsModifier, actionsModifier].filter { $0 != "none" }
        return Set(used).count != used.count
    }

    var body: some View {
        Form {
            Section(L("Key to hold while dragging", "Sürüklerken basılan tuş")) {
                modifierPicker(L("Convert", "Dönüştür"), $convertModifier)
                modifierPicker(L("Tools", "Araçlar"), $toolsModifier)
                modifierPicker(L("Actions", "İşlemler"), $actionsModifier)
                if clash {
                    Label(L("The same key is used twice; Convert, Tools, Actions take priority in that order.", "Aynı tuş iki halkaya atanmış; öncelik Dönüştür, Araçlar, İşlemler sırasıyla."),
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                }
            }

            Section(L("Output", "Çıktı")) {
                Picker(L("Save results", "Dosyalar nereye yazılsın"), selection: Binding(
                    get: { outputFolder.isEmpty ? 0 : 1 },
                    set: { if $0 == 0 { outputFolder = "" } else { chooseFolder { outputFolder = $0.path } } })) {
                    Text(L("Next to the original", "Kaynağın yanına")).tag(0)
                    Text(L("In a chosen folder", "Seçilen klasöre")).tag(1)
                }
                if !outputFolder.isEmpty {
                    LabeledContent(L("Folder", "Klasör")) {
                        HStack {
                            Text((outputFolder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                            Button(L("Change…", "Değiştir…")) { chooseFolder { outputFolder = $0.path } }
                        }
                    }
                }
                Text(L("Files dragged from Photos go to Downloads unless a folder is chosen. Existing files are never overwritten.", "Galeriden gelen dosyalar, klasör seçilmemişse İndirilenler'e yazılır. Var olan dosyanın üzerine asla yazılmaz."))
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent(L("Image quality", "Görüntü kalitesi")) {
                    HStack {
                        Slider(value: $imageQuality, in: 0.5...1, step: 0.05).frame(width: 160)
                        Text(L("\(Int((imageQuality * 100).rounded()))%", "%\(Int((imageQuality * 100).rounded()))")).monospacedDigit().frame(width: 40, alignment: .trailing)
                    }
                }
            }

            Section(L("Actions", "İşlemler")) {
                Picker("Terminal", selection: $terminal) {
                    Text(L("Automatic", "Otomatik")).tag("")
                    ForEach(terminals, id: \.0) { Text($0.1).tag($0.0) }
                }
                LabeledContent("ffmpeg") {
                    HStack {
                        Text(ffmpegLabel).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button(L("Choose…", "Seç…")) { chooseFolder { ffmpegFolder = $0.path } }
                        if !ffmpegFolder.isEmpty { Button(L("Reset", "Sıfırla")) { ffmpegFolder = "" } }
                    }
                }
                if !ffmpegFolder.isEmpty {
                    Text(L("The ffmpeg change takes effect after restarting Halka.", "ffmpeg değişikliği Halka yeniden açılınca geçerli olur.")).font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("General", "Genel")) {
                Toggle(L("Launch at login", "Mac açılınca başlat"), isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Toggle(L("Notify when a job finishes", "İş bitince bildirim göster"), isOn: Binding(get: { notifyWhenDone }, set: setNotify))
                LabeledContent(L("Version", "Sürüm"), value: previewVersion ?? Halka.version)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var ffmpegLabel: String {
        if let previewFFmpeg { return previewFFmpeg }
        if !ffmpegFolder.isEmpty { return (ffmpegFolder as NSString).abbreviatingWithTildeInPath }
        guard let found = FormatRegistry.shared.ffmpeg?.ffmpeg else { return L("Not found", "Bulunamadı") }
        return found.path.contains(".app/Contents/Helpers") ? L("Using the bundled one", "Pakettekini kullanıyor") : (found.path as NSString).abbreviatingWithTildeInPath
    }

    private func modifierPicker(_ title: String, _ value: Binding<String>) -> some View {
        Picker(title, selection: value) {
            ForEach(modifiers, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func chooseFolder(_ done: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = L("Choose", "Seç")
        if panel.runModal() == .OK, let url = panel.url { done(url) }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = L("Could not change this: \(error.localizedDescription). You can also add Halka in System Settings › General › Login Items.", "Ayarlanamadı: \(error.localizedDescription). Sistem Ayarları › Genel › Giriş Öğeleri'nden de eklenebilir.")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval {
            loginError = L("Allow Halka in System Settings › General › Login Items.", "Sistem Ayarları › Genel › Giriş Öğeleri'nden Halka'ya izin verin.")
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    private func setNotify(_ enabled: Bool) {
        notifyWhenDone = enabled
        guard enabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { DispatchQueue.main.async { notifyWhenDone = false } }
        }
    }
}
