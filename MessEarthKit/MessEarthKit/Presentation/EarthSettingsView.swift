import Foundation
import MessEarthKit
import Observation
import SwiftUI

@MainActor
@Observable
final class EarthSettingsViewModel
{
    let usage: EarthRequestUsageViewModel
    private(set) var apiKey = ""
    private(set) var settings: EarthAppSettings?
    private(set) var settingsError: String?
    private(set) var credentialError: String?
    private(set) var credentialStatus = ""
    private(set) var isSavingKey = false
    @ObservationIgnored private let store: EarthAppSettingsStore
    @ObservationIgnored private let keyStore = EarthAPIKeyStore()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var credentialTask: Task<Void, Never>?
    @ObservationIgnored private var settingsTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSettings: EarthAppSettings?
    @ObservationIgnored private var keyRevision = 0

    init(files: EarthAppFiles, usageStore: EarthRequestUsageStore)
    {
        store = EarthAppSettingsStore(files: files)
        usage = EarthRequestUsageViewModel(store: usageStore)
        reloadSettings()
        credentialTask = Task
        { [weak self, keyStore] in
            do
            {
                let key = try await keyStore.load()
                guard let self, keyRevision == 0 else { return }
                apiKey = key ?? ""
                credentialStatus = key == nil ? "" : "Saved in Keychain"
            }
            catch
            {
                guard let self, keyRevision == 0 else { return }
                credentialError = error.localizedDescription
            }
        }
    }

    func setAPIKey(_ value: String)
    {
        apiKey = value
        keyRevision += 1
        credentialError = nil
        credentialStatus = ""
    }

    func saveAPIKey()
    {
        guard !isSavingKey else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = keyRevision
        isSavingKey = true
        credentialTask = Task
        { [weak self, keyStore] in
            defer { self?.isSavingKey = false }
            do
            {
                try await keyStore.save(key)
                guard let self, keyRevision == revision else { return }
                apiKey = key
                credentialStatus = "Saved in Keychain"
                credentialError = nil
            }
            catch { self?.credentialError = error.localizedDescription }
        }
    }

    func reloadSettings()
    {
        guard loadTask == nil, settingsTask == nil else { return }
        settingsError = nil
        loadTask = Task
        { [weak self, store] in
            defer { self?.loadTask = nil }
            do { self?.settings = try await store.load() }
            catch { self?.settingsError = error.localizedDescription }
        }
    }

    func setShowsUsageDetails(_ value: Bool)
    {
        guard var settings else { return }
        settings.showsUsageDetails = value
        self.settings = settings
        pendingSettings = settings
        savePendingSettings()
    }

    func savePendingSettings()
    {
        guard settingsTask == nil, pendingSettings != nil else { return }
        settingsTask = Task
        { [weak self, store] in
            guard let self else { return }
            defer { settingsTask = nil }
            while let value = pendingSettings
            {
                pendingSettings = nil
                do
                {
                    try await store.save(value)
                    settingsError = nil
                }
                catch
                {
                    if pendingSettings == nil { pendingSettings = value }
                    settingsError = error.localizedDescription
                    return
                }
            }
        }
    }
}

struct EarthSettingsView: View
{
    let viewModel: EarthSettingsViewModel

    var body: some View
    {
        Form
        {
            Section("Google Maps Tile API")
            {
                SecureField("API key", text: Binding(get: { viewModel.apiKey }, set: viewModel.setAPIKey))
                Button("Save Key in Keychain", action: viewModel.saveAPIKey)
                    .disabled(viewModel.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isSavingKey)
                if !viewModel.credentialStatus.isEmpty { Text(viewModel.credentialStatus).foregroundStyle(.secondary) }
                if let error = viewModel.credentialError { Text(error).foregroundStyle(.red) }
            }
            Section("Request history")
            {
                EarthRequestUsageView(viewModel: viewModel.usage, showsDetails: Binding(get: { viewModel.settings?.showsUsageDetails == true }, set: viewModel.setShowsUsageDetails))
            }
            if let error = viewModel.settingsError
            {
                Section("Settings could not be saved or loaded")
                {
                    Text(error).foregroundStyle(.red)
                    if viewModel.settings == nil { Button("Retry", action: viewModel.reloadSettings) }
                    else { Button("Retry Save", action: viewModel.savePendingSettings) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
