// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DragConvert",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DragConvert", targets: ["DragConvertApp"]),
    ],
    targets: [
        // Saf mantık: format kayıt defteri, iş planlama, motorlar. AppKit yok.
        .target(name: "DragConvertCore"),
        // Sürükleme algılama; halka geometrisi ve tetik durum makinesi saf Swift.
        .target(name: "DragConvertDrag", dependencies: ["DragConvertCore"]),
        // Pencereler ve görünümler (AppKit + SwiftUI).
        .target(name: "DragConvertUI", dependencies: ["DragConvertCore", "DragConvertDrag"]),
        // Giriş noktası, menü çubuğu.
        .executableTarget(name: "DragConvertApp", dependencies: ["DragConvertCore", "DragConvertDrag", "DragConvertUI"]),
        .testTarget(name: "DragConvertCoreTests", dependencies: ["DragConvertCore"]),
        .testTarget(name: "DragConvertDragTests", dependencies: ["DragConvertDrag"]),
        // README images: RENDER_SCREENSHOTS=1 swift test --filter Screenshots (skipped otherwise).
        .testTarget(name: "DragConvertUITests", dependencies: ["DragConvertUI", "DragConvertCore", "DragConvertDrag"]),
    ]
)
