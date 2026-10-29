import Foundation
import MessEarthKit

/// Live edits are transient. Release validates the original location identity
/// and area before the owner persists one complete edit; cancellation saves none.
struct EarthMapAreaEditing
{
    private struct Session
    {
        let locationID: UUID
        let area: EarthLocationArea
        let kind: EarthMapAreaDrag
        let start: EarthGeographicOrigin
    }

    private var session: Session?
    private var failure: (any Error)?
    private(set) var preview: EarthLocationArea?
    private(set) var errorMessage: String?
    var isEditing: Bool { session != nil }
    var locationID: UUID? { session?.locationID }

    mutating func begin(location: EarthLocationRecord, kind: EarthMapAreaDrag, start: EarthGeographicOrigin) throws
    {
        guard !location.isFrozen else { throw EarthProjectStoreError.frozenLocation }
        guard session == nil else { throw EarthMapAreaError.changed }
        if kind != .draw { _ = try EarthMapAreaGeometry(area: location.area) }
        session = .init(locationID: location.id, area: location.area, kind: kind, start: start)
        preview = nil
        errorMessage = nil
        failure = nil
    }

    mutating func update(to point: EarthGeographicOrigin)
    {
        guard let session else { return }
        do
        {
            switch session.kind
            {
                case .move: preview = try EarthMapAreaGeometry(area: session.area).moved(area: session.area, from: session.start, to: point)
                case let .resize(handle): preview = try EarthMapAreaGeometry(area: session.area).resized(area: session.area, handle: handle, to: point)
                case .draw: preview = try EarthMapAreaGeometry.drawn(from: session.start, to: point, ellipsoidHeight: session.area.center.ellipsoidHeight)
            }
            errorMessage = nil
            failure = nil
        }
        catch { preview = nil; failure = error; errorMessage = error.localizedDescription }
    }

    mutating func finish(location: EarthLocationRecord?) throws -> EarthLocationArea
    {
        defer { cancel() }
        guard let session, let location, location.id == session.locationID,
              !location.isFrozen, location.area == session.area else { throw EarthMapAreaError.changed }
        guard let preview else { throw failure ?? EarthMapAreaError.tooSmall }
        return preview
    }

    mutating func cancel()
    {
        session = nil
        preview = nil
        errorMessage = nil
        failure = nil
    }
}
