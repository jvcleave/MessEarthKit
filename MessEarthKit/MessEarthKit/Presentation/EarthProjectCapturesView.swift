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
            EarthProjectLocationView(location: location, project: project, library: library)
        }
        if !library.exportQueue.entries.isEmpty
        {
            Button(library.exportQueue.buttonTitle, action: library.showExportQueue)
        }
    }
}

struct EarthProjectCaptureCard: View
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
                    .disabled(!library.canDeleteCapture(project.id, captureID: variant.id))
            }
            Picker("Detail", selection: Binding(get: { variant.detail }, set: { project.setVariantDetail($0, captureID: variant.id) }))
            { ForEach(EarthProjectDetail.allCases) { Text($0.title).tag($0) } }
            .disabled(!project.canChangeVariantDetail(variant.id) || !library.canStartWork)
            if let archive = project.captureStatuses[variant.id]?.archive, archive.state != .downloaded,
               project.downloadJob(variant.id)?.phase.isActive != true
            {
                Button(archive.sourceRequests == 0 ? "Download" : "Resume Download") { library.download(project.id, captureID: variant.id) }
                    .disabled(!library.canStartWork || !project.canDownload(variant.id))
            }
            HStack(alignment: .firstTextBaseline, spacing: 4)
            {
                Text(project.captureStatus(variant.id)).font(.subheadline)
                if let summary = project.captureStatuses[variant.id]?.summary
                { Text("· \(summary)").font(.caption).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            if let error = project.captureError(variant.id)
            { EarthErrorMessage(error) }
            EarthProjectCaptureProgressView(captureID: variant.id, project: project)
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
            if project.captureStatuses[variant.id]?.archive?.state == .downloaded
            {
                EarthProjectExportControls(
                    export: project.export,
                    variantID: variant.id,
                    isDownloaded: true,
                    canStartWork: library.canStartWork && !project.isBusy && project.downloadJob(variant.id)?.phase.isActive != true,
                    startExport: { project.exportVariant(variant.id) },
                    canQueue: library.exportQueue.canEdit,
                    isQueued: library.isExportQueued(project.id, variantID: variant.id),
                    addToQueue: { library.addExportToQueue(project.id, variantID: variant.id) }
                )
            }
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 6)
    }
}

/// Both expanded cards and collapsed locations expose the same progress actions.
struct EarthProjectCaptureProgressView: View
{
    let captureID: UUID
    let project: EarthProjectViewModel

    var body: some View
    {
        if let job = project.downloadJob(captureID), job.phase.isActive
        {
            ProgressView(job.progressText).controlSize(.small)
            Button(job.phase == .queued ? "Remove from Queue" : job.phase == .downloading ? "Pause Download" : "Cancel")
            { project.pauseDownload(captureID) }.disabled(job.phase == .stopping)
        }
        else if project.operationCaptureID == captureID, project.phase != .idle
        {
            ProgressView(project.progressText).controlSize(.small)
            if project.phase != .deleting { Button(project.phase == .downloading ? "Pause Download" : "Cancel", action: project.pause) }
        }
        else if project.selectedCaptureID == captureID, project.preview.isLoading
        {
            ProgressView(project.preview.status).controlSize(.small)
            Button("Cancel Preview", action: project.pause)
        }
    }
}
