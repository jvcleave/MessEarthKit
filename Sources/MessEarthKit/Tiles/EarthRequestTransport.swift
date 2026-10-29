import Foundation

/// Capture and inspection share this boundary, including injected fixture
/// transports. A local cache hit never enters it. Observers cannot fail a job.
struct EarthRequestTransport: Sendable
{
    typealias Loader = @Sendable (URL, Int) async throws -> Data
    let observer: EarthRequestObserver?
    let loader: Loader
    var now: @Sendable () -> Date = { Date() }

    func load(url: URL, maximumBytes: Int) async throws -> Data
    {
        try await perform(url: url)
        {
            let data = try await loader(url, maximumBytes)
            return (data, data.count)
        }
    }

    func download(url: URL, to fileURL: URL, using downloader: @Sendable (URL, URL) async throws -> Int) async throws -> Int
    {
        try await perform(url: url)
        {
            let count = try await downloader(url, fileURL)
            return (count, count)
        }
    }

    private func perform<Value: Sendable>(url: URL, operation: @Sendable () async throws -> (Value, Int)) async throws -> Value
    {
        try Task.checkCancellation()
        let id = UUID()
        let kind: EarthRequestKind = url.path == "/v1/3dtiles/root.json" ? .session : url.pathExtension.lowercased() == "json" ? .metadata : .tile
        await observer?(.started(id: id, kind: kind, at: now()))
        do
        {
            let (value, count) = try await operation()
            await observer?(.finished(id: id, outcome: .succeeded, at: now(), statusCode: 200, receivedBytes: count))
            return value
        }
        catch
        {
            let code: Int?
            if case let EarthCaptureError.requestFailed(status) = error { code = status }
            else if case let EarthCaptureError.serviceRejected(_, status) = error { code = status }
            else { code = nil }
            await observer?(.finished(id: id, outcome: error is CancellationError || Task.isCancelled ? .cancelled : .failed, at: now(), statusCode: code, receivedBytes: nil))
            throw error
        }
    }
}
