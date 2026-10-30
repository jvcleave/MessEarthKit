import MessEarthKit
import SwiftUI

struct EarthProjectPreviewView: View
{
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        VStack(spacing: 0)
        {
            if let collection = project.prepared, collection.modelCount > 1
            {
                HStack
                {
                    Picker("Preview", selection: Binding(
                        get: { project.preview.selectedPartOffset != nil },
                        set: { parts in
                            if parts { project.preview.showPart(collection, offset: 0) }
                            else { project.preview.showEntireRegion(collection) }
                        }
                    ))
                    {
                        Text("Entire Region").tag(false)
                        Text("Model Parts").tag(true)
                    }.pickerStyle(.segmented).frame(maxWidth: 320)
                    if let offset = project.preview.selectedPartOffset
                    {
                        Button("Previous", systemImage: "chevron.left") { project.preview.showPart(collection, offset: offset - 1) }
                            .disabled(offset == 0)
                        Text("Part \(offset + 1) of \(collection.modelCount)").monospacedDigit()
                        Button("Next", systemImage: "chevron.right") { project.preview.showPart(collection, offset: offset + 1) }
                            .disabled(offset + 1 >= collection.modelCount)
                    }
                    Spacer()
                    if let captureID = project.selectedCaptureID
                    { Button("Reveal Models") { project.revealCapture(captureID, preparedModels: true) } }
                }
                .disabled(!library.canStartWork || project.isBusy)
                .padding(16)
            }
            if let collection = project.prepared
            {
                displayControls(collection)
                memoryControls(collection)
            }
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
                EarthErrorMessage(error).padding()
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

    private func displayControls(_ collection: EarthPreparedCollection) -> some View
    {
        HStack(spacing: 16)
        {
            Picker("Display", selection: Binding(
                get: { project.preview.displayMode },
                set: { project.preview.setDisplayMode($0, collection: collection) }
            ))
            {
                ForEach(EarthPreviewDisplayMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.menu).frame(maxWidth: 360)
            Text("Changing display reloads the preview. Solid and Wireframe skip textures; geometry memory limits still apply.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .disabled(!library.canStartWork || project.isBusy || project.preview.memoryBudgetError != nil)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func memoryControls(_ collection: EarthPreparedCollection) -> some View
    {
        VStack(alignment: .leading, spacing: 6)
        {
            HStack
            {
                Toggle("Automatic preview memory", isOn: Binding(
                    get: { project.preview.usesAutomaticMemoryBudget },
                    set: project.preview.setUsesAutomaticMemoryBudget
                )).toggleStyle(.switch)
                if !project.preview.usesAutomaticMemoryBudget
                {
                    Text("Budget (GiB)")
                    TextField("Budget (GiB)", text: Binding(
                        get: { project.preview.customMemoryBudgetGiB },
                        set: project.preview.setCustomMemoryBudgetGiB
                    ))
                    .textFieldStyle(.roundedBorder).frame(width: 80)
                    .onSubmit { project.preview.reload(collection) }
                }
                Button("Reload Preview") { project.preview.reload(collection) }
                    .disabled(project.preview.memoryBudgetError != nil)
                Spacer()
            }
            Text("Automatic scales the budget to this Mac. Changes apply on reload and reset to Automatic when the app restarts.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = project.preview.memoryBudgetError
            { EarthErrorMessage(error).font(.caption) }
        }
        .disabled(!library.canStartWork || project.isBusy)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }
}
