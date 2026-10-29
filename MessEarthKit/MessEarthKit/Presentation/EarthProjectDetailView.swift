import MessEarthKit
import SwiftUI

struct EarthProjectDetailView: View
{
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        HSplitView
        {
            captureControls
                .frame(minWidth: 320, idealWidth: 360, maxWidth: 440)
            EarthProjectMapView(selection: project.confirmation, inputError: project.mapInputError)
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880)
        .task { await project.refreshCaptureStatuses() }
        .navigationTitle(project.displayTitle)
        .toolbar
        {
            if project.isSaving { ToolbarItem { ProgressView().controlSize(.small) } }
            ToolbarItem
            {
                Button("Refresh Project", systemImage: "arrow.clockwise") { library.refreshProject(project.id) }
                    .disabled(!library.canStartWork)
            }
        }
    }

    private var captureControls: some View
    {
        Form
        {
            Section("Project")
            {
                TextField("Title", text: Binding(get: { project.title }, set: project.setTitle))
            }
            .disabled(project.isBusy)
            Section("Capture area")
            {
                TextField("Address", text: Binding(get: { project.draft.address }, set: project.setAddress))
                    .onSubmit { library.updateMap(project.id) }
                Picker("Detail", selection: Binding(get: { project.draft.detail }, set: project.setDetail))
                {
                    ForEach(EarthProjectDetail.allCases) { Text($0.title).tag($0) }
                }
                TextField("Width (m)", text: Binding(get: { project.draft.widthMeters }, set: project.setWidth))
                TextField("Height (m)", text: Binding(get: { project.draft.heightMeters }, set: project.setHeight))
            }
            .disabled(project.isBusy)
            Section
            {
                Button("Update Map") { library.updateMap(project.id) }.disabled(!library.canStartWork)
                Button("Download Tiles") { library.download(project.id) }
                    .disabled(!project.canDownload || !project.hasAPIKey || !library.canStartWork)
                Text("Width, height and detail update the mapped selection as you edit.")
                    .font(.caption).foregroundStyle(.secondary)
                if project.phase != .idle, project.operationCaptureID == nil
                {
                    ProgressView(project.progressText).controlSize(.small)
                    if project.phase != .deleting { Button("Cancel", action: project.pause) }
                }
                if project.operationCaptureID == nil, let error = project.jobError
                { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if !project.hasAPIKey
                {
                    Text("Add an API key in Settings to download.").font(.caption).foregroundStyle(.secondary)
                    Button("Open Settings", action: library.showSettings)
                }
            }
            if let error = project.persistenceError
            {
                Section("Changes could not be saved")
                {
                    Text(error).foregroundStyle(.red)
                    Button("Retry Save", action: project.retrySave)
                }
            }
            EarthProjectCapturesView(project: project, library: library)
        }
        .formStyle(.grouped)
    }
}
