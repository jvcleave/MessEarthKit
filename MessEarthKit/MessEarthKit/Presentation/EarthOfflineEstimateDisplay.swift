import Foundation
import MessEarthKit

struct EarthOfflineEstimateDisplay
{
    let rows: [EarthCaptureEstimateRow]
    let detail: String

    init(areaSquareMeters: Double?, limits: EarthImportLimits?, request: EarthCaptureRequest?, history: EarthCaptureObservationHistory)
    {
        var rows: [EarthCaptureEstimateRow] = []
        if let areaSquareMeters, areaSquareMeters.isFinite, areaSquareMeters > 0
        { rows.append(.init(id: "Requested area", value: String(format: "%.3f km²", areaSquareMeters / 1000000), exceedsLimit: false)) }
        if let limits
        {
            let budget = limits.maximumVertices.multipliedReportingOverflow(by: MemoryLayout<EarthVertex>.stride)
            if !budget.overflow { rows.append(.init(id: "Vertex buffer budget", value: Self.bytes(budget.partialValue), exceedsLimit: false)) }
            rows.append(.init(id: "Texture RGBA budget", value: Self.bytes(limits.maximumDecodedTextureBytes), exceedsLimit: false))
        }
        let estimate = request.map { EarthCaptureOfflineEstimate(request: $0, observations: history.observations) }
        if let estimate, estimate.sampleCount > 0, let request, let limits
        {
            rows += [
                .init(id: "Projected tiles", value: Self.counts(estimate.selectedTiles), exceedsLimit: (estimate.selectedTiles?.upperBound ?? 0) > request.maximumSelectedTiles),
                .init(id: "Projected requests", value: Self.counts(estimate.sourceRequests), exceedsLimit: (estimate.sourceRequests?.upperBound ?? 0) > request.maximumSourceRequests),
                .init(id: "Projected vertices", value: Self.counts(estimate.vertices), exceedsLimit: (estimate.vertices?.upperBound ?? 0) > limits.maximumVertices),
                .init(id: "Source bytes", value: Self.byteRange(estimate.sourceBytes), exceedsLimit: (estimate.sourceBytes?.upperBound ?? 0) > limits.maximumSourceBytes),
                .init(id: "Geometry buffers", value: Self.byteRange(estimate.geometryBytes), exceedsLimit: false),
                .init(id: "Texture RGBA", value: Self.byteRange(estimate.textureBytes), exceedsLimit: (estimate.textureBytes?.upperBound ?? 0) > limits.maximumDecodedTextureBytes),
            ]
            detail = "Zero Google calls. Rough area-based ranges from \(estimate.sampleCount) nearby local measurements at the same detail, with broad headroom. Accuracy is uncalibrated; whole-tile boundaries and content can vary. These ranges do not block capture.\(history.note.map { " " + $0 } ?? "")"
        }
        else
        {
            detail = "Zero Google calls. Not enough matching local data to predict workload yet. Complete captures and API inspections build this local reference automatically. Area and configured buffer budget are shown now; the budget is not a workload prediction.\(history.note.map { " " + $0 } ?? "")"
        }
        self.rows = rows
    }

    private static func counts(_ range: ClosedRange<Int>?) -> String
    {
        range.map { "\($0.lowerBound)–\($0.upperBound)" } ?? "Unavailable at this scale"
    }

    private static func byteRange(_ range: ClosedRange<Int>?) -> String
    {
        range.map { "\(bytes($0.lowerBound))–\(bytes($0.upperBound))" } ?? "Unavailable at this scale"
    }

    private static func bytes(_ value: Int) -> String
    {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
    }
}
