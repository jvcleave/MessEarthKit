import MessEarthKit
import SwiftUI

/// Locations own their shared capture area; variants own detail, downloads and exports.
struct EarthProjectCapturesView: View
{
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        ForEach(project.locations)
        { location in
            Section(location.displayTitle)
            {
                HStack
                {
                    Text(project.areaAdjustment?.locationID == location.id ? "Editing area" : location.isFrozen ? "Frozen area" : "Draft area").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show on Map") { project.showLocation(location.id) }.disabled(!library.canStartWork)
                    Button("Copy Location") { project.copyLocation(location.id) }.disabled(!library.canStartWork)
                    Button(role: .destructive) { library.requestLocationDeletion(project.id, locationID: location.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete Location").accessibilityLabel("Delete location \(location.displayTitle)")
                        .disabled(!library.canRequestDeletion || project.isSaving)
                }
                if location.id == project.editingLocationID, let editingLocation = project.editingLocation
                {
                    EarthLocationEditorView(location: editingLocation, project: project, library: library)
                }
                else { Text("\(location.area.widthMeters) × \(location.area.heightMeters) m").font(.caption) }
                if !location.variants.isEmpty
                {
                    Text("Variants").font(.headline)
                    ForEach(location.variants.reversed())
                    { variant in EarthProjectCaptureCard(variant: variant, project: project, library: library) }
                }
            }
        }
    }
}

private struct EarthProjectCaptureCard: View
{
    let variant: EarthProjectCaptureVariant
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        VStack(alignment: .leading, spacing: 8)
        {
            HStack
            {
                Text(variant.title).font(.headline)
                Spacer()
                Button(role: .destructive) { library.requestCaptureDeletion(project.id, captureID: variant.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete Variant").accessibilityLabel("Delete variant \(variant.title)")
                    .disabled(!library.canRequestDeletion || project.isSaving)
            }
            Picker("Detail", selection: Binding(get: { variant.detail }, set: { project.setVariantDetail($0, captureID: variant.id) }))
            { ForEach(EarthProjectDetail.allCases) { Text($0.title).tag($0) } }
            .disabled(!project.canChangeVariantDetail(variant.id) || !library.canStartWork)
            if let archive = project.captureStatuses[variant.id]?.archive, archive.state != .downloaded
            {
                Button(archive.sourceRequests == 0 ? "Download" : "Resume Download") { library.download(project.id, captureID: variant.id) }
                    .disabled(project.areaAdjustment != nil || !library.canStartWork || !project.hasAPIKey)
            }
            Text(project.captureStatus(variant.id)).font(.subheadline)
            if let summary = project.captureStatuses[variant.id]?.summary
            { Text(summary).font(.caption).foregroundStyle(.secondary) }
            if let error = project.captureError(variant.id)
            { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            if project.operationCaptureID == variant.id, project.phase != .idle
            {
                ProgressView(project.progressText).controlSize(.small)
                if project.phase != .deleting { Button(project.phase == .downloading ? "Pause Download" : "Cancel", action: project.pause) }
            }
            else if project.selectedCaptureID == variant.id, project.preview.isLoading
            {
                ProgressView(project.preview.status).controlSize(.small)
                Button("Cancel Preview", action: project.pause)
            }
            HStack
            {
                if let archive = project.captureStatuses[variant.id]?.archive, archive.completedPayloadCount > 0
                { Button("Reveal Download") { project.revealCapture(variant.id) } }
                if variant.preparation != nil
                { Button("Reveal Models") { project.revealCapture(variant.id, preparedModels: true) } }
                if project.captureStatuses[variant.id]?.archive?.state == .downloaded
                {
                    Button("Preview") { library.showPreview(project.id, captureID: variant.id) }
                        .disabled(!library.canViewPreview(project.id, captureID: variant.id))
                }
                else { Button("Preview", action: {}).disabled(true) }
            }
            EarthProjectExportControls(
                export: project.export,
                variantID: variant.id,
                isDownloaded: project.captureStatuses[variant.id]?.archive?.state == .downloaded,
                canStartWork: library.canStartWork && !project.isBusy,
                startExport: { project.exportVariant(variant.id) }
            )
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 6)
    }
}
