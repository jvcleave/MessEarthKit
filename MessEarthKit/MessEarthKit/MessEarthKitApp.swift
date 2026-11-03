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
    @State private var application = EarthApplicationViewModel()

    var body: some Scene
    {
        Window("MessEarthKit", id: "workspace")
        {
            ZStack
            {
                Group
                {
                    if let library = application.library
                    { EarthProjectLibraryView(viewModel: library).environment(library.exportViewer).id(ObjectIdentifier(library)) }
                    else if let error = application.openingError
                    {
                        ContentUnavailableView
                        {
                            Label("Storage unavailable", systemImage: "folder.badge.questionmark")
                        } description: {
                            EarthErrorMessage(error)
                        } actions: {
                            Button("Retry", action: application.retryOpening)
                        }
                    }
                    else
                    {
                        ProgressView("Opening project storage…")
                            .task { await application.openLibrary() }
                    }
                }
                .disabled(application.isMovingStorage)
                if application.isMovingStorage
                {
                    VStack(spacing: 12)
                    {
                        ProgressView(application.storageStatus)
                        Button("Cancel Move", action: application.cancelStorageMove)
                    }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .environment(application)
        }
        .defaultSize(width: 1440, height: 900)

        Window("Exported Model", id: "export-viewer")
        {
            if let library = application.library
            { EarthExportViewerView(viewModel: library.exportViewer).disabled(application.isMovingStorage) }
            else { ProgressView("Opening project storage…") }
        }
        .defaultSize(width: 1000, height: 760)
        .defaultLaunchBehavior(.suppressed)
    }
}
