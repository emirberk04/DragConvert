import Foundation
import Testing
@testable import DragConvertCore

struct FormatRegistryTests {
    /// ImageIO'ya bağlı olmayan, sabit yeteneklerle bir kayıt defteri: WebP okunur ama yazılamaz.
    let registry = FormatRegistry(
        readable: ["public.jpeg", "public.png", "public.heic", "org.webmproject.webp"],
        writable: ["public.jpeg", "public.png", "public.heic"]
    )

    func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func detectsByExtensionCaseInsensitively() {
        #expect(registry.format(for: url("a.JPEG"))?.id == "jpg")
        #expect(registry.format(for: url("a.tif"))?.id == "tiff")
        #expect(registry.format(for: url("a.unknown")) == nil)
    }

    @Test func imageTargetsExcludeSelfAndUnwritable() {
        let ids = registry.targets(from: registry.format(id: "webp")!).map(\.id)
        #expect(ids == ["jpg", "png", "heic", "pdf"])
    }

    @Test func unreadableSourceHasNoTargets() {
        #expect(registry.targets(from: registry.format(id: "avif")!).isEmpty)
    }

    @Test func pdfBecomesImages() {
        #expect(registry.targets(from: registry.format(id: "pdf")!).map(\.id) == ["png", "jpg", "heic", "txt"])
    }

    @Test func mixedSelectionOffersEachOthersFormat() {
        // JPG + PNG → PNG de hedef ("hepsi PNG olsun"), JPG de.
        let ids = registry.commonTargets(for: [url("a.jpg"), url("b.png")]).map(\.id)
        #expect(ids == ["png", "heic", "pdf", "jpg"])
    }

    @Test func sameFormatSelectionHidesThatFormat() {
        let ids = registry.commonTargets(for: [url("a.png"), url("b.PNG")]).map(\.id)
        #expect(!ids.contains("png"))
    }

    @Test func unknownFileEmptiesTheRing() {
        #expect(registry.commonTargets(for: [url("a.png"), url("b.zip")]).isEmpty)
    }

    @Test func systemRegistryCanWriteTheBasics() {
        let system = FormatRegistry.shared
        for id in ["jpg", "png", "heic", "tiff"] {
            #expect(system.canWrite(system.format(id: id)!), "\(id) yazılamıyor")
        }
    }
}
