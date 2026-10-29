import SwiftUI

struct EarthProjectPreviewView: View
{
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        VStack(spacing: 0)
        {
            if project.phase != .idle
            {
                HStack
                {
                    ProgressView(project.progressText).controlSize(.small)
                    Spacer()
                    Button("Cancel", action: project.pause)
                }.padding(16)
            }
            if let error = project.jobError
            {
                Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
            }
            if project.phase == .idle, !project.preview.isLoading, !project.preview.hasPreview
            {
                Button("Refresh Preview") { library.refreshProject(project.id) }.disabled(!library.canStartWork)
            }
            if project.preview.isLoading { Button("Cancel Preview", action: project.pause) }
            if project.prepared != nil || project.preview.isLoading
            { EarthRegionPreviewView(viewModel: project.preview) }
            else
            {
                ContentUnavailableView(project.phase == .preparing ? "Preparing Downloaded Models" : "Preview Unavailable", systemImage: "globe.americas")
            }
        }
    }
}
