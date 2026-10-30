// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MessEarthKit",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "MessEarthKit", targets: ["MessEarthKit"]),
        .executable(name: "MessEarthKitIntegrationProbe", targets: ["MessEarthKitIntegrationProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/warrenm/GLTFKit2.git", exact: "0.5.15"),
        .package(url: "https://github.com/warrenm/DracoSwift.git", exact: "1.5.7"),
    ],
    targets: [
        .target(
            name: "EarthDracoBridge",
            dependencies: [.product(name: "GLTFKit2", package: "GLTFKit2"), .product(name: "DracoSwift", package: "DracoSwift")]
        ),
        .target(name: "MessEarthKit", dependencies: ["EarthDracoBridge", .product(name: "GLTFKit2", package: "GLTFKit2")], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "MessEarthKitTests", dependencies: ["MessEarthKit"], resources: [.copy("Fixtures")]),
        // Compile actual app storage/workflow/renderer sources for headless verification,
        // without exposing app types from the public SDK or launching its UI.
        .testTarget(
            name: "MessEarthKitAppFilesTests",
            dependencies: ["MessEarthKit"],
            path: "MessEarthKit/MessEarthKit",
            exclude: ["Assets.xcassets", "Presentation", "Rendering/EarthPreviewView.swift", "Services", "MessEarthKitApp.swift"],
            sources: ["Storage", "Workflow", "Rendering/EarthPreviewResources.swift", "Rendering/EarthPreviewSceneBuilder.swift", "Rendering/EarthRegionPreviewLoader.swift", "Rendering/EarthPreviewRenderer.swift", "Rendering/EarthGLBThumbnailRenderer.swift"],
            resources: [.copy("Rendering/EarthPreviewShaders.metal")]
        ),
        .executableTarget(
            name: "MessEarthKitIntegrationProbe",
            dependencies: ["MessEarthKit"],
            path: "Tools/IntegrationProbe",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6],
    cxxLanguageStandard: .cxx17
)
