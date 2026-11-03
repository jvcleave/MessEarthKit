import SwiftUI

struct EarthProjectExportControls: View
{
    let export: EarthProjectExportViewModel
    let variantID: UUID
    let isDownloaded: Bool
    let canStartWork: Bool
    let startExport: () -> Void
    let canQueue: Bool
    let isQueued: Bool
    let addToQueue: () -> Void
    @Environment(EarthExportViewerViewModel.self) private var viewer
    @Environment(\.openWindow) private var openWindow
    @State private var renameDraft: EarthExportRenameViewModel?
    @State private var deletingExport: EarthProjectExportRecord?

    var body: some View
    {
        let exports = export.exports(for: variantID)
        VStack(alignment: .leading, spacing: 8)
        {
            Divider()
            Text("Export").font(.subheadline.bold())
            Picker("Format", selection: Binding(get: { export.format(for: variantID) }, set: { export.setFormat($0, variantID: variantID) }))
            {
                ForEach(EarthExportFormat.allCases) { format in Text(format.rawValue).tag(format) }
            }.disabled(!canStartWork)
            if export.format(for: variantID).isOptimized
            {
                EarthExportOptimizationControls(settings: export.optimization(for: variantID), showsTextureOptions: export.format(for: variantID) == .optimizedUSDZ, setSettings: { export.setOptimization($0, variantID: variantID) })
                    .disabled(!canStartWork)
            }
            HStack
            {
                Button("Export \(export.format(for: variantID).rawValue)", action: startExport)
                    .disabled(!isDownloaded || !canStartWork || export.isLoadingHistory || export.historyError != nil)
                Button(isQueued ? "Already queued" : "ADD TO QUEUE", action: addToQueue)
                    .disabled(!isDownloaded || !canStartWork || !canQueue || isQueued || export.isLoadingHistory || export.historyError != nil)
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
                { EarthErrorMessage(error).font(.caption) }
                if let record = export.unrecordedExport
                { Button("Show Unrecorded File in Finder") { export.reveal(record) } }
            }
            ForEach(exports)
            { item in
                VStack(alignment: .leading, spacing: 4)
                {
                    Text(item.deliverySummary).font(.caption.bold())
                    Text(item.contentsSummary).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if !item.fileIsAvailable { Text("File unavailable").font(.caption).foregroundStyle(.secondary) }
                    if let error = item.contentsError
                    { EarthErrorMessage(error).font(.caption) }
                    Text(item.record.fileName).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack
                    {
                        Button("VIEW")
                        {
                            viewer.open(.init(projectID: export.projectID, variantID: variantID, exportID: item.id), title: item.record.fileName)
                            openWindow(id: "export-viewer")
                        }.disabled(!item.fileIsAvailable || !canStartWork)
                        Button("Rename…")
                        {
                            renameDraft = export.renameDraft(for: item.record)
                        }.disabled(!item.fileIsAvailable || !canStartWork || export.isLoadingHistory || viewerIsReading(item.record))
                        Button("Delete…", role: .destructive) { deletingExport = item.record }
                            .disabled(!canStartWork || export.isLoadingHistory || viewerIsReading(item.record))
                        if item.fileIsAvailable
                        { Button("Show in Finder") { export.reveal(item.record) } }
                    }
                    .controlSize(.small)
                    .lineLimit(1)
                }
            }
            if let error = export.managementError
            { EarthErrorMessage(error).font(.caption) }
            if let error = export.historyError
            {
                EarthErrorMessage("Export history: \(error)").font(.caption)
                Button("Reload Export History", action: export.reloadHistory)
                    .disabled(!canStartWork || export.isLoadingHistory)
            }
        }
        .sheet(item: $renameDraft)
        { draft in
            EarthExportRenameView(viewModel: draft, canRename: canStartWork && !viewerIsReading(draft.record))
            { if canStartWork && !viewerIsReading(draft.record) { export.rename(draft.record, to: draft.name) } }
        }
        .alert(
            "Delete Export?",
            isPresented: Binding(get: { deletingExport != nil }, set: { if !$0 { deletingExport = nil } }),
            presenting: deletingExport
        )
        { record in
            Button("Move to Trash", role: .destructive) { if canStartWork && !viewerIsReading(record) { export.delete(record) } }
            Button("Cancel", role: .cancel) {}
        } message: { record in
            Text("Move “\(record.fileName)” and its export folder to Trash and remove it from export history? The variant’s downloads and prepared models are kept. If the file is already missing, only its history entry and any remaining export folder are removed.")
        }
    }

    private func viewerIsReading(_ record: EarthProjectExportRecord) -> Bool
    { viewer.isLoading && viewer.request?.projectID == export.projectID && viewer.request?.exportID == record.id }
}
