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

/// The native footprint remains visible while its box and handles receive edits.
/// A drag previews in memory; its owner commits one area on release.
struct EarthProjectMapView: View
{
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel
    @State private var camera: MapCameraPosition = .automatic
    @State private var areaIsSelected = false
    @State private var isDrawing = false
    @State private var screenArea: EarthMapAreaScreenGeometry?
    @GestureState private var dragIsActive = false
    @State private var dragCancelled = false
    @FocusState private var mapIsFocused: Bool
    @Namespace private var mapCoordinateSpace

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
                    { Text("Use Adjust Area on an incomplete variant, or Duplicate to capture another area.").font(.caption).foregroundStyle(.secondary) }
                }
                else
                { Text("Search an address or browse the map, then choose Add Location.").font(.callout).foregroundStyle(.secondary) }
                HStack
                {
                    Button("Draw Area")
                    {
                        project.cancelMapAreaEdit()
                        isDrawing = true
                        areaIsSelected = true
                        mapIsFocused = true
                    }
                    .tint(isDrawing ? .accentColor : .secondary)
                    .disabled(!canEdit || dragIsActive || project.mapEdit.isEditing)
                    if areaIsSelected || isDrawing
                    {
                        Spacer()
                        Button("Done", action: finishEditing)
                            .buttonStyle(.borderedProminent)
                            .disabled(dragIsActive || project.mapEdit.isEditing)
                    }
                }.buttonStyle(.bordered)
                Text(mapHelp)
                    .font(.caption).foregroundStyle(.secondary)
                if let error = project.mapEdit.errorMessage ?? project.mapInputError ??
                    (footprint?.corners.isEmpty == true ? "This footprint exceeds the map's editing range. Its numeric dimensions are retained." : nil)
                { EarthErrorMessage(error, color: .orange).font(.callout) }
                else { Text("").frame(height: 36) }
            }.padding(16)
            mapCanvas
                .focusable().focused($mapIsFocused).focusEffectDisabled()
        }
        .onChange(of: project.mapFocus, initial: true)
        {
            resetAreaSelection()
            if let focus = project.mapFocus,
               let request = try? EarthDownloadRequest(center: focus.center, widthMeters: focus.width, depthMeters: focus.height)
            { camera = .region(EarthProjectMapFootprint(request: request).cameraRegion) }
        }
        .onChange(of: project.editingLocationID) { resetAreaSelection() }
        .onChange(of: canEdit) { resetAreaSelection() }
        .onChange(of: dragIsActive)
        {
            if !dragIsActive { project.cancelMapAreaEdit(); dragCancelled = false }
        }
        .onExitCommand(perform: cancelDrag)
        .onDisappear(perform: project.cancelMapAreaEdit)
    }

    private var mapHelp: String
    {
        if !canEdit { return "Pan and zoom to browse." }
        if isDrawing { return "Drag between two corners to replace this draft's rectangle. Changes save on release. Choose Done to finish." }
        if areaIsSelected { return "Drag the box to move it, or its handles to resize. Pan and zoom outside the box. Changes save on release. Choose Done to finish." }
        return "Drag the box to move it, or click it to show resize handles. Pan and zoom outside the box."
    }

    private var mapCanvas: some View
    {
        MapReader
        { proxy in
            GeometryReader
            { bounds in
                ZStack(alignment: .topLeading)
                {
                    Map(position: $camera, interactionModes: isDrawing || project.mapEdit.isEditing ? [] : [.pan, .zoom])
                    {
                        if let location = project.editingLocation, let footprint
                        {
                            if !canEdit { Marker(location.displayTitle, coordinate: footprint.center) }
                            if !footprint.corners.isEmpty
                            { MapPolygon(coordinates: footprint.corners).foregroundStyle(.blue.opacity(0.18)).stroke(.blue, lineWidth: 2) }
                        }
                    }
                    .mapStyle(.standard(elevation: .flat))
                    .mapControls { MapCompass(); MapScaleView() }
                    .onMapCameraChange(frequency: .continuous)
                    { context in
                        refreshScreenArea(proxy: proxy)
                        if let center = try? EarthGeographicOrigin(latitude: context.region.center.latitude, longitude: context.region.center.longitude)
                        { project.mapCenter = center }
                    }
                    if canEdit
                    {
                        if let editRect = isDrawing ? CGRect(origin: .zero, size: bounds.size) : screenArea?.interactionRect(showsHandles: areaIsSelected)
                        {
                            let hitRect = editRect.intersection(CGRect(origin: .zero, size: bounds.size))
                            if !hitRect.isNull, !hitRect.isEmpty
                            {
                                Color.clear
                                    .frame(width: hitRect.width, height: hitRect.height)
                                    .contentShape(Rectangle())
                                    .onTapGesture { areaIsSelected = true; mapIsFocused = true }
                                    .gesture(areaDrag(proxy: proxy))
                                    .position(x: hitRect.midX, y: hitRect.midY)
                            }
                        }
                        if areaIsSelected, !isDrawing, let screenArea
                        { EarthMapAreaHandles(geometry: screenArea).allowsHitTesting(false) }
                    }
                }
                .coordinateSpace(name: mapCoordinateSpace)
                .clipped()
                .onChange(of: bounds.size) { refreshScreenArea(proxy: proxy) }
                .onChange(of: project.displayedLocationArea, initial: true) { refreshScreenArea(proxy: proxy) }
            }
        }
    }

    private func refreshScreenArea(proxy: MapProxy)
    {
        screenArea = geometry.flatMap
        { area in
            EarthMapAreaScreenGeometry(corners: area.corners.compactMap { proxy.convert($0, to: .named(mapCoordinateSpace)) })
        }
    }

    private func areaDrag(proxy: MapProxy) -> some Gesture
    {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(mapCoordinateSpace))
            .updating($dragIsActive) { _, active, _ in active = true }
            .onChanged { value in updateDrag(value, proxy: proxy) }
            .onEnded
            { value in
                defer { dragCancelled = false }
                guard !dragCancelled else { project.cancelMapAreaEdit(); return }
                guard coordinate(value.location, proxy: proxy) != nil else { project.cancelMapAreaEdit(); return }
                updateDrag(value, proxy: proxy)
                if project.finishMapAreaEdit() { isDrawing = false }
            }
    }

    private func coordinate(_ point: CGPoint, proxy: MapProxy) -> EarthGeographicOrigin?
    {
        guard let coordinate = proxy.convert(point, from: .named(mapCoordinateSpace)) else { return nil }
        return try? EarthGeographicOrigin(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private func updateDrag(_ value: DragGesture.Value, proxy: MapProxy)
    {
        guard !dragCancelled, canEdit, let start = coordinate(value.startLocation, proxy: proxy), let current = coordinate(value.location, proxy: proxy) else { return }
        if !project.mapEdit.isEditing
        {
            let kind: EarthMapAreaDrag?
            if isDrawing { kind = .draw }
            else { kind = screenArea?.target(at: value.startLocation, showsHandles: areaIsSelected) }
            guard let kind else { return }
            areaIsSelected = true
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
        isDrawing = false
        areaIsSelected = false
        mapIsFocused = false
    }

    private func resetAreaSelection()
    {
        project.cancelMapAreaEdit()
        isDrawing = false
        areaIsSelected = canEdit
    }
}

private struct EarthMapAreaHandles: View
{
    let geometry: EarthMapAreaScreenGeometry

    var body: some View
    {
        ZStack(alignment: .topLeading)
        {
            Color.clear
            ForEach(EarthMapAreaHandle.allCases)
            { handle in
                let point = geometry.point(for: handle)
                Circle().fill(.white).overlay(Circle().stroke(.blue, lineWidth: 2))
                    .frame(width: 10, height: 10).position(point)
            }
        }
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
