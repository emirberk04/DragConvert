import Foundation
import Testing
@testable import DragConvertCore

struct OutputLocationTests {
    @Test func ordinaryFolderWritesBeside() {
        let file = URL(fileURLWithPath: "/Users/test/Desktop/video.mov")
        #expect(OutputLocation.directory(for: file, isPackage: { _ in false }) == nil)
    }

    @Test func photosLibraryGoesToDownloads() {
        let thumbnail = URL(fileURLWithPath:
            "/Users/test/Pictures/Photos Library.photoslibrary/resources/derivatives/0/ABC_1_102_o.jpeg")
        #expect(OutputLocation.directory(for: thumbnail) == OutputLocation.downloads)
    }

    @Test func anyPackageAncestorCounts() {
        let inside = URL(fileURLWithPath: "/Applications/Foo.app/Contents/Resources/icon.png")
        #expect(OutputLocation.directory(for: inside) == OutputLocation.downloads)
    }

    @Test func convertsIntoChosenDirectory() async throws {
        let source = try ConverterTests().makePNG("kaynak.png")
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("DragConvertOut-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let outcomes = await Converter.run(.convert([source], to: FormatRegistry.shared.format(id: "jpg")!),
                                           outputDirectory: target)
        #expect(outcomes.first?.outputs.first?.deletingLastPathComponent().standardizedFileURL
                == target.standardizedFileURL)
    }
}

struct PreferredOutputTests {
    @Test func chosenFolderWinsOverEverything() {
        let folder = URL(fileURLWithPath: "/Users/test/Çıktılar", isDirectory: true)
        let source = URL(fileURLWithPath: "/Users/test/Pictures/Photos Library.photoslibrary/x/a.jpeg")
        #expect(OutputLocation.directory(for: source, preferred: folder) == folder)
        #expect(OutputLocation.directory(for: URL(fileURLWithPath: "/tmp/a.png"), preferred: folder) == folder)
    }
}
