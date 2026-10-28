import SwiftUI

struct EarthCaptureControlsView: View
{
    let viewModel: EarthWorkspaceViewModel

    var body: some View
    {
        VStack(alignment: .leading, spacing: 12)
        {
            HStack(spacing: 12)
            {
                TextField("Address", text: Binding(get: { viewModel.address }, set: viewModel.setAddress))
                Button("Resolve Address", action: viewModel.resolveAddress).disabled(!viewModel.canResolveAddress)
            }
            HStack(spacing: 12)
            {
                EarthCaptureValueField(title: "Latitude", value: viewModel.latitude, action: viewModel.setLatitude)
                EarthCaptureValueField(title: "Longitude", value: viewModel.longitude, action: viewModel.setLongitude)
                EarthCaptureValueField(title: "Width (m)", value: viewModel.captureWidth, action: viewModel.setCaptureWidth)
                EarthCaptureValueField(title: "Depth (m)", value: viewModel.captureDepth, action: viewModel.setCaptureDepth)
                EarthCaptureValueField(title: "Detail error (m)", value: viewModel.detailError, action: viewModel.setDetailError)
                EarthCaptureValueField(title: "Maximum Requests", value: viewModel.maximumRequests, action: viewModel.setMaximumRequests)
                    .help("Positive whole number. Counts root and child tileset JSON plus GLB downloads per capture. Other capture limits still apply.")
            }
            HStack(spacing: 12)
            {
                SecureField("Google Maps Tile API key", text: Binding(get: { viewModel.apiKey }, set: viewModel.setAPIKey))
                Button("Capture Region", action: viewModel.captureRegion)
                    .buttonStyle(.borderedProminent).disabled(!viewModel.canCapture)
            }
            EarthCaptureCostView()
        }
        .textFieldStyle(.roundedBorder)
        .disabled(viewModel.isLoading)
        .padding(16)
    }
}

private struct EarthCaptureValueField: View
{
    let title: String
    let value: String
    let action: (String) -> Void

    var body: some View
    {
        VStack(alignment: .leading, spacing: 4)
        {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, text: Binding(get: { value }, set: action)).labelsHidden()
        }
    }
}
