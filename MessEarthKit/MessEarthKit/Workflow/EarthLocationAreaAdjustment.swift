import Foundation
import MessEarthKit

/// A location-owned draft. Applying replaces every pending variant's current
/// source together; the snapshot rejects stale area or variant changes.
struct EarthLocationAreaAdjustment: Equatable, Sendable
{
    let locationID: UUID
    let expectedArea: EarthLocationArea
    let expectedName: EarthLocationName
    let expectedVariants: [EarthProjectCaptureVariant]
    var area: EarthLocationArea

    init(location: EarthLocationRecord)
    {
        locationID = location.id
        expectedArea = location.area
        expectedName = location.name
        expectedVariants = location.variants
        area = location.area
    }

    func matches(_ location: EarthLocationRecord) -> Bool
    {
        location.id == locationID && location.area == expectedArea && location.name == expectedName && location.variants == expectedVariants
    }

    func editingLocation(_ original: EarthLocationRecord) -> EarthLocationRecord
    {
        var draft = original
        draft.area = area
        draft.frozenAt = nil
        draft.variants = []
        return draft
    }
}
