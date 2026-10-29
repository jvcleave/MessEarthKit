import MessEarthKit
import SwiftUI

/// Each saved acquisition owns its actions. Opening files or a preview leaves
/// the editor alone; restoring the capture area is a separate explicit action.
struct EarthProjectCapturesView: View
{
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        Section("Capture variants")
        {
            if project.hasNewCaptureDraft
            {
                VStack(alignment: .leading, spacing: 6)
                {
                    Label("\(project.draft.detail.title) · New variant", systemImage: "plus.circle")
                        .font(.headline)
                    Text("Draft · \(project.draft.widthMeters) × \(project.draft.heightMeters) m")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Download Tiles saves this as a separate capture.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 4)
            }
            ForEach(project.captures.reversed())
            { variant in
                EarthProjectCaptureCard(variant: variant, project: project, library: library)
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
            if !variant.draft.address.isEmpty { Text(variant.draft.address).font(.caption).foregroundStyle(.secondary) }
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
            Button("Restore Capture Area") { library.restoreCaptureArea(project.id, captureID: variant.id) }
                .buttonStyle(.borderless)
                .disabled(!library.canStartWork)
        }
        .buttonStyle(.bordered)
        .padding(.vertical, 6)
    }
}
