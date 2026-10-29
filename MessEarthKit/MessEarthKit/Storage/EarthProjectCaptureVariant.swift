import Foundation
import MessEarthKit

/// Stable user-visible identity, independent of its immutable source attempts.
/// An incomplete attempt can be revised without adding another variant.
struct EarthProjectCaptureVariant: Codable, Equatable, Identifiable, Sendable
{
    let id: UUID
    let capture: EarthProjectCapture
    let locationID: UUID
    let detail: EarthProjectDetail
    let createdAt: Date
    var preparation: EarthProjectPreparation?
    let previousCaptures: [EarthProjectCapture]
    var sourceCaptures: [EarthProjectCapture] { previousCaptures + [capture] }
    var title: String { detail.title }

    init(id: UUID? = nil, capture: EarthProjectCapture, locationID: UUID, detail: EarthProjectDetail, createdAt: Date, preparation: EarthProjectPreparation? = nil, previousCaptures: [EarthProjectCapture] = [])
    {
        self.id = id ?? capture.id
        self.capture = capture
        self.locationID = locationID
        self.detail = detail
        self.createdAt = createdAt
        self.preparation = preparation
        self.previousCaptures = previousCaptures
    }

    func validate() throws
    {
        guard createdAt.timeIntervalSince1970.isFinite,
              sourceCaptures.first?.id == id,
              detail.errorMeters == capture.request.maximumGeometricErrorMeters,
              previousCaptures.allSatisfy({ previous in EarthProjectDetail.allCases.contains { $0.errorMeters == previous.request.maximumGeometricErrorMeters } }),
              Set(sourceCaptures.map(\.id)).count == sourceCaptures.count
        else { throw EarthProjectStoreError.invalidRecord }
        if let preparation, preparation.captureID != capture.id { throw EarthProjectStoreError.invalidRecord }
    }

    private enum CodingKeys: String, CodingKey { case id, capture, locationID, detail, createdAt, preparation, previousCaptures }

    init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        capture = try values.decode(EarthProjectCapture.self, forKey: .capture)
        locationID = try values.decode(UUID.self, forKey: .locationID)
        detail = try values.decode(EarthProjectDetail.self, forKey: .detail)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        preparation = try values.decode(EarthProjectPreparation?.self, forKey: .preparation)
        previousCaptures = try values.decode([EarthProjectCapture].self, forKey: .previousCaptures)
        try validate()
    }

    func encode(to encoder: any Encoder) throws
    {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(capture, forKey: .capture)
        try values.encode(locationID, forKey: .locationID)
        try values.encode(detail, forKey: .detail)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(preparation, forKey: .preparation)
        try values.encode(previousCaptures, forKey: .previousCaptures)
    }
}
