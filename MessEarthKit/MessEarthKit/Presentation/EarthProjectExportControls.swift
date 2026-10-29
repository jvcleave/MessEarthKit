import SwiftUI

struct EarthProjectExportControls: View
{
    let export: EarthProjectExportViewModel
    let variantID: UUID
    let isDownloaded: Bool
    let canStartWork: Bool
    let startExport: () -> Void

    var body: some View
    {
        let exports = export.exports(for: variantID)
        VStack(alignment: .leading, spacing: 8)
        {
            Divider()
            Text("Export").font(.subheadline.bold())
            HStack
            {
                Menu("Preset: \(export.presetName(for: variantID))")
                {
                    ForEach(EarthProjectExportPreset.allCases, id: \.self)
                    { preset in Button(preset.rawValue) { export.setPreset(preset, variantID: variantID) } }
                }.disabled(!canStartWork)
                Button(exports.isEmpty ? "Export GLB" : "Export Again", action: startExport)
                    .disabled(!isDownloaded || !canStartWork || export.isLoadingHistory || export.historyError != nil)
                if export.isLoadingHistory { ProgressView().controlSize(.small) }
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 6)
            {
                ForEach(EarthProjectExportField.allCases)
                { field in
                    Toggle(field.rawValue, isOn: Binding(
                        get: { export.options(for: variantID)[keyPath: field.keyPath] },
                        set: { export.setOption(field, included: $0, variantID: variantID) }
                    )).toggleStyle(.checkbox).disabled(!canStartWork)
                }
            }
            if export.variantID == variantID
            {
                if export.isLoading
                {
                    HStack
                    {
                        ProgressView().controlSize(.small)
                        Text(export.status).font(.caption)
                        Button("Cancel Export", action: export.cancel)
                    }
                }
                else if !export.status.isEmpty { Text(export.status).font(.caption) }
                if let error = export.errorMessage
                { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if let record = export.unrecordedExport
                { Button("Show Unrecorded File in Finder") { export.reveal(record) } }
            }
            ForEach(Array(exports.enumerated()), id: \.element.id)
            { index, item in
                VStack(alignment: .leading, spacing: 4)
                {
                    HStack
                    {
                        Text("Export \(exports.count - index) · \(item.record.includeTextures ? "With textures" : "Without textures")").font(.caption)
                        Spacer()
                        if item.fileIsAvailable
                        { Button("Show Export in Finder") { export.reveal(item.record) } }
                        else { Text("File unavailable").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(item.record.fileName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            if let error = export.historyError
            {
                Text("Export history: \(error)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Reload Export History", action: export.reloadHistory)
                    .disabled(!canStartWork || export.isLoadingHistory)
            }
        }
    }
}
