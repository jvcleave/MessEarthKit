import Foundation

/// Ephemeral network transport; never persists requests or reports credential URLs.
final class EarthGoogleTileClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable
{
    private let session: URLSession

    override init()
    {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        session = URLSession(configuration: configuration)
        super.init()
    }

    deinit { session.invalidateAndCancel() }

    /// URLSession streams to its temporary file using a bounded working set.
    /// The completed response moves to the caller's staging file; it is never Data.
    func download(url: URL, to fileURL: URL) async throws -> Int
    {
        let temporary: URL
        let response: URLResponse
        do
        {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            (temporary, response) = try await session.download(for: request, delegate: self)
        }
        catch
        {
            if Task.isCancelled { throw CancellationError() }
            if (error as NSError).domain == NSCocoaErrorDomain { throw EarthAcquisitionError.storage }
            if let error = error as? URLError,
               [.cannotCreateFile, .cannotOpenFile, .cannotCloseFile, .cannotWriteToFile, .cannotRemoveFile, .cannotMoveFile].contains(error.code)
            { throw EarthAcquisitionError.storage }
            throw EarthCaptureError.requestFailed(nil)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else { throw EarthCaptureError.requestFailed(nil) }
        if response.statusCode != 200
        {
            let handle = try? FileHandle(forReadingFrom: temporary)
            defer { try? handle?.close() }
            let data = (try? handle?.read(upToCount: EarthGoogleErrorResponse.maximumBytes)) ?? Data()
            throw EarthGoogleErrorResponse.failure(statusCode: response.statusCode, data: data)
        }
        do
        {
            let count = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard count > 0 else { throw EarthImportError.invalidContent("Empty source payload.") }
            try FileManager.default.moveItem(at: temporary, to: fileURL)
            return count
        }
        catch let error as EarthImportError { throw error }
        catch { throw EarthAcquisitionError.storage }
    }

    func load(url: URL, maximumBytes: Int) async throws -> Data
    {
        do
        {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw EarthCaptureError.requestFailed(nil) }
            if response.statusCode != 200
            {
                var body = Data()
                do
                {
                    for try await byte in bytes
                    {
                        if body.count >= EarthGoogleErrorResponse.maximumBytes { break }
                        body.append(byte)
                    }
                }
                catch { if Task.isCancelled { throw CancellationError() } }
                throw EarthGoogleErrorResponse.failure(statusCode: response.statusCode, data: body)
            }
            guard response.expectedContentLength <= maximumBytes
            else { throw EarthImportError.limitExceeded("Tile response bytes.") }
            var data = Data()
            data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
            for try await byte in bytes
            {
                guard data.count < maximumBytes else { throw EarthImportError.limitExceeded("Tile response bytes.") }
                data.append(byte)
                if data.count.isMultiple(of: 65536) { try Task.checkCancellation() }
            }
            try Task.checkCancellation()
            return data
        }
        catch is CancellationError { throw CancellationError() }
        catch let error as EarthCaptureError { throw error }
        catch let error as EarthImportError { throw error }
        catch
        {
            if Task.isCancelled { throw CancellationError() }
            throw EarthCaptureError.requestFailed(nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    )
    {
        completionHandler(nil)
    }
}
