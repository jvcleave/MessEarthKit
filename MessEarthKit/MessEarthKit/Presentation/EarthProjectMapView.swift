import MapKit
import MessEarthKit
import SwiftUI

struct EarthProjectMapFocus: Equatable
{
    let id = UUID()
    let center: EarthGeographicOrigin
    var width: Double = 1000
    var height: Double = 1000
}

private enum EarthMapTool: String, CaseIterable, Identifiable
{
    case browse = "Browse", edit = "Edit Area", draw = "Draw Area"
    var id: Self { self }
}

/// Camera browsing and explicit draft editing have independent lifetimes.
/// A drag previews in memory; its owner commits one area on release.
struct EarthProjectMapView: View
{
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var tool: EarthMapTool = .browse
    @GestureState private var dragIsActive = false
    @State private var dragCancelled = false
    @FocusState private var mapIsFocused: Bool

    private var canEdit: Bool { library.canEditMap(project.id) && project.editingLocation?.isFrozen == false }
    private var geometry: EarthMapAreaGeometry? { project.displayedLocationArea.flatMap { try? EarthMapAreaGeometry(area: $0) } }
    private var footprint: EarthProjectMapFootprint?
    {
        guard let area = project.displayedLocationArea, let request = try? area.request(detail: .standard) else { return nil }
        return EarthProjectMapFootprint(request: request)
    }

    var body: some View
    {
        VStack(alignment: .leading, spacing: 0)
        {
            VStack(alignment: .leading, spacing: 8)
            {
                Text(project.editingLocation?.displayTitle ?? "Location map").font(.headline)
                if let location = project.editingLocation, let area = project.displayedLocationArea
                {
                    Text("\(area.widthMeters) × \(area.heightMeters) m · \(location.isFrozen ? "Frozen area" : "Editable area")")
                        .lineLimit(1)
                    Text("Requested footprint. Downloaded edge tiles may extend beyond it.").font(.caption).foregroundStyle(.secondary)
                    if location.isFrozen
                    { Text("Choose Adjust Area to edit a copy of this location.").font(.caption).foregroundStyle(.secondary) }
                }
                else
                { Text("Search an address or browse the map, then choose Add Location.").font(.callout).foregroundStyle(.secondary) }
                HStack
                {
                    ForEach(EarthMapTool.allCases.filter { $0 != .browse })
                    { mode in
                        Button(mode.rawValue) { project.cancelMapAreaEdit(); tool = mode }
                            .tint(tool == mode ? .accentColor : .secondary)
                            .disabled(project.mapEdit.isEditing || (mode != .browse && (!canEdit || (mode == .edit && geometry == nil))))
                    }
                    if tool != .browse
                    {
                        Spacer()
                        Button("Done", action: finishEditing)
                            .buttonStyle(.borderedProminent)
                            .disabled(dragIsActive || project.mapEdit.isEditing)
                    }
                }.buttonStyle(.bordered)
                Text(tool == .browse ? "Pan and zoom to browse. Choose Edit Area to move or resize a draft." :
                    tool == .edit ? "Drag inside the box to move it; drag an edge or corner handle to resize. Changes save on release. Choose Done to finish." :
                    "Drag between two corners to replace this draft's rectangle. Changes save on release. Choose Done to finish.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(project.mapEdit.errorMessage ?? project.mapInputError ??
                    (footprint?.corners.isEmpty == true ? "This footprint exceeds the map's editing range. Its numeric dimensions are retained." : ""))
                    .foregroundStyle(.orange).font(.callout).lineLimit(2).frame(height: 36, alignment: .topLeading)
            }.padding(16)
            mapCanvas
                .focusable().focused($mapIsFocused).focusEffectDisabled()
        }
        .onChange(of: project.mapFocus, initial: true)
        {
            project.cancelMapAreaEdit()
            tool = .browse
            if let focus = project.mapFocus,
               let request = try? EarthDownloadRequest(center: focus.center, widthMeters: focus.width, depthMeters: focus.height)
            { camera = .region(EarthProjectMapFootprint(request: request).cameraRegion) }
        }
        .onChange(of: project.editingLocationID) { project.cancelMapAreaEdit(); tool = .browse }
        .onChange(of: canEdit) { if !canEdit { project.cancelMapAreaEdit(); tool = .browse } }
        .onChange(of: dragIsActive)
        {
            if !dragIsActive { project.cancelMapAreaEdit(); dragCancelled = false }
        }
        .onExitCommand(perform: cancelDrag)
        .onDisappear(perform: project.cancelMapAreaEdit)
    }

