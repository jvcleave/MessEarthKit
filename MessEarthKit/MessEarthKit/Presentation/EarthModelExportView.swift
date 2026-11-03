import MessEarthKit
import Observation
import SwiftUI

enum EarthModelExportMode: String, CaseIterable, Identifiable
{
    case separate = "Separate models"
    case combinedGLB = "GLB"
    case optimizedGLB = "Optimized GLB"
    case combinedUSDZ = "USDZ"
    case optimizedUSDZ = "Optimized USDZ"

    var format: EarthExportFormat?
    {
        switch self
        {
            case .separate: nil
            case .combinedGLB: .glb
            case .optimizedGLB: .optimizedGLB
            case .combinedUSDZ: .usdz
            case .optimizedUSDZ: .optimizedUSDZ
        }
    }

    var id: Self { self }
}

@MainActor
@Observable
final class EarthModelExportViewModel
{
    private(set) var mode = EarthModelExportMode.separate
    private(set) var options = EarthExportOptions(includeNormals: false)
    private(set) var optimization = EarthExportOptimizationSettings()
    private(set) var isLoading = false
    private(set) var summary = ""
    private(set) var issues: [String] = []
    private(set) var errorMessage: String?
    private(set) var canExportCombined = false
    private enum DeliveryPlan
    {
        case glb(EarthGLBExportPlan)
        case usdz(EarthUSDZExportPlan)
    }

    @ObservationIgnored private var plan: DeliveryPlan?
    @ObservationIgnored private let exporter = EarthGLBExporter()
    @ObservationIgnored private let usdzExporter = EarthUSDZExporter()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()

    func setMode(_ value: EarthModelExportMode) { mode = value; invalidate() }
    func setOptimization(_ value: EarthExportOptimizationSettings) { optimization = value; invalidate() }
    func setOption(_ field: EarthProjectExportField, included: Bool)
    {
        options[keyPath: field.keyPath] = included
        switch field
        {
            case .textures:
                if included { options.includeMaterials = true; options.includeTextureCoordinates = true }
            case .materials, .textureCoordinates:
                if !included { options.includeTextures = false }
            case .vertexColors: break
        }
        invalidate()
    }

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
        guard !isLoading, let format = mode.format else { return }
        let options = options
        let optimization = optimization
        invalidate()
        let job = UUID()
        generation = job
        isLoading = true
        summary = "Checking selected models offline…"
        task = Task
        { [weak self, exporter, usdzExporter] in
            defer { self?.isLoading = false; self?.task = nil }
            do
            {
                let progress: @Sendable (EarthGLBExportProgress) -> Void = { [weak self] progress in
                    Task
                    { @MainActor [weak self] in
                        guard let self, generation == job, isLoading else { return }
                        summary = "Checking models: \(progress.completedModels.formatted()) / \(progress.totalModels.formatted())"
                    }
                }
                let selectedCount: Int
                let result: DeliveryPlan
                let requirements: [String]
                let canExport: Bool
                let bytes: String
                if format.isGLB
                {
                    let profile = format == .optimizedGLB ? try optimization.meshProfile() : nil
                    let value = try await exporter.preflight(collection: collection, selection: selection, destination: destination, options: options, optimization: profile, progress: progress)
                    result = .glb(value)
                    selectedCount = value.selectedModelCount
                    requirements = value.issues
                    canExport = value.canExport
                    bytes = value.outputByteCount.map { " - " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? ""
                }
                else
                {
                    let profile = format == .optimizedUSDZ ? try optimization.profile() : nil
                    let value = try await usdzExporter.preflight(collection: collection, selection: selection, destination: destination, options: options, optimization: profile, progress: progress)
                    result = .usdz(value)
                    selectedCount = value.selectedModelCount
                    requirements = value.issues
                    canExport = value.canExport
                    bytes = ""
                }
                try Task.checkCancellation()
                guard let self, generation == job else { return }
                plan = result
                canExportCombined = canExport
                issues = requirements
                let noun = selectedCount == 1 ? "model" : "models"
                summary = "\(selectedCount.formatted()) \(noun) → one \(format.rawValue)\(bytes)"
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
        switch plan
        {
            case let .glb(value): return try await exporter.export(plan: value, fileURL: fileURL, progress: progress)
            case let .usdz(value): return try await usdzExporter.export(plan: value, fileURL: fileURL, progress: progress).fileURL
        }
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
            if let format = export.mode.format
            {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading)
                {
                    ForEach(EarthProjectExportField.allCases)
                    { field in
                        Toggle(field.rawValue, isOn: Binding(get: { export.options[keyPath: field.keyPath] }, set: { viewModel.setExportOption(field, included: $0) }))
                            .toggleStyle(.checkbox).disabled(viewModel.isLoading)
                    }
                }
                if format.isOptimized
                {
                    EarthExportOptimizationControls(settings: export.optimization, showsTextureOptions: format == .optimizedUSDZ, setSettings: viewModel.setExportOptimization)
                        .disabled(viewModel.isLoading)
                }
                Text("One file keeps the selected models' placement, materials and textures.").foregroundStyle(.secondary)
                if !export.summary.isEmpty { Text(export.summary).textSelection(.enabled) }
                ForEach(export.issues, id: \.self) { Text($0).foregroundStyle(.orange).textSelection(.enabled) }
                if !export.issues.isEmpty { Text("Choose fewer models, export separately, or adjust the destination in Advanced.").foregroundStyle(.secondary) }
                if let error = export.errorMessage { EarthErrorMessage(error, color: .orange) }
                Button("Check \(format.rawValue)", action: viewModel.checkCombinedExport)
                    .disabled(viewModel.isLoading || viewModel.preparedModels.selectedCount == 0)
            }
        }
        .font(.callout)
        .padding(16)
    }
}
