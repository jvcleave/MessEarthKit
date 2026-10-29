import Foundation
import MessEarthKit

/// A saved acquisition selection. Project title/editor changes never rewrite
/// this snapshot, its source request, or another variant's prepared reference.
struct EarthProjectCaptureVariant: Codable, Equatable, Identifiable, Sendable
{
    let capture: EarthProjectCapture
    let draft: EarthProjectDraft
    let location: EarthProjectLocation?
    let createdAt: Date
    var preparation: EarthProjectPreparation?
    var id: UUID { capture.id }
    var title: String { "\(draft.detail.title) · \(capture.request.widthMeters.formatted()) × \(capture.request.depthMeters.formatted()) m" }

    init(capture: EarthProjectCapture, draft: EarthProjectDraft, location: EarthProjectLocation?, createdAt: Date, preparation: EarthProjectPreparation? = nil)
    {
        self.capture = capture
        self.draft = draft
        self.location = location
        self.createdAt = createdAt
        self.preparation = preparation
    }

    func validate() throws
    {
        try draft.validate()
        guard createdAt.timeIntervalSince1970.isFinite,
              Double(draft.widthMeters) == capture.request.widthMeters,
              Double(draft.heightMeters) == capture.request.depthMeters,
              draft.detail.errorMeters == capture.request.maximumGeometricErrorMeters
        else { throw EarthProjectStoreError.invalidRecord }
        if let location
        {
            guard location.address == draft.address, !location.title.isEmpty,
                  location.title.utf8.count <= 4096, location.origin == capture.request.center
            else { throw EarthProjectStoreError.invalidRecord }
        }
        if let preparation, preparation.captureID != id { throw EarthProjectStoreError.invalidRecord }
    }

    private enum CodingKeys: String, CodingKey { case capture, draft, location, createdAt, preparation }

    init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        capture = try values.decode(EarthProjectCapture.self, forKey: .capture)
        draft = try values.decode(EarthProjectDraft.self, forKey: .draft)
        location = try values.decode(EarthProjectLocation?.self, forKey: .location)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        preparation = try values.decode(EarthProjectPreparation?.self, forKey: .preparation)
        try validate()
    }

    func encode(to encoder: any Encoder) throws
    {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(capture, forKey: .capture)
        try values.encode(draft, forKey: .draft)
        try values.encode(location, forKey: .location)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(preparation, forKey: .preparation)
    }
}
