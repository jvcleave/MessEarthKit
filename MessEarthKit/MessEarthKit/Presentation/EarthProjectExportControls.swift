import SwiftUI

struct EarthProjectExportControls: View
{
    let export: EarthProjectExportViewModel
    let variantID: UUID
    let isDownloaded: Bool
    let canStartWork: Bool
    let startExport: () -> Void
    @State private var requestedAction: ExportAction?
    @State private var exportName = ""

    private enum ExportAction
    {
        case rename(EarthProjectExportRecord), delete(EarthProjectExportRecord)

        var title: String
        {
            switch self
            {
                case .rename: "Rename Export"
                case .delete: "Delete Export?"
            }
        }
    }

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
                if export.isLoadingHistory || export.isManagingHistory { ProgressView().controlSize(.small) }
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
                    HStack
                    {
                        Button("Rename…")
                        {
                            exportName = String(item.record.fileName.dropLast(4))
                            requestedAction = .rename(item.record)
                        }.disabled(!item.fileIsAvailable || !canStartWork || export.isLoadingHistory)
                        Button("Delete…", role: .destructive) { requestedAction = .delete(item.record) }
                            .disabled(!canStartWork || export.isLoadingHistory)
                    }
                }
            }
            if let error = export.managementError
            { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let error = export.historyError
            {
                Text("Export history: \(error)").font(.caption).foregroundStyle(.red).textSelection(.enabled)
                Button("Reload Export History", action: export.reloadHistory)
                    .disabled(!canStartWork || export.isLoadingHistory)
            }
        }
        .alert(
            requestedAction?.title ?? "Export",
            isPresented: Binding(get: { requestedAction != nil }, set: { if !$0 { requestedAction = nil } }),
            presenting: requestedAction
        )
        { action in
            switch action
            {
                case let .rename(record):
                    TextField("Filename", text: $exportName)
                    Button("Rename") { if canStartWork { export.rename(record, to: exportName) } }
                        .disabled(exportName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                case let .delete(record):
                    Button("Move to Trash", role: .destructive) { if canStartWork { export.delete(record) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action
            {
                case .rename: Text("Rename the exported file and its optional information companion. The .glb extension is kept.")
                case let .delete(record): Text("Move “\(record.fileName)” and its export folder to Trash and remove it from export history? The variant’s downloads and prepared models are kept. If the file is already missing, only its history entry and any remaining export folder are removed.")
            }
        }
    }
}
