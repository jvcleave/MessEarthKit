import SwiftUI

/// Changes apply only to the new optimized delivery, never the captured source.
struct EarthExportOptimizationControls: View
{
    let settings: EarthExportOptimizationSettings
    var showsTextureOptions = true
    let setSettings: (EarthExportOptimizationSettings) -> Void

    var body: some View
    {
        VStack(alignment: .leading, spacing: 8)
        {
            HStack
            {
                Text("Target triangles")
                Slider(value: Binding(get: { settings.triangleFraction }, set: { var value = settings; value.triangleFraction = $0; setSettings(value) }), in: 0.05 ... 1, step: 0.05)
                Text(settings.triangleFraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().frame(width: 45, alignment: .trailing)
            }
            HStack
            {
                Text("Maximum geometry error (m)")
                TextField("Meters", value: Binding(get: { settings.maximumErrorMeters }, set: { var value = settings; value.maximumErrorMeters = $0; setSettings(value) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
            }
            if showsTextureOptions
            {
                Picker("Maximum texture edge", selection: Binding(get: { settings.maximumTextureDimension }, set: { var value = settings; value.maximumTextureDimension = $0; setSettings(value) }))
                {
                    Text("Original size").tag(Int?.none)
                    ForEach([8192, 4096, 2048, 1024], id: \.self) { edge in Text("\(edge) px").tag(Int?.some(edge)) }
                }
                Text("The error limit and protected mesh borders can keep more triangles than the target. Texture resizing changes appearance. Source files are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
