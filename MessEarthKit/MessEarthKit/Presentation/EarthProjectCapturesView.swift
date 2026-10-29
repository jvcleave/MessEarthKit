import MessEarthKit
import SwiftUI

/// Each saved acquisition owns its actions. Opening files or a preview leaves
/// the editor alone; adjusting an area creates an independent editable location.
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
                    Text(location.isFrozen ? "Frozen area" : "Draft area").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show on Map") { project.showLocation(location.id) }.disabled(!library.canStartWork)
                    Button(role: .destructive) { library.requestLocationDeletion(project.id, locationID: location.id) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Delete Location").accessibilityLabel("Delete location \(location.displayTitle)")
                        .disabled(!library.canRequestDeletion || project.isSaving)
                }
                Text("\(location.area.widthMeters) × \(location.area.heightMeters) m").font(.caption)
                HStack
                {
                    Button("Copy Location") { project.copyLocation(location.id) }
                    if location.isFrozen, location.variantDetail == nil
                    { Button("Add Variant") { project.addVariant(location.id) } }
                }.disabled(!library.canStartWork)
                if let detail = location.variantDetail
                { Text("\(detail.title) variant · Not downloaded").font(.caption).foregroundStyle(.secondary) }
                ForEach(location.variants.reversed())
                { variant in EarthProjectCaptureCard(variant: variant, project: project, library: library) }
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
            Text(variant.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
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
                Button("Reveal in Finder") { project.revealCapture(variant.id) }
                if project.captureStatuses[variant.id]?.archive?.state == .downloaded
                {
                    Button("Preview") { library.showPreview(project.id, captureID: variant.id) }
                        .disabled(!library.canViewPreview(project.id, captureID: variant.id))
                }
                else if project.captureStatuses[variant.id]?.archive != nil
                {
                    Button("Resume Download") { library.resume(project.id, captureID: variant.id) }
                        .disabled(!library.canStartWork || !project.hasAPIKey)
                }
                else { Button("Preview", action: {}).disabled(true) }
            }
            if let archive = project.captureStatuses[variant.id]?.archive, archive.state != .downloaded
            {
                Button("Adjust Area") { project.adjustCaptureArea(variant.id) }
                    .disabled(!library.canStartWork)
                Text("Opens an editable copy with this variant's area and detail. Adjust Width/Height, then Download Tiles to retry.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 6)
    }
}
