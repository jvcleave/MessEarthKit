import Foundation
import MessEarthKit
import SwiftUI

struct EarthCaptureEstimateRow: Identifiable
{
    let id: String
    let value: String
    let exceedsLimit: Bool
}

/// Cached by the presentation owner when results or budgets change.
struct EarthCapturePrecheckDisplay
{
    let rows: [EarthCaptureEstimateRow]
    let detail: String
    let allowsCapture: Bool

    init(precheck: EarthCapturePrecheck, request: EarthCaptureRequest, limits: EarthImportLimits)
    {
        let prefix = precheck.selectionIsComplete ? "" : "≥ "
        var rows = [
            EarthCaptureEstimateRow(id: "Selected tiles", value: "\(prefix)\(precheck.selectedTileCount) / \(request.maximumSelectedTiles)", exceedsLimit: precheck.selectedTileCount > request.maximumSelectedTiles),
            EarthCaptureEstimateRow(id: "Planned requests", value: "\(prefix)\(precheck.plannedSourceRequests) / \(request.maximumSourceRequests)", exceedsLimit: precheck.plannedSourceRequests > request.maximumSourceRequests),
            EarthCaptureEstimateRow(id: "JSON / unique GLBs", value: "\(precheck.metadataRequests) / \(precheck.uniquePayloadCount)", exceedsLimit: false),
            EarthCaptureEstimateRow(id: "Source bytes read", value: "\(Self.bytes(precheck.downloadedBytes)) / \(Self.bytes(limits.maximumSourceBytes))", exceedsLimit: precheck.downloadedBytes > limits.maximumSourceBytes),
        ]
        if let geometry = precheck.geometry
        {
            rows += [
                EarthCaptureEstimateRow(id: "Estimated vertices", value: "\(geometry.vertexCount) / \(limits.maximumVertices)", exceedsLimit: geometry.vertexCount > limits.maximumVertices),
                EarthCaptureEstimateRow(id: "Geometry buffers", value: Self.bytes(geometry.geometryBufferBytes), exceedsLimit: false),
                EarthCaptureEstimateRow(id: "Texture RGBA", value: "\(Self.bytes(geometry.decodedTextureBytes)) / \(Self.bytes(limits.maximumDecodedTextureBytes))", exceedsLimit: geometry.decodedTextureBytes > limits.maximumDecodedTextureBytes),
                EarthCaptureEstimateRow(id: "Largest texture edge", value: "\(geometry.largestTextureDimension) / \(limits.maximumTextureDimension) px", exceedsLimit: geometry.largestTextureDimension > limits.maximumTextureDimension),
            ]
        }
        else { rows.append(EarthCaptureEstimateRow(id: "Geometry", value: "Not inspected", exceedsLimit: false)) }
        self.rows = rows
        allowsCapture = precheck.selectionIsComplete && precheck.interruptionReason == nil && !rows.contains(where: \.exceedsLimit)
        if let interruption = precheck.interruptionReason
        { detail = "Selection incomplete; counts are lower bounds. \(interruption)" }
        else if !precheck.hasReusableSources
        { detail = "Adjust request/tile limits and use Inspect via API again to inspect geometry. Metadata discovery uses API requests." }
        else if !allowsCapture
        { detail = "Estimates exceed the current limits. Adjust limits to reuse these downloaded sources for Capture." }
        else
        { detail = "Sources ready to reuse for Capture. Full import validation still runs. Buffer estimates exclude peak memory, mipmaps, and GPU copies." }
    }

    init(invalidLimits: String)
    {
        rows = []
        detail = invalidLimits
        allowsCapture = false
    }

    private static func bytes(_ value: Int) -> String
    {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}

struct EarthCaptureEstimateView: View
{
    let title: String
    let rows: [EarthCaptureEstimateRow]
    let detail: String

    var body: some View
    {
        VStack(alignment: .leading, spacing: 6)
        {
            Text(title).font(.callout.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), alignment: .leading)], alignment: .leading, spacing: 8)
            {
                ForEach(rows)
                { row in
                    VStack(alignment: .leading, spacing: 2)
                    {
                        Text(row.id).foregroundStyle(.secondary)
                        Text(row.value).monospacedDigit().foregroundStyle(row.exceedsLimit ? .orange : .primary)
                    }
                }
            }
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
    }
}
