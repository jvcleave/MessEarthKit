import MessEarthKit
import Observation
import SwiftUI

enum EarthModelExportMode: String, CaseIterable, Identifiable
{
    case separate = "Separate models"
    case combinedGLB = "Combined GLB"
    var id: Self { self }
}

@MainActor
@Observable
final class EarthModelExportViewModel
{
    private(set) var mode = EarthModelExportMode.separate
    private(set) var isLoading = false
    private(set) var summary = ""
    private(set) var issues: [String] = []
    private(set) var errorMessage: String?
    private(set) var canExportCombined = false
    @ObservationIgnored private var plan: EarthGLBExportPlan?
    @ObservationIgnored private let exporter = EarthGLBExporter()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func setMode(_ value: EarthModelExportMode) { mode = value; invalidate() }

    func invalidate()
    {
        task?.cancel()
        generation = UUID()
        plan = nil
        canExportCombined = false
        summary = ""
        issues = []
        errorMessage = nil
        // Keep the busy flag until cancellation finishes. A replacement job
        // must not overlap a still-active native decoder on the same exporter.
    }

    func cancel() { task?.cancel() }

    func check(collection: EarthPreparedCollection, selection: EarthModelSelection, destination: EarthPreparationProfile)
    {
        guard !isLoading else { return }
        invalidate()
        let job = UUID()
        generation = job
        isLoading = true
        summary = "Checking selected models offline…"
        task = Task
        { [weak self, exporter] in
            defer { self?.isLoading = false; self?.task = nil }
            do
            {
                let result = try await exporter.preflight(collection: collection, selection: selection, destination: destination)
                { [weak self] progress in
                    Task
                    { @MainActor [weak self] in
                        guard let self, generation == job, isLoading else { return }
                        summary = "Checking models: \(progress.completedModels.formatted()) / \(progress.totalModels.formatted())"
                    }
                }
                try Task.checkCancellation()
                guard let self, generation == job else { return }
                plan = result
                canExportCombined = result.canExport
                issues = result.issues
                let bytes = result.outputByteCount.map { " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                let noun = result.selectedModelCount == 1 ? "model" : "models"
                summary = "\(result.selectedModelCount.formatted()) \(noun) → one GLB\(bytes)"
            }
            catch
            {
                if let self, generation == job
                {
                    if error is CancellationError { summary = "Check cancelled" }
                    else { errorMessage = error.localizedDescription; summary = "Combined export check failed" }
                }
            }
        }
    }

    func saveCombined(to fileURL: URL, progress: @escaping @Sendable (EarthGLBExportProgress) -> Void) async throws -> URL
    {
        guard let plan, canExportCombined else { throw EarthGLBExportError.requirements(["Check the current selection before saving."]) }
        return try await exporter.export(plan: plan, fileURL: fileURL, progress: progress)
    }
}

struct EarthModelExportView: View
{
    let viewModel: EarthWorkspaceViewModel

    var body: some View
    {
        let export = viewModel.modelExport
        VStack(alignment: .leading, spacing: 8)
        {
            Text("Export selected models").font(.headline)
            Picker("Export", selection: Binding(get: { export.mode }, set: viewModel.setExportMode))
            {
                ForEach(EarthModelExportMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isLoading)
            if export.mode == .combinedGLB
            {
                Text("One file keeps the selected models' placement, materials and textures.").foregroundStyle(.secondary)
                if !export.summary.isEmpty { Text(export.summary).textSelection(.enabled) }
                ForEach(export.issues, id: \.self) { Text($0).foregroundStyle(.orange).textSelection(.enabled) }
                if !export.issues.isEmpty { Text("Choose fewer models, export separately, or adjust the destination in Advanced.").foregroundStyle(.secondary) }
                if let error = export.errorMessage { EarthErrorMessage(error, color: .orange) }
                Button("Check Combined GLB", action: viewModel.checkCombinedExport)
                    .disabled(viewModel.isLoading || viewModel.preparedModels.selectedCount == 0)
            }
        }
        .font(.callout)
        .padding(16)
    }
}
