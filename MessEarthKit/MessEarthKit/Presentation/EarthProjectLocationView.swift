import SwiftUI

/// Expansion belongs to the project owner; hiding controls never owns job lifetime.
struct EarthProjectLocationView: View
{
    let location: EarthLocationRecord
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel
    @State private var renameDraft: EarthLocationRenameViewModel?

    private var isExpanded: Bool { project.expandedLocationIDs.contains(location.id) }
    private var area: EarthLocationArea
    { location.id == project.editingLocationID ? project.displayedLocationArea ?? location.area : location.area }

    private var hasError: Bool
    {
        location.variants.contains
        { variant in
            project.captureError(variant.id) != nil ||
                (project.export.variantID == variant.id && project.export.errorMessage != nil) ||
                project.export.exports(for: variant.id).contains(where: { $0.contentsError != nil })
        } || (!location.variants.isEmpty && (project.export.historyError != nil || project.export.managementError != nil))
    }

    var body: some View
    {
        Section
        {
            HStack(alignment: .top)
            {
                Button { project.setLocationExpanded(!isExpanded, locationID: location.id) } label: {
                    HStack(alignment: .top, spacing: 8)
                    {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            .frame(width: 10).padding(.top, 3).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4)
                        {
                            Text(location.displayTitle).font(.headline)
                            Text("\(area.widthMeters) × \(area.heightMeters) m · \(location.variants.count) \(location.variants.count == 1 ? "variant" : "variants")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                Button("Rename…") { project.prepareLocationRename(location.id) { renameDraft = $0 } }
                    .buttonStyle(.borderless).controlSize(.small)
                    .accessibilityLabel("Rename location \(location.displayTitle)")
                    .disabled(!library.canStartWork || !project.canRenameLocation(location.id))
            }
            if isExpanded
            {
                locationControls
                if !location.variants.isEmpty
                {
                    Text("Variants").font(.headline)
                    ForEach(location.variants.reversed())
                    { variant in EarthProjectCaptureCard(variant: variant, project: project, library: library) }
                }
            }
            else { collapsedActivity }
        }
        .sheet(item: $renameDraft) { EarthLocationRenameView(viewModel: $0) }
    }

    @ViewBuilder
    private var locationControls: some View
    {
        HStack
        {
            Text(project.areaAdjustment?.locationID == location.id ? "Editing area" : location.isFrozen ? "Frozen area" : "Draft area").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Show on Map") { project.showLocation(location.id) }.disabled(!library.canStartWork || project.isBusy)
            Button("Duplicate") { project.copyLocation(location.id) }.disabled(!library.canStartWork || project.isBusy)
            Button(role: .destructive) { library.requestLocationDeletion(project.id, locationID: location.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete Location").accessibilityLabel("Delete location \(location.displayTitle)")
                .disabled(!library.canDeleteLocation(project.id, locationID: location.id))
        }
        if location.id == project.editingLocationID, let editingLocation = project.editingLocation
        { EarthLocationEditorView(location: editingLocation, project: project, library: library) }
    }

    @ViewBuilder
    private var collapsedActivity: some View
    {
        ForEach(location.variants)
        { variant in
            if project.downloadJob(variant.id)?.phase.isActive == true ||
                (project.operationCaptureID == variant.id && project.phase != .idle) ||
                (project.selectedCaptureID == variant.id && project.preview.isLoading)
            {
                VStack(alignment: .leading, spacing: 6)
                {
                    Text(variant.title).font(.subheadline)
                    EarthProjectCaptureProgressView(captureID: variant.id, project: project)
                }
            }
        }
        if project.export.isLoading, location.variants.contains(where: { $0.id == project.export.variantID })
        {
            ProgressView(project.export.status).controlSize(.small)
            Button("Cancel Export", action: project.export.cancel)
        }
        if hasError
        {
            Button { project.setLocationExpanded(true, locationID: location.id) } label: {
                Label("Expand to view errors", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.caption)
            }.buttonStyle(.borderless)
        }
    }
}
