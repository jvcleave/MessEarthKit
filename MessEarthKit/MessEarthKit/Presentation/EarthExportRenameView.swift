import SwiftUI

struct EarthExportRenameView: View
{
    let viewModel: EarthExportRenameViewModel
    let canRename: Bool
    let rename: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View
    {
        VStack(alignment: .leading, spacing: 16)
        {
            Text("Rename Export").font(.headline)
            HStack
            {
                TextField("Filename", text: Binding(get: { viewModel.name }, set: viewModel.setName))
                    .textFieldStyle(.roundedBorder)
                Button("Auto", action: viewModel.useAutomaticName).disabled(viewModel.isResolving || !canRename)
                    .help("Use the city and coordinates of this export's capture.")
                if viewModel.isResolving { ProgressView().controlSize(.small) }
            }
            Text("Rename the exported file and its optional information companion. The .glb extension is kept.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = viewModel.errorMessage { EarthErrorMessage(error) }
            HStack
            {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename") { rename(); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(!canRename || viewModel.isResolving || viewModel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onDisappear(perform: viewModel.cancelLookup)
    }
}
