import MessEarthKit
import SwiftUI

struct EarthLocationEditorView: View
{
    let location: EarthLocationRecord
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        Section("Location")
        {
            TextField("Name", text: Binding(get: { project.editingLocation?.title ?? "" }, set: project.setLocationTitle))
            Group
            {
                TextField("Width (m)", text: Binding(get: { project.displayedLocationArea?.widthMeters ?? "" }, set: project.setWidth))
                TextField("Height (m)", text: Binding(get: { project.displayedLocationArea?.heightMeters ?? "" }, set: project.setHeight))
                Button("Move to Map Center") { if let center = project.mapCenter { project.setLocationCenter(center) } }
                    .disabled(project.mapCenter == nil)
            }.disabled(location.isFrozen)
            if location.isFrozen
            {
                Text("Capture area frozen. Adjust Area opens an editable copy to move or resize.").font(.caption).foregroundStyle(.secondary)
                Button("Adjust Area") { project.copyLocation(location.id) }
            }
            if let detail = location.variantDetail
            {
                Picker("Variant detail", selection: Binding(get: { project.editingLocation?.variantDetail ?? detail }, set: project.setDetail))
                { ForEach(EarthProjectDetail.allCases) { Text($0.title).tag($0) } }
                Button("Download Tiles") { library.download(project.id) }
                    .disabled(!project.canDownload || !project.hasAPIKey || !library.canStartWork)
            }
            else { Button("Add Variant") { project.addVariant(location.id) } }
        }
        .disabled(project.isBusy || !library.canStartWork)
    }
}
