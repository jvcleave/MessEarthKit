import SwiftUI

struct EarthCaptureCostView: View
{
    // Global Photorealistic 3D Tiles list rate, verified October 28, 2026.
    // Precheck and uncached capture each start one root session.
    private let standardSessionPriceUSD = Decimal(6) / 1000
    private let pricingURL = URL(string: "https://developers.google.com/maps/billing-and-pricing/pricing")!

    var body: some View
    {
        VStack(alignment: .leading, spacing: 4)
        {
            HStack(alignment: .firstTextBaseline, spacing: 12)
            {
                Label
                {
                    Text("Estimated API cost: \(standardSessionPriceUSD, format: .currency(code: "USD").precision(.fractionLength(3))) USD per new Google session")
                } icon: {
                    Image(systemName: "dollarsign.circle")
                }
                .font(.callout)
                Spacer()
                Link("Google pricing", destination: pricingURL)
                    .font(.caption)
            }
            Text("$0 when your billing account's shared 1,000/month free allowance remains. This app can't check that balance.")
            Text("Offline estimates make no Google calls. Inspect via API starts a session. Capture reuses a completed inspection; otherwise it starts a new session.")
            Text("Global USD list rate before taxes or account discounts · Checked October 28, 2026")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .help("A new session can count even if the capture later fails or is cancelled. This estimate is not your Google billing total.")
    }
}
