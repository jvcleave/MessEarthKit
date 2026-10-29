import Foundation
import MapKit
import MessEarthKit
import Testing

// The visible box can move without a mode change. Only visible handles resize;
// outside points must remain available for map browsing rather than start edits.
@Test func mapAreaScreenTargetsKeepOutsideMapAvailable() throws
{
    let geometry = try #require(EarthMapAreaScreenGeometry(corners: [
        CGPoint(x: 100, y: 80), CGPoint(x: 300, y: 80),
        CGPoint(x: 300, y: 200), CGPoint(x: 100, y: 200),
    ]))
    #expect(geometry.target(at: CGPoint(x: 200, y: 140), showsHandles: false) == .move)
    #expect(geometry.target(at: CGPoint(x: 108, y: 78), showsHandles: true) == .resize(.northWest))
    let nearEast = CGPoint(x: 310, y: 140)
    #expect(geometry.interactionRect(showsHandles: true).contains(nearEast))
    #expect(geometry.target(at: nearEast, showsHandles: true) == .resize(.east))
    #expect(!geometry.interactionRect(showsHandles: false).contains(nearEast))
    #expect(geometry.target(at: nearEast, showsHandles: false) == nil)
    let outside = CGPoint(x: 320, y: 140)
    #expect(!geometry.interactionRect(showsHandles: true).contains(outside))
    #expect(geometry.target(at: outside, showsHandles: true) == nil)
    #expect(EarthMapAreaScreenGeometry(corners: []) == nil)
}

// Pointer movement preserves meters; resizing anchors the opposite edge and
// stays positive; date-line drawing selects the small wrapped area. No map I/O.
@Test func mapAreaMoveResizeAndWrappedDrawing() throws
{
    let origin = try EarthGeographicOrigin(latitude: 0, longitude: 179.999, ellipsoidHeight: 12)
    let area = EarthLocationArea(center: origin, widthMeters: "200", heightMeters: "100")
    let geometry = try EarthMapAreaGeometry(area: area)
    let destination = try EarthGeographicOrigin(latitude: 1, longitude: -179.999)
    let moved = try geometry.moved(area: area, from: origin, to: destination)
    #expect(abs(moved.center.latitude - 1) < 1e-8 && abs(moved.center.longitude + 179.999) < 1e-8)
    #expect(moved.center.ellipsoidHeight == 12 && moved.widthMeters == "200" && moved.heightMeters == "100")
    let east = MKMapPoint(x: geometry.rect.maxX + geometry.rect.size.width, y: geometry.rect.midY).coordinate
    let resized = try geometry.resized(area: area, handle: .east, to: EarthGeographicOrigin(latitude: east.latitude, longitude: east.longitude))
    #expect(abs(try #require(Double(resized.widthMeters)) - 400) < 0.01 && resized.heightMeters == area.heightMeters)
    let retainedWest = try EarthMapAreaGeometry(area: resized).coordinate(for: .west)
    let originalWest = geometry.coordinate(for: .west)
    #expect(abs(retainedWest.longitude - originalWest.longitude) < 1e-7)
    let crossed = try geometry.resized(area: area, handle: .west, to: destination)
    #expect(try #require(Double(crossed.widthMeters)) >= 1 && crossed.heightMeters == "100")
    let drawn = try EarthMapAreaGeometry.drawn(from: origin, to: EarthGeographicOrigin(latitude: 0.001, longitude: -179.999), ellipsoidHeight: 12)
    #expect(abs(abs(drawn.center.longitude) - 180) < 1e-7 && drawn.center.ellipsoidHeight == 12)
    // Independent geodesic distances validate meter conversion rather than
    // deriving expected dimensions from the map-point scale being tested.
    let start = CLLocation(latitude: 0, longitude: 179.999)
    let width = start.distance(from: CLLocation(latitude: 0, longitude: -179.999))
    let height = start.distance(from: CLLocation(latitude: 0.001, longitude: 179.999))
    #expect(abs(try #require(Double(drawn.widthMeters)) - width) < 0.01)
    #expect(abs(try #require(Double(drawn.heightMeters)) - height) < 0.01)
}

private enum MapEditFinish: CaseIterable { case commit, cancel, differentLocation, changedArea, frozen }

// Live preview cannot write a frozen/replaced area. Release returns one atomic
// area; cancellation discards it without modifying the original snapshot.
@Test(arguments: MapEditFinish.allCases)
private func mapAreaSessionValidatesIdentityAndCancellation(outcome: MapEditFinish) throws
{
    let origin = try EarthGeographicOrigin(latitude: 39, longitude: -84)
    let original = EarthLocationRecord(date: Date(), name: .custom("Draft"), area: .init(center: origin))
    var editing = EarthMapAreaEditing()
    try editing.begin(location: original, kind: .resize(.southEast), start: origin)
    editing.update(to: try EarthGeographicOrigin(latitude: 38.999, longitude: -83.998))
    let preview = try #require(editing.preview)
    #expect(editing.isEditing && preview != original.area)
    var current = original
    switch outcome
    {
        case .commit: #expect(try editing.finish(location: current) == preview)
        case .cancel: editing.cancel()
        case .differentLocation: current = EarthLocationRecord(date: Date(), name: .custom("Other"), area: original.area)
        case .changedArea: current.area.widthMeters = "500"
        case .frozen: current.frozenAt = Date()
    }
    if outcome != .commit && outcome != .cancel
    { #expect(throws: EarthMapAreaError.self) { try editing.finish(location: current) } }
    #expect(!editing.isEditing && editing.preview == nil && original.area.widthMeters == "200")
}

@Test func mapAreaRejectsInvalidDrawingAndFrozenStart() throws
{
    let origin = try EarthGeographicOrigin(latitude: 0, longitude: 0)
    var location = EarthLocationRecord(date: Date(), name: .custom("Draft"), area: .init(center: origin))
    var editing = EarthMapAreaEditing()
    // Drawing repairs an incomplete numeric draft.
    location.area.widthMeters = ""
    try editing.begin(location: location, kind: .draw, start: origin)
    editing.update(to: origin)
    #expect(editing.preview == nil && editing.errorMessage != nil)
    editing.update(to: try EarthGeographicOrigin(latitude: 0.002, longitude: 0.001))
    #expect(try editing.finish(location: location).widthMeters != "")
    let polar = EarthLocationArea(center: try EarthGeographicOrigin(latitude: 86, longitude: 0))
    #expect(throws: EarthMapAreaError.self) { try EarthMapAreaGeometry(area: polar) }
    location.area.widthMeters = "200"
    location.frozenAt = Date()
    #expect(throws: EarthProjectStoreError.frozenLocation) { try editing.begin(location: location, kind: .draw, start: origin) }
    #expect(!editing.isEditing)
}
