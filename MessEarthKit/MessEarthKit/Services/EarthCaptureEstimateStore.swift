import Foundation
import MessEarthKit

struct EarthCaptureObservationHistory: Sendable
{
    let observations: [EarthCaptureObservation]
    let note: String?
}

/// Owns a bounded private calibration cache, separate from raw recovery files.
actor EarthCaptureEstimateStore
{
    private struct SavedHistory: Codable
    {
        let version: Int
        let observations: [EarthCaptureObservation]
    }

    private let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("MessEarthKit/OfflineEstimates.json")
    private var cached: EarthCaptureObservationHistory?
    private var canWrite = true

    func load() -> EarthCaptureObservationHistory
    {
        if let cached { return cached }
        guard let fileURL else { return remember([], note: "Local estimate history storage is unavailable.") }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return remember([]) }
        do
        {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1024 * 1024
            else { throw EarthImportError.invalidContent("Offline estimate history is oversized or invalid.") }
            let saved = try JSONDecoder().decode(SavedHistory.self, from: Data(contentsOf: fileURL))
            guard saved.version == 1, saved.observations.count <= 64, saved.observations.allSatisfy(\.isUsable)
            else { throw EarthImportError.invalidContent("Offline estimate history has invalid measurements.") }
            return remember(saved.observations)
        }
        catch
        {
            canWrite = false
            return remember([], note: "Saved estimate history could not be read. Only current-session measurements will be used.")
        }
    }

    func record(_ observation: EarthCaptureObservation) -> EarthCaptureObservationHistory
    {
        let previous = load()
        guard observation.isUsable else { return previous }
        var observations = previous.observations.filter { !$0.matchesSelection(observation) }
        observations.append(observation)
        observations.sort { $0.recordedAt > $1.recordedAt }
        observations = Array(observations.prefix(64))
        var note = previous.note
        if canWrite, let fileURL
        {
            do
            {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(SavedHistory(version: 1, observations: observations))
                try data.write(to: fileURL, options: .atomic)
                note = nil
            }
            catch { note = "Estimate history could not be saved. Current-session measurements are still available." }
        }
        return remember(observations, note: note)
    }

    private func remember(_ observations: [EarthCaptureObservation], note: String? = nil) -> EarthCaptureObservationHistory
    {
        let value = EarthCaptureObservationHistory(observations: observations, note: note)
        cached = value
        return value
    }
}
