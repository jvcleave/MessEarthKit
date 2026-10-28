import SwiftUI

struct EarthCaptureRecoveryView: View
{
    let viewModel: EarthWorkspaceViewModel

    var body: some View
    {
        VStack(alignment: .leading, spacing: 8)
        {
            if let reason = viewModel.incompleteCaptureMessage
            {
                Label
                {
                    Text("Partial capture: \(reason) Only completed downloads are included; the full requested region is incomplete.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.orange)
                .textSelection(.enabled)
            }
            if viewModel.hasRecoverableDownload
            {
                HStack(spacing: 12)
                {
                    Text("Downloaded tiles are kept locally.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Last Download", action: viewModel.openLastDownload)
                    Button("Show Downloads", action: viewModel.showDownloads)
                }
                .disabled(viewModel.isLoading)
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
