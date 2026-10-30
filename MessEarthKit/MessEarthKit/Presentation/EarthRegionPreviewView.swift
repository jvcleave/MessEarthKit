import SwiftUI

/// A single region scene; prepared part counts and selection stay internal.
struct EarthRegionPreviewView: View
{
    let viewModel: EarthRegionPreviewViewModel

    var body: some View
    {
        VStack(spacing: 0)
        {
            VStack(alignment: .leading, spacing: 6)
            {
                if !viewModel.summary.isEmpty { Text(viewModel.summary).foregroundStyle(.secondary) }
                if viewModel.isLoading { ProgressView(viewModel.status).controlSize(.small) }
                else if !viewModel.hasPreview { Text(viewModel.status).foregroundStyle(.secondary) }
                if let notice = viewModel.appearanceNotice { Text(notice).foregroundStyle(.orange) }
                if let error = viewModel.errorMessage { EarthErrorMessage(error) }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            Divider()
            if viewModel.hasPreview, let renderer = viewModel.renderer
            {
                EarthPreviewView(renderer: renderer, revision: viewModel.revision)
                    .id(ObjectIdentifier(renderer))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else
            {
                ContentUnavailableView(viewModel.isLoading ? "Preparing Preview" : "Preview Unavailable", systemImage: "globe.americas")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4)
            {
                Text("Drag to orbit · Scroll to zoom").foregroundStyle(.secondary)
                if !viewModel.attribution.isEmpty { Text(viewModel.attribution).textSelection(.enabled) }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .toolbar
        {
            ToolbarItem(placement: .primaryAction)
            {
                Button("Reset View", action: viewModel.resetCamera).disabled(!viewModel.hasPreview)
            }
        }
    }
}
