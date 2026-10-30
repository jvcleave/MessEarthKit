import MessEarthKit
import SwiftUI

struct EarthLocationEditorView: View
{
    let location: EarthLocationRecord
    let project: EarthProjectViewModel
    let library: EarthProjectLibraryViewModel

    var body: some View
    {
        Group
        {
            TextField("Name", text: Binding(get: { project.editingLocation?.title ?? "" }, set: project.setLocationTitle))
                .disabled(project.areaAdjustment != nil)
            Group
            {
                TextField("Width (m)", text: Binding(get: { project.displayedLocationArea?.widthMeters ?? "" }, set: project.setWidth))
                TextField("Height (m)", text: Binding(get: { project.displayedLocationArea?.heightMeters ?? "" }, set: project.setHeight))
            }.disabled(location.isFrozen)
            if project.areaAdjustment != nil
            {
                HStack
                {
                    Button("Apply Area", action: project.applyAreaAdjustment).disabled(!project.canApplyAreaAdjustment)
                    Button("Cancel Adjustment", action: project.cancelAreaAdjustment)
                }
            }
            else if location.isFrozen
            {
                Button("Adjust Area") { project.adjustLocationArea(location.id) }
                    .disabled(!project.canAdjustArea(location.id))
            }
            if project.areaAdjustment != nil
            {
                Text("Move or resize the capture box, then Apply Area to update all pending variants. Earlier download files are retained.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            else
            {
                Button("Add Variant") { project.addVariant(location.id) }
                    .disabled(!project.canAddVariant || !library.canStartWork)
            }
        }
        .disabled(project.isBusy || !library.canStartWork)
    }
}
