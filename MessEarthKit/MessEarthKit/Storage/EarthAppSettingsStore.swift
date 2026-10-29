import Foundation

enum EarthAppSettingsError: Error, LocalizedError, Sendable
{
    case invalidData, unsupportedVersion

    var errorDescription: String?
    {
        switch self
        {
            case .invalidData: "The app settings file is invalid."
            case .unsupportedVersion: "The app settings file uses an unsupported format version."
        }
    }
}

struct EarthAppSettings: Codable, Equatable, Sendable
{
    let version: Int
    var showsUsageDetails: Bool

    static let initial = EarthAppSettings(version: 1, showsUsageDetails: false)
}

actor EarthAppSettingsStore
{
    private let files: EarthAppFiles

    init(files: EarthAppFiles) { self.files = files }

    func load() async throws -> EarthAppSettings
    {
        guard let data = try await files.readMetadata(.settings)
        else
        {
            try await save(.initial)
            return .initial
        }
        let settings: EarthAppSettings
        do { settings = try JSONDecoder().decode(EarthAppSettings.self, from: data) }
        catch { throw EarthAppSettingsError.invalidData }
        guard settings.version == 1 else { throw EarthAppSettingsError.unsupportedVersion }
        return settings
    }

    func save(_ value: EarthAppSettings) async throws
    {
        guard value.version == 1 else { throw EarthAppSettingsError.unsupportedVersion }
        try await files.writeMetadata(JSONEncoder().encode(value), location: .settings)
    }
}
