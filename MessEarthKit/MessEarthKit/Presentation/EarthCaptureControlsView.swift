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
            }
            HStack(spacing: 12)
            {
                EarthCaptureValueField(title: "Maximum Requests", value: viewModel.maximumRequests, action: viewModel.setMaximumRequests)
                    .help("Positive whole number. Counts root and child tileset JSON plus GLB downloads per capture. Other capture limits still apply.")
                EarthCaptureValueField(title: "Maximum Tiles", value: viewModel.maximumTiles, action: viewModel.setMaximumTiles)
                    .help("Positive whole number. Limits selected GLB tile placements per capture, including placements that reuse a download. Other capture limits still apply.")
                EarthCaptureValueField(title: "Maximum Vertices", value: viewModel.maximumVertices, action: viewModel.setMaximumVertices)
                    .help("Positive whole number. Limits total decoded vertices across the capture. Applies to capture, recovery, and local-file imports.")
                EarthCaptureValueField(title: "Maximum Textures (MiB)", value: viewModel.maximumTexturesMiB, action: viewModel.setMaximumTexturesMiB)
                    .help("Positive whole number. Limits total base-level decoded RGBA texture bytes across the capture. One MiB is 1,048,576 bytes. Applies to capture, inspection, recovery, and local imports.")
            }
            HStack(spacing: 12)
            {
                SecureField("Google Maps Tile API key", text: Binding(get: { viewModel.apiKey }, set: viewModel.setAPIKey))
                Button("Inspect via API", action: viewModel.precheckRegion)
                    .disabled(!viewModel.canPrecheck)
                    .help("Uses a Google session. Discovers tiles first, then downloads GLBs within the request/tile budgets to estimate geometry. Completed downloads are reused by Capture.")
                Button("Capture Region", action: viewModel.captureRegion)
                    .buttonStyle(.borderedProminent).disabled(!viewModel.canCapture)
            }
            EarthCaptureCostView()
            if let display = viewModel.precheckDisplay
            { EarthCaptureEstimateView(title: "API inspection", rows: display.rows, detail: display.detail) }
            else if let display = viewModel.offlineEstimateDisplay
            { EarthCaptureEstimateView(title: "Offline estimate", rows: display.rows, detail: display.detail) }
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