    private var mapCanvas: some View
    {
        MapReader
        { proxy in
            Map(position: $camera, interactionModes: tool == .browse ? [.pan, .zoom] : [])
            {
                if let location = project.editingLocation, let footprint
                {
                    if tool == .browse { Marker(location.displayTitle, coordinate: footprint.center) }
                    if tool == .browse, !footprint.corners.isEmpty
                    { MapPolygon(coordinates: footprint.corners).foregroundStyle(.blue.opacity(0.18)).stroke(.blue, lineWidth: 2) }
                }
            }
            .mapStyle(.standard(elevation: .flat))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd)
            { context in
                if let center = try? EarthGeographicOrigin(latitude: context.region.center.latitude, longitude: context.region.center.longitude)
                { project.mapCenter = center }
            }
            .overlay
            {
                if canEdit, tool != .browse
                {
                    EarthMapAreaHandles(geometry: geometry, proxy: proxy, showsHandles: tool == .edit)
                        .clipped()
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .local)
                            .updating($dragIsActive) { _, active, _ in active = true }
                            .onChanged { value in updateDrag(value, proxy: proxy) }
                            .onEnded
                            { value in
                                defer { dragCancelled = false }
                                guard !dragCancelled else { project.cancelMapAreaEdit(); return }
                                guard coordinate(value.location, proxy: proxy) != nil else { project.cancelMapAreaEdit(); return }
                                updateDrag(value, proxy: proxy)
                                let committed = project.finishMapAreaEdit()
                                if tool == .draw, committed { tool = .edit }
                            })
                }
            }
        }
    }

    private func coordinate(_ point: CGPoint, proxy: MapProxy) -> EarthGeographicOrigin?
    {
        guard let coordinate = proxy.convert(point, from: .local) else { return nil }
        return try? EarthGeographicOrigin(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func updateDrag(_ value: DragGesture.Value, proxy: MapProxy)
    {
        guard !dragCancelled, canEdit, let start = coordinate(value.startLocation, proxy: proxy), let current = coordinate(value.location, proxy: proxy) else { return }
        if !project.mapEdit.isEditing
        {
            let kind: EarthMapAreaDrag?
            if tool == .draw { kind = .draw }
            else { kind = EarthMapAreaHandles.target(at: value.startLocation, geometry: geometry, proxy: proxy) }
            guard let kind else { return }
            mapIsFocused = true
            project.beginMapAreaEdit(kind: kind, start: start)
        }
        project.updateMapAreaEdit(to: current)
    }

    private func cancelDrag()
    {
        if dragIsActive { dragCancelled = true }
        project.cancelMapAreaEdit()
    }

    private func finishEditing()
    {
        project.cancelMapAreaEdit()
        tool = .browse
        mapIsFocused = false
    }
}

private struct EarthMapAreaHandles: View
{
    let geometry: EarthMapAreaGeometry?
    let proxy: MapProxy
    let showsHandles: Bool

    var body: some View
    {
        GeometryReader
        { _ in
            ZStack(alignment: .topLeading)
            {
                Color.clear
                if let geometry
                {
                    let points = geometry.corners.compactMap { proxy.convert($0, to: .local) }
                    if points.count == 4
                    {
                        let outline = Path
                        { path in
                            path.move(to: points[0])
                            for point in points.dropFirst() { path.addLine(to: point) }
                            path.closeSubpath()
                        }
                        outline.fill(.blue.opacity(0.18)).overlay(outline.stroke(.blue, lineWidth: 2))
                            .allowsHitTesting(false)
                    }
                }
                if showsHandles, let geometry
                {
                    ForEach(EarthMapAreaHandle.allCases)
                    { handle in
                        if let point = proxy.convert(geometry.coordinate(for: handle), to: .local)
                        {
                            Circle().fill(.white).overlay(Circle().stroke(.blue, lineWidth: 2))
                                .frame(width: 10, height: 10).position(point)
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
        }
    }

    static func target(at point: CGPoint, geometry: EarthMapAreaGeometry?, proxy: MapProxy) -> EarthMapAreaDrag?
    {
        guard let geometry else { return nil }
        let handles = EarthMapAreaHandle.allCases.compactMap
        { handle -> (EarthMapAreaHandle, CGFloat)? in
            guard let position = proxy.convert(geometry.coordinate(for: handle), to: .local) else { return nil }
            return (handle, hypot(position.x - point.x, position.y - point.y))
        }
        if let nearest = handles.min(by: { $0.1 < $1.1 }), nearest.1 <= 12 { return .resize(nearest.0) }
        let corners = geometry.corners.compactMap { proxy.convert($0, to: .local) }
        guard corners.count == 4, let minX = corners.map(\.x).min(), let minY = corners.map(\.y).min(),
              let maxX = corners.map(\.x).max(), let maxY = corners.map(\.y).max() else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).contains(point) ? .move : nil
    }
}

private struct EarthProjectMapFootprint
{
    let center: CLLocationCoordinate2D
    let corners: [CLLocationCoordinate2D]
    let cameraRegion: MKCoordinateRegion

    init(request: EarthDownloadRequest)
    {
        center = CLLocationCoordinate2D(latitude: request.center.latitude, longitude: request.center.longitude)
        let region = MKCoordinateRegion(center: center, latitudinalMeters: request.depthMeters, longitudinalMeters: request.widthMeters)
        let area = EarthLocationArea(center: request.center, widthMeters: String(request.widthMeters), heightMeters: String(request.depthMeters))
        corners = (try? EarthMapAreaGeometry(area: area).corners) ?? []
        cameraRegion = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: min(170, max(0.002, region.span.latitudeDelta * 1.5)),
                longitudeDelta: min(360, max(0.002, region.span.longitudeDelta * 1.5))
            )
        )
    }
}
