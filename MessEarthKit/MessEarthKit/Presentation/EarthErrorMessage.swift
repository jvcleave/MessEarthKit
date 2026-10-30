import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
final class EarthErrorMessageViewModel
{
    private(set) var copiedMessage: String?

    func copy(_ message: String)
    {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        copiedMessage = pasteboard.setString(message, forType: .string) ? message : nil
    }
}

/// Selection and an explicit copy action stay available for the full message.
struct EarthErrorMessage: View
{
    let message: String
    let color: Color
    @State private var viewModel = EarthErrorMessageViewModel()

    init(_ message: String, color: Color = .red)
    {
        self.message = message
        self.color = color
    }

    var body: some View
    {
        VStack(alignment: .leading, spacing: 6)
        {
            Text(message).foregroundStyle(color).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8)
            {
                Button("Copy Error", systemImage: "doc.on.doc") { viewModel.copy(message) }
                    .buttonStyle(.borderless).controlSize(.small)
                if viewModel.copiedMessage == message { Text("Copied").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
