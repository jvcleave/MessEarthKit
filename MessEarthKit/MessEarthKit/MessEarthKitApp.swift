//
//  MessEarthKitApp.swift
//  MessEarthKit
//
//  Created by jason van cleave on 10/27/26.
//

import SwiftUI

@main
struct MessEarthKitApp: App
{
    @State private var workspace = EarthWorkspaceViewModel()

    var body: some Scene
    {
        Window("MessEarthKit", id: "workspace")
        {
            EarthWorkspaceView(viewModel: workspace)
        }
        .defaultSize(width: 1100, height: 760)
    }
}
