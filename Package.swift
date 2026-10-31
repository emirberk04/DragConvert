// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Halka",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Halka", targets: ["HalkaApp"]),
    ],
    targets: [
        // Saf mantık: format kayıt defteri, iş planlama, motorlar. AppKit yok.
        .target(name: "HalkaCore"),
        // Sürükleme algılama; halka geometrisi ve tetik durum makinesi saf Swift.
        .target(name: "HalkaDrag", dependencies: ["HalkaCore"]),
        // Pencereler ve görünümler (AppKit + SwiftUI).
        .target(name: "HalkaUI", dependencies: ["HalkaCore", "HalkaDrag"]),
        // Giriş noktası, menü çubuğu.
        .executableTarget(name: "HalkaApp", dependencies: ["HalkaCore", "HalkaDrag", "HalkaUI"]),
        .testTarget(name: "HalkaCoreTests", dependencies: ["HalkaCore"]),
        .testTarget(name: "HalkaDragTests", dependencies: ["HalkaDrag"]),
        // README images: RENDER_SCREENSHOTS=1 swift test --filter Screenshots (skipped otherwise).
        .testTarget(name: "HalkaUITests", dependencies: ["HalkaUI", "HalkaCore", "HalkaDrag"]),
    ]
)
