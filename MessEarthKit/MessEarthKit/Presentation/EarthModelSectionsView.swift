import MessEarthKit
import SwiftUI

enum EarthCaptureDetail: String, CaseIterable, Identifiable
{
    case preview = "Preview", standard = "Standard", high = "High", custom = "Custom"
    var id: Self { self }
    var errorMeters: String?
    {
        switch self
        {
            case .preview: "16"
            case .standard: "4"
            case .high: "1"
            case .custom: nil
        }
    }
}

struct EarthModelSectionDisplayItem: Identifiable
{
    let id: Int
    let title: String
    let isIncluded: Bool
    let isPreviewed: Bool
}

struct EarthModelSectionsView: View
{
    let viewModel: EarthWorkspaceViewModel

    var body: some View
    {
        VStack(alignment: .leading, spacing: 8)
        {
            Text(viewModel.modelSectionsSummary).font(.callout)
            HStack
            {
                Button("Select All", action: viewModel.selectAllSections)
                Button("Select None", action: viewModel.selectNoSections)
            }
            LazyVStack(spacing: 10)
            {
                ForEach(viewModel.modelSectionItems)
                {
                    item in
                    HStack(spacing: 12)
                    {
                        Toggle(item.title, isOn: Binding(get: { item.isIncluded }, set: { viewModel.setSectionIncluded(item.id, included: $0) }))
                        Spacer()
                        Button(item.isPreviewed ? "Viewing" : "Preview") { viewModel.previewSection(item.id) }
                            .disabled(item.isPreviewed)
                    }
                }
            }
        }
        .disabled(viewModel.isLoading)
        .padding(16)
    }
}
