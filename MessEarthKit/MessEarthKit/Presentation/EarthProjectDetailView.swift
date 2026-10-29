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
            EarthProjectMapView(project: project, library: library)
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
            Section("Find a starting point")
            {
                LabeledContent("Address")
                {
                    EarthAddressField(
                        text: project.searchAddress,
                        onChange: project.setAddress,
                        onSubmit: { library.updateMap(project.id) }
                    )
                }
                Button("Update Map") { library.updateMap(project.id) }.disabled(!library.canStartWork)
                Button("Add Location", action: project.addLocation).disabled(!library.canStartWork || project.mapCenter == nil)
                Text("Searching and browsing move the map. Add Location creates a capture area there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(project.isBusy)
            EarthProjectCapturesView(project: project, library: library)
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
            if let error = project.persistenceError
            {
                Section("Changes could not be saved")
                {
                    Text(error).foregroundStyle(.red)
                    Button("Retry Save", action: project.retrySave)
                }
            }
        }
        .formStyle(.grouped)
    }
}
