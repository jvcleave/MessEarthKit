import SwiftUI

struct EarthExportViewerView: View
{
    let viewModel: EarthExportViewerViewModel

    var body: some View
    {
        VStack(spacing: 0)
        {
            HStack
            {
                if let request = viewModel.request, !viewModel.choices.isEmpty
                {
                    Picker("Export", selection: Binding(get: { request.exportID }, set: viewModel.selectExport))
                    {
                        ForEach(viewModel.choices) { choice in Text(choice.title).tag(choice.id).disabled(!choice.isAvailable) }
                    }
                }
                else { Text(viewModel.fileName).font(.headline) }
                Spacer()
                Button("Frame All", action: viewModel.frameAll).disabled(viewModel.renderer == nil)
            }
            .padding(12)
            if !viewModel.summary.isEmpty
            { Text(viewModel.summary).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 12) }
            Divider()
            if let renderer = viewModel.renderer
            {
                EarthPreviewView(renderer: renderer, revision: viewModel.revision, allowsPanning: true)
                    .id(ObjectIdentifier(renderer))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            else
            {
                VStack(spacing: 12)
                {
                    if viewModel.isLoading
                    {
                        ProgressView(viewModel.status)
                        Button("Cancel", action: viewModel.cancel)
                    }
                    else
                    {
                        Text(viewModel.status).foregroundStyle(.secondary)
                        if let error = viewModel.errorMessage { EarthErrorMessage(error) }
                        if viewModel.request != nil { Button("Retry", action: viewModel.retry) }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4)
            {
                Text("Drag to orbit - Shift-drag or right-drag to pan - Scroll to zoom").foregroundStyle(.secondary)
                if !viewModel.attribution.isEmpty { Text(viewModel.attribution).textSelection(.enabled) }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 480)
        .onDisappear(perform: viewModel.close)
    }
}
