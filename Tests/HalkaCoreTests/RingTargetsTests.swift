import Foundation
import Testing
@testable import HalkaCore

struct RingTargetsTests {
    func url(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name)") }

    @Test func kinds() {
        #expect(FileKind(url: url("a.HEIC")) == .image)
        #expect(FileKind(url: url("a.mov")) == .movie)
        #expect(FileKind(url: url("a.mp3")) == .audio)
        #expect(FileKind(url: url("a.pdf")) == .pdf)
        #expect(FileKind(url: url("a.xyz123")) == .other)
    }

    @Test func convertComesFromRegistry() {
        let ids = RingTargets.targets(for: .convert, files: [url("a.jpeg")]).map(\.id)
        #expect(!ids.contains("convert.jpg"))
        #expect(ids.contains("convert.png") && ids.contains("convert.pdf"))
    }

    @Test func actionsWorkOnAnything() {
        #expect(RingTargets.targets(for: .actions, files: [url("a.xyz123")]).count == 7)
        #expect(RingTargets.targets(for: .convert, files: [url("a.xyz123")]).isEmpty)
    }
}
