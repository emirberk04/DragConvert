import Foundation
import Testing
@testable import DragConvertCore

struct OutputNamingTests {
    let source = URL(fileURLWithPath: "/Users/test/Desktop/foto.heic")

    @Test func writesBesideSourceWithNewExtension() {
        let url = OutputNaming.destination(for: source, pathExtension: "jpg", exists: { _ in false })
        #expect(url.path == "/Users/test/Desktop/foto.jpg")
    }

    @Test func numbersWhenNameIsTaken() {
        let taken: Set<String> = ["/Users/test/Desktop/foto.jpg", "/Users/test/Desktop/foto 2.jpg"]
        let url = OutputNaming.destination(for: source, pathExtension: "jpg", exists: { taken.contains($0.path) })
        #expect(url.path == "/Users/test/Desktop/foto 3.jpg")
    }

    @Test func neverReturnsTheSourceItself() {
        // Aynı formata işlem (ör. sıkıştırma) kaynağın üzerine yazmamalı, kaynak diskte görünmese bile.
        let jpg = URL(fileURLWithPath: "/Users/test/Desktop/foto.jpg")
        let url = OutputNaming.destination(for: jpg, pathExtension: "jpg", exists: { _ in false })
        #expect(url.path == "/Users/test/Desktop/foto 2.jpg")
    }

    @Test func honoursOutputDirectory() {
        let folder = URL(fileURLWithPath: "/Users/test/Converted", isDirectory: true)
        let url = OutputNaming.destination(for: source, pathExtension: "png", in: folder, exists: { _ in false })
        #expect(url.path == "/Users/test/Converted/foto.png")
    }

    @Test func keepsDotsInStem() {
        let dotted = URL(fileURLWithPath: "/tmp/rapor.v2.final.pdf")
        let url = OutputNaming.destination(for: dotted, pathExtension: "png", exists: { _ in false })
        #expect(url.lastPathComponent == "rapor.v2.final.png")
    }

    @Test func emptyExtensionGivesBareName() {
        let zip = URL(fileURLWithPath: "/tmp/arsiv.zip")
        let url = OutputNaming.destination(for: zip, pathExtension: "", exists: { _ in false })
        #expect(url.lastPathComponent == "arsiv")
    }
}
