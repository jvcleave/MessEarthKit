import Foundation
import MessEarthKit

/// Delivery choices share channel settings and keep optimization explicit.
enum EarthExportFormat: String, CaseIterable, Identifiable, Sendable
{
    case glb = "GLB"
    case optimizedGLB = "Optimized GLB"
    case usdz = "USDZ"
    case optimizedUSDZ = "Optimized USDZ"

    var id: Self { self }
    var isGLB: Bool { self == .glb || self == .optimizedGLB }
    var isOptimized: Bool { self == .optimizedGLB || self == .optimizedUSDZ }
    var fileExtension: String { isGLB ? "glb" : "usdz" }
}

struct EarthExportOptimizationSettings: Equatable, Sendable
{
    var triangleFraction = 0.5
    var maximumErrorMeters = 0.1
    var maximumTextureDimension: Int?

    func meshProfile() throws -> EarthMeshOptimizationProfile
    { try EarthMeshOptimizationProfile(triangleFraction: Float(triangleFraction), maximumErrorMeters: Float(maximumErrorMeters)) }

    func profile() throws -> EarthUSDZOptimizationProfile
    {
        try EarthUSDZOptimizationProfile(triangleFraction: Float(triangleFraction), maximumErrorMeters: Float(maximumErrorMeters), maximumTextureDimension: maximumTextureDimension)
    }
}
