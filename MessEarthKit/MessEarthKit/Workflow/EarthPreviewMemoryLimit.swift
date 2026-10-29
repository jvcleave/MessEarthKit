import Foundation

/// A per-job admission choice. Custom limits do not reserve memory in advance.
enum EarthPreviewMemoryLimit: Equatable, Sendable
{
    case automatic
    case customBytes(Int)

    init(gibibytes: String) throws
    {
        guard gibibytes.utf8.count <= 64,
              let value = Double(gibibytes.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite, value > 0
        else { throw EarthRegionPreviewError.invalidMemoryBudget }
        let bytes = value * 1073741824
        // Double(Int.max) rounds upward on 64-bit platforms; use strict '<'
        // before converting, and reject positive amounts that truncate to zero.
        guard bytes.isFinite, bytes >= 1, bytes < Double(Int.max)
        else { throw EarthRegionPreviewError.invalidMemoryBudget }
        self = .customBytes(Int(bytes))
    }

    func resolvedBytes(recommendedWorkingSetSize: UInt64) throws -> Int
    {
        switch self
        {
            // Leave half of Metal's recommended working set outside the budget.
            // Existing allocations, the viewport and upload headroom count inside it.
            case .automatic: return Int(clamping: recommendedWorkingSetSize / 2)
            case let .customBytes(bytes):
                guard bytes > 0 else { throw EarthRegionPreviewError.invalidMemoryBudget }
                return bytes
        }
    }
}
