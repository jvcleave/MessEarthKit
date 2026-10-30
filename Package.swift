// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MessEarthKit",
    platforms: [.macOS("15.6")],
    products: [
        .library(name: "MessEarthKit", targets: ["MessEarthKit"]),
        .executable(name: "MessEarthKitIntegrationProbe", targets: ["MessEarthKitIntegrationProbe"]),
    ],
    targets: [
        .binaryTarget(name: "GLTFKit2", path: "ThirdParty/Artifacts/GLTFKit2.xcframework"),
        .binaryTarget(name: "Draco", path: "ThirdParty/Artifacts/Draco.xcframework"),
        .target(
            name: "EarthDracoBridge",
            dependencies: ["GLTFKit2", "Draco"]
        ),
        .target(name: "MessEarthKit", dependencies: ["EarthDracoBridge", "GLTFKit2"], linkerSettings: [.linkedLibrary("sqlite3")]),
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
