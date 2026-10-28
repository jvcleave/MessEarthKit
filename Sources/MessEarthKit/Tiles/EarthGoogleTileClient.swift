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
        configuration.timeoutIntervalForResource = 90
        session = URLSession(configuration: configuration)
        super.init()
    }

    deinit { session.invalidateAndCancel() }

    func load(url: URL, maximumBytes: Int) async throws -> Data
    {
        do
        {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (bytes, response) = try await session.bytes(for: request, delegate: self)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw EarthCaptureError.requestFailed(nil) }
            switch response.statusCode
            {
                case 200: break
                case 401, 403: throw EarthCaptureError.authenticationRejected
                default: throw EarthCaptureError.requestFailed(response.statusCode)
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
