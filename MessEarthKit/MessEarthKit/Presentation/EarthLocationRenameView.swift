import SwiftUI

struct EarthLocationRenameView: View
{
    let viewModel: EarthLocationRenameViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View
    {
        VStack(alignment: .leading, spacing: 16)
        {
            Text("Rename Location").font(.headline)
            HStack
            {
                TextField("Name", text: Binding(get: { viewModel.name }, set: viewModel.setName))
                    .textFieldStyle(.roundedBorder).disabled(viewModel.isSaving)
                Button("Auto", action: viewModel.useAutomaticName)
                    .disabled(viewModel.isResolving || viewModel.isSaving)
                    .help("Use the city and coordinates of this location.")
                if viewModel.isResolving || viewModel.isSaving { ProgressView().controlSize(.small) }
            }
            if let error = viewModel.errorMessage { EarthErrorMessage(error) }
            HStack
            {
                Spacer()
                Button("Cancel") { viewModel.cancelLookup(); dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(viewModel.isSaving)
                Button("Rename", action: viewModel.save).keyboardShortcut(.defaultAction)
                    .disabled(viewModel.isSaving || viewModel.isResolving || viewModel.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(viewModel.isSaving)
        .onChange(of: viewModel.didSave) { if viewModel.didSave { dismiss() } }
        .onDisappear(perform: viewModel.cancelLookup)
    }
}
