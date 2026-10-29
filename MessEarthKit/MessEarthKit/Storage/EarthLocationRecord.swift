import Foundation
import MessEarthKit

/// Incomplete dimension edits stay intact until acquisition validates them.
struct EarthLocationArea: Codable, Equatable, Sendable
{
    var center: EarthGeographicOrigin
    var widthMeters: String = "200"
    var heightMeters: String = "200"

    func request(detail: EarthProjectDetail) throws -> EarthDownloadRequest
    {
        guard let width = Double(widthMeters), let height = Double(heightMeters)
        else { throw EarthProjectCaptureError.invalidInput }
        return try EarthDownloadRequest(center: center, widthMeters: width, depthMeters: height, maximumGeometricErrorMeters: detail.errorMeters)
    }

    func validate() throws
    {
        guard widthMeters.utf8.count <= 64, heightMeters.utf8.count <= 64
        else { throw EarthProjectStoreError.invalidRecord }
    }
}

struct EarthLocationEdit: Equatable, Sendable
{
    var name: EarthLocationName
    var area: EarthLocationArea
    var variantDetail: EarthProjectDetail?
    var title: String
    {
        get { name.title(center: area.center) }
        set { name = .custom(newValue) }
    }
}

/// Area ownership is separate from map search and from acquisition identity.
/// Once registered, even an empty location retains its permanent frozen state.
struct EarthLocationRecord: Codable, Equatable, Identifiable, Sendable
{
    let id: UUID
    let createdAt: Date
    var name: EarthLocationName
    var area: EarthLocationArea
    var frozenAt: Date?
    var variantDetail: EarthProjectDetail?
    var variants: [EarthProjectCaptureVariant]
    var isFrozen: Bool { frozenAt != nil }
    var nextVariantDetail: EarthProjectDetail { variantDetail ?? variants.last?.detail ?? .standard }
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled Location" : title }
    var title: String { name.title(center: area.center) }
    var edit: EarthLocationEdit { .init(name: name, area: area, variantDetail: variantDetail) }

    init(id: UUID = UUID(), date: Date, name: EarthLocationName, area: EarthLocationArea, detail: EarthProjectDetail = .standard)
    {
        self.id = id
        createdAt = date
        self.name = name
        self.area = area
        variantDetail = detail
        variants = []
    }

    mutating func apply(_ edit: EarthLocationEdit) throws
    {
        if isFrozen, edit.area != area { throw EarthProjectStoreError.frozenLocation }
        name = edit.name
        area = edit.area
        variantDetail = edit.variantDetail
    }

    func validate() throws
    {
        try area.validate()
        try name.validate()
        guard title.utf8.count <= 512, createdAt.timeIntervalSince1970.isFinite,
              Set(variants.map(\.id)).count == variants.count,
              variants.isEmpty || isFrozen
        else { throw EarthProjectStoreError.invalidRecord }
        if let frozenAt
        {
            guard frozenAt.timeIntervalSince1970.isFinite, frozenAt >= createdAt else { throw EarthProjectStoreError.invalidRecord }
            _ = try area.request(detail: .standard)
        }
        for variant in variants
        {
            try variant.validate()
            guard variant.locationID == id, variant.createdAt >= createdAt,
                  frozenAt.map({ $0 <= variant.createdAt }) == true
            else { throw EarthProjectStoreError.invalidRecord }
        }
        // Every current detail variant captures the same location-owned box.
        // Historical attempts keep their original immutable requests.
        guard variants.allSatisfy({ variant in
            variant.capture.request == (try? area.request(detail: variant.detail))
        }) else { throw EarthProjectStoreError.invalidRecord }
    }

    private enum CodingKeys: String, CodingKey { case id, createdAt, name, area, frozenAt, variantDetail, variants }

    init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        name = try values.decode(EarthLocationName.self, forKey: .name)
        area = try values.decode(EarthLocationArea.self, forKey: .area)
        frozenAt = try values.decode(Date?.self, forKey: .frozenAt)
        variantDetail = try values.decode(EarthProjectDetail?.self, forKey: .variantDetail)
        variants = try values.decode([EarthProjectCaptureVariant].self, forKey: .variants)
        try validate()
    }

    func encode(to encoder: any Encoder) throws
    {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(name, forKey: .name)
        try values.encode(area, forKey: .area)
        try values.encode(frozenAt, forKey: .frozenAt)
        try values.encode(variantDetail, forKey: .variantDetail)
        try values.encode(variants, forKey: .variants)
    }
}
