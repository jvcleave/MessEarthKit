import Foundation
import MessEarthKit

/// A saved acquisition selection. Project title/editor changes never rewrite
/// this snapshot, its source request, or another variant's prepared reference.
struct EarthProjectCaptureVariant: Codable, Equatable, Identifiable, Sendable
{
    let capture: EarthProjectCapture
    let locationID: UUID
    let detail: EarthProjectDetail
    let createdAt: Date
    var preparation: EarthProjectPreparation?
    var id: UUID { capture.id }
    var title: String { "\(detail.title) · \(capture.request.widthMeters.formatted()) × \(capture.request.depthMeters.formatted()) m" }

    init(capture: EarthProjectCapture, locationID: UUID, detail: EarthProjectDetail, createdAt: Date, preparation: EarthProjectPreparation? = nil)
    {
        self.capture = capture
        self.locationID = locationID
        self.detail = detail
        self.createdAt = createdAt
        self.preparation = preparation
    }

    func validate() throws
    {
        guard createdAt.timeIntervalSince1970.isFinite,
              detail.errorMeters == capture.request.maximumGeometricErrorMeters
        else { throw EarthProjectStoreError.invalidRecord }
        if let preparation, preparation.captureID != id { throw EarthProjectStoreError.invalidRecord }
    }

    private enum CodingKeys: String, CodingKey { case capture, locationID, detail, createdAt, preparation }

    init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        capture = try values.decode(EarthProjectCapture.self, forKey: .capture)
        locationID = try values.decode(UUID.self, forKey: .locationID)
        detail = try values.decode(EarthProjectDetail.self, forKey: .detail)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        preparation = try values.decode(EarthProjectPreparation?.self, forKey: .preparation)
        try validate()
    }

    func encode(to encoder: any Encoder) throws
    {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(capture, forKey: .capture)
        try values.encode(locationID, forKey: .locationID)
        try values.encode(detail, forKey: .detail)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(preparation, forKey: .preparation)
    }
}
