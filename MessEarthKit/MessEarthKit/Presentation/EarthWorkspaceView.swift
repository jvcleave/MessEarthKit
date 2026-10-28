import SwiftUI

struct EarthWorkspaceView: View
{
    let viewModel: EarthWorkspaceViewModel

    var body: some View
    {
        VStack(spacing: 0)
        {
            HStack(alignment: .center, spacing: 16)
            {
                VStack(alignment: .leading, spacing: 4)
                {
                    Text(viewModel.title).font(.title2.weight(.semibold))
                    if !viewModel.summary.isEmpty { Text(viewModel.summary).font(.callout).foregroundStyle(.secondary) }
                }
                Spacer()
                if viewModel.isLoading { ProgressView().controlSize(.small) }
                Text(viewModel.status).font(.callout).foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            EarthCaptureControlsView(viewModel: viewModel)
            Divider()
            if viewModel.hasRecoverableDownload || viewModel.incompleteCaptureMessage != nil
            {
                EarthCaptureRecoveryView(viewModel: viewModel)
                Divider()
            }
            ZStack
            {
                if viewModel.hasPreview, let renderer = viewModel.renderer
                {
                    EarthPreviewView(renderer: renderer, revision: viewModel.previewRevision)
                }
                else
                {
                    ContentUnavailableView("Open a 3D Capture", systemImage: "globe.americas", description: Text("Load the reference scene or open a local GLB or tileset folder."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = viewModel.errorMessage
            {
                Divider()
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            Divider()
            HStack(spacing: 12)
            {
                Button("Load Reference", action: viewModel.loadReference)
                    .disabled(viewModel.isLoading)
                Button("Open GLB…", action: viewModel.chooseGLB)
                    .disabled(viewModel.isLoading)
                Button("Open Tileset Folder…", action: viewModel.chooseTilesetFolder)
                    .disabled(viewModel.isLoading)
                Button("Save Capture…", action: viewModel.saveCapture)
                    .disabled(viewModel.isLoading || !viewModel.hasPreview)
                if viewModel.hasSavedCapture { Button("Show in Finder", action: viewModel.showSavedCapture) }
                Spacer()
                if viewModel.isLoading
                {
                    Button("Cancel", action: viewModel.cancelImport)
                }
                else
                {
                    Button("Reset View", action: viewModel.resetView).disabled(!viewModel.hasPreview)
                }
            }
            .padding(16)
            if !viewModel.attribution.isEmpty
            {
                Text(viewModel.attribution).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        .frame(minWidth: 1000, minHeight: 720)
        .onDisappear { viewModel.cancelImport() }
    }
}

#Preview
{
    EarthWorkspaceView(viewModel: EarthWorkspaceViewModel())
}
