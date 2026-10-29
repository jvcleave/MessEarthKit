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

/// Text fields retain incomplete edits. Numeric validity is checked when a
/// download is requested, rather than silently replacing a saved draft value.
struct EarthProjectDraft: Codable, Equatable, Sendable
{
    var address: String
    var detail: EarthProjectDetail
    var widthMeters: String
    var heightMeters: String

    static let empty = EarthProjectDraft(address: "", detail: .standard, widthMeters: "200", heightMeters: "200")

    func validate() throws
    {
        guard address.utf8.count <= 4096, widthMeters.utf8.count <= 64, heightMeters.utf8.count <= 64
        else { throw EarthProjectStoreError.invalidRecord }
    }
}

struct EarthProjectLocation: Codable, Equatable, Sendable
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
    var draft: EarthProjectDraft
    var resolvedLocation: EarthProjectLocation?
    var captures: [EarthProjectCaptureVariant]
    var selectedCaptureID: UUID?
    var selectedCapture: EarthProjectCaptureVariant? { captures.first { $0.id == selectedCaptureID } }
    var currentCapture: EarthProjectCapture? { selectedCapture?.capture }
    var currentPreparation: EarthProjectPreparation? { selectedCapture?.preparation }

    init(id: UUID, date: Date)
    {
        version = 2
        self.id = id
        createdAt = date
        modifiedAt = date
        title = ""
        draft = .empty
        captures = []
    }

    var displayTitle: String
    {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Untitled Project" : name
    }

    func validate(id expectedID: UUID) throws
    {
        guard version == 2 else { throw EarthProjectStoreError.unsupportedVersion }
        guard id == expectedID, createdAt.timeIntervalSince1970.isFinite,
              modifiedAt.timeIntervalSince1970.isFinite, modifiedAt >= createdAt,
              title.utf8.count <= 512, Set(captures.map(\.id)).count == captures.count,
              captures.isEmpty ? selectedCaptureID == nil : selectedCapture != nil
        else { throw EarthProjectStoreError.invalidRecord }
        try draft.validate()
        if let resolvedLocation
        {
            guard resolvedLocation.address == draft.address, !resolvedLocation.title.isEmpty,
                  resolvedLocation.title.utf8.count <= 4096 else { throw EarthProjectStoreError.invalidRecord }
        }
        for capture in captures
        {
            try capture.validate()
            guard capture.createdAt >= createdAt, capture.createdAt <= modifiedAt else { throw EarthProjectStoreError.invalidRecord }
        }
    }

    private enum CodingKeys: String, CodingKey
    {
        case version, id, createdAt, modifiedAt, title, draft, resolvedLocation, captures, selectedCaptureID
    }

    init(from decoder: any Decoder) throws
    {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        guard version == 2 else { throw EarthProjectStoreError.unsupportedVersion }
        id = try values.decode(UUID.self, forKey: .id)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        modifiedAt = try values.decode(Date.self, forKey: .modifiedAt)
        title = try values.decode(String.self, forKey: .title)
        draft = try values.decode(EarthProjectDraft.self, forKey: .draft)
        // Required nullable keys: absent fields are not a legacy default.
        resolvedLocation = try values.decode(EarthProjectLocation?.self, forKey: .resolvedLocation)
        captures = try values.decode([EarthProjectCaptureVariant].self, forKey: .captures)
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
        try values.encode(draft, forKey: .draft)
        try values.encode(resolvedLocation, forKey: .resolvedLocation)
        try values.encode(captures, forKey: .captures)
        try values.encode(selectedCaptureID, forKey: .selectedCaptureID)
    }
}

enum EarthProjectStoreError: Error, Equatable, LocalizedError, Sendable
{
    case unsupportedVersion, invalidRecord, sourceMismatch, captureNotFound

    var errorDescription: String?
    {
        switch self
        {
            case .unsupportedVersion: "This project uses an unsupported format version."
            case .invalidRecord: "The project file is invalid or does not match its folder."
            case .sourceMismatch: "The project's saved capture or prepared models do not match their recorded source."
            case .captureNotFound: "This capture variant is no longer available in the project. Refresh the project and try again."
        }
    }
}
