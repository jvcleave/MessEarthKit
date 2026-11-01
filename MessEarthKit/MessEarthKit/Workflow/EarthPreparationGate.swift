import Foundation

/// One native preparation at a time, including callers outside the download queue.
actor EarthPreparationGate
{
    private var occupied = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    func run<Value: Sendable>(_ operation: @Sendable () async throws -> Value) async throws -> Value
    {
        let id = UUID()
        try await withTaskCancellationHandler
        {
            try Task.checkCancellation()
            if !occupied { occupied = true }
            else { try await withCheckedThrowingContinuation { waiters.append((id, $0)) } }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func cancelWaiter(_ id: UUID)
    {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func release()
    {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}
