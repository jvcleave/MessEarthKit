import Foundation
import MessEarthKit

enum EarthProjectDetail: String, Codable, CaseIterable, Identifiable, Sendable
{
    case preview, standard, high
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var errorMeters: Double
    {
        switch self
        {
            case .preview: 16
            case .standard: 4
            case .high: 1
        }
    }
}

/// A map search result is a starting point, never a saved capture area.
struct EarthMapSearchResult: Codable, Equatable, Sendable
{
    let address: String
    let title: String
    let origin: EarthGeographicOrigin
}

struct EarthProjectCapture: Codable, Equatable, Sendable
{
    let id: UUID
    let request: EarthDownloadRequest
    var reference: String { "sources/\(id.uuidString)" }
    var area: EarthLocationArea
    {
        .init(center: request.center, widthMeters: String(request.widthMeters), heightMeters: String(request.depthMeters))
    }
}

struct EarthProjectPreparation: Codable, Equatable, Sendable
{
    let id: UUID
    let captureID: UUID
    let profile: EarthPreparationProfile
    var reference: String { "prepared/\(id.uuidString)" }
}

struct EarthProjectRecord: Codable, Equatable, Identifiable, Sendable
{
    let version: Int
    let id: UUID
    let createdAt: Date
    var modifiedAt: Date
    var title: String
    var searchAddress: String
    var searchResult: EarthMapSearchResult?
    var locations: [EarthLocationRecord]
    var editingLocationID: UUID?
    var captures: [EarthProjectCaptureVariant] { locations.flatMap(\.variants) }
    var editingLocation: EarthLocationRecord? { locations.first { $0.id == editingLocationID } }
    var captureLocation: EarthLocationRecord? { locations.first { location in location.variants.contains { $0.id == selectedCaptureID } } }
    var selectedCaptureID: UUID?
    var selectedCapture: EarthProjectCaptureVariant? { captures.first { $0.id == selectedCaptureID } }
    var currentCapture: EarthProjectCapture? { selectedCapture?.capture }
    var currentPreparation: EarthProjectPreparation? { selectedCapture?.preparation }

    init(id: UUID, date: Date)
    {
        version = 5
        self.id = id
        createdAt = date
        modifiedAt = date
        title = ""
        searchAddress = ""
        locations = []
    }

    var displayTitle: String
    {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Project" : name
    }

    func validate(id expectedID: UUID) throws
    {
        guard version == 5 else { throw EarthProjectStoreError.unsupportedVersion }
        guard id == expectedID, createdAt.timeIntervalSince1970.isFinite,
              modifiedAt.timeIntervalSince1970.isFinite, modifiedAt >= createdAt,
              title.utf8.count <= 512, searchAddress.utf8.count <= 4096,
              Set(locations.map(\.id)).count == locations.count,
              locations.isEmpty ? editingLocationID == nil : editingLocation != nil,
              Set(captures.map(\.id)).count == captures.count,
              Set(captures.flatMap(\.sourceCaptures).map(\.id)).count == captures.flatMap(\.sourceCaptures).count,
              captures.isEmpty ? selectedCaptureID == nil : selectedCapture != nil
        else { throw EarthProjectStoreError.invalidRecord }
        if let searchResult
        {
            guard searchResult.address == searchAddress, !searchResult.title.isEmpty,
                  searchResult.title.utf8.count <= 4096 else { throw EarthProjectStoreError.invalidRecord }
        }
        for location in locations
        {
            try location.validate()
            guard location.createdAt >= createdAt, location.createdAt <= modifiedAt,
                  location.frozenAt.map({ $0 <= modifiedAt }) ?? true
            else { throw EarthProjectStoreError.invalidRecord }
            for variant in location.variants where variant.createdAt > modifiedAt
            { throw EarthProjectStoreError.invalidRecord }
        }
    }

    private enum CodingKeys: String, CodingKey
    {
        case version, id, createdAt, modifiedAt, title, searchAddress, searchResult, locations, editingLocationID, selectedCaptureID
    }

    init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == 5 else { throw EarthProjectStoreError.unsupportedVersion }
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        title = try values.decode(String.self, forKey: .title)
        searchAddress = try values.decode(String.self, forKey: .searchAddress)
        searchResult = try values.decode(EarthMapSearchResult?.self, forKey: .searchResult)
        locations = try values.decode([EarthLocationRecord].self, forKey: .locations)
        editingLocationID = try values.decode(UUID?.self, forKey: .editingLocationID)
        selectedCaptureID = try values.decode(UUID?.self, forKey: .selectedCaptureID)
        try validate(id: id)
    }

    func encode(to encoder: any Encoder) throws
    {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(id, forKey: .id)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(modifiedAt, forKey: .modifiedAt)
        try values.encode(title, forKey: .title)
        try values.encode(searchAddress, forKey: .searchAddress)
        try values.encode(searchResult, forKey: .searchResult)
        try values.encode(locations, forKey: .locations)
        try values.encode(editingLocationID, forKey: .editingLocationID)
        try values.encode(selectedCaptureID, forKey: .selectedCaptureID)
    }
}

enum EarthProjectStoreError: Error, Equatable, LocalizedError, Sendable
{
    case unsupportedVersion, invalidRecord, sourceMismatch, captureNotFound, locationNotFound, frozenLocation, changedLocation, capturedLocation, lockedVariantDetail

    var errorDescription: String?
    {
        switch self
        {
            case .unsupportedVersion: "This project uses an unsupported format version."
            case .invalidRecord: "The project file is invalid or does not match its folder."
            case .sourceMismatch: "The project's saved capture or prepared models do not match their recorded source."
            case .locationNotFound: "This location is no longer available. Refresh the project and try again."
            case .frozenLocation: "This location's capture area is frozen. Use Adjust Area before any capture completes, or Duplicate."
            case .changedLocation: "The location or its variants changed. Review the location and try again."
            case .captureNotFound: "This capture variant is no longer available in the project. Refresh the project and try again."
            case .capturedLocation: "The capture area is fixed after a variant finishes downloading. Use Duplicate for a different area."
            case .lockedVariantDetail: "Detail is fixed once a variant starts downloading. Add another variant to choose a different detail."
        }
    }
}
