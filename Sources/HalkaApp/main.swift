import AppKit

// NSApplication delegate'i zayıf tutar; uygulama boyunca yaşaması için burada saklanıyor.
let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
// Dock'ta ve ⌘⇥'de görünmez; sadece menü çubuğu. Paketli sürümde Info.plist'teki LSUIElement aynı işi yapar,
// bu satır `swift run` ile çalışırken de aynı davranışı verir.
app.setActivationPolicy(.accessory)
app.run()
