//
//  MessEarthKitApp.swift
//  MessEarthKit
//
//  Created by jason van cleave on 10/27/26.
//

import MessEarthKit
import SwiftUI

@main
struct MessEarthKitApp: App
{
    @State private var library: EarthProjectLibraryViewModel?
    @State private var storageError: String?

    var body: some Scene
    {
        Window("MessEarthKit", id: "workspace")
        {
            if let library { EarthProjectLibraryView(viewModel: library) }
            else if let storageError
            {
                ContentUnavailableView
                {
                    Label("Storage unavailable", systemImage: "folder.badge.questionmark")
                } description: {
                    EarthErrorMessage(storageError)
                } actions: {
                    Button("Retry") { self.storageError = nil }
                }
            }
            else
            {
                ProgressView("Opening project storage…")
                    .task { await openLibrary() }
            }
        }
        .defaultSize(width: 1440, height: 900)
    }

    @MainActor
    private func openLibrary() async
    {
        do
        {
            let appFiles = try await EarthAppFiles.openDefault()
            let usageStore = try await EarthRequestUsageStore(fileURL: appFiles.requestUsageURL())
            library = EarthProjectLibraryViewModel(files: appFiles, usageStore: usageStore)
        }
        catch { storageError = error.localizedDescription }
    }
}
