import Foundation
@testable import MessEarthKit
import Testing

@Test func googleRejectionReasonsRemainSpecificAndCredentialFree() async throws
{
    let payload = Data("""
    {"error":{"code":403,"message":"Requests from this IP address SECRET are blocked: https://tile.googleapis.com/?key=PRIVATE","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_IP_ADDRESS_BLOCKED","metadata":{"consumer":"projects/PRIVATE"}}]}}
    """.utf8)
    let error = EarthGoogleErrorResponse.failure(statusCode: 403, data: payload)
    guard case .serviceRejected(.ipRestricted, 403) = error else { Issue.record("Lost the service rejection reason."); return }
    #expect(error.localizedDescription.contains("IPv6"))
    for secret in ["SECRET", "PRIVATE", "https://", "projects/"] { #expect(!error.localizedDescription.contains(secret)) }
    let quota = Data("""
    {"error":{"errors":[{"reason":"quotaExceeded"}],"message":"PRIVATE"}}
    """.utf8)
    guard case .serviceRejected(.quotaExceeded, 403) = EarthGoogleErrorResponse.failure(statusCode: 403, data: quota) else { Issue.record("Misidentified quota rejection as an invalid key."); return }
    let oversized = Data(repeating: 32, count: EarthGoogleErrorResponse.maximumBytes + 1)
    guard case .serviceRejected(.permissionDenied, 403) = EarthGoogleErrorResponse.failure(statusCode: 403, data: oversized) else { Issue.record("Oversized response did not fall back safely."); return }
    let recorded = GoogleRejectionEvents()
    let transport = EarthRequestTransport(observer: { await recorded.receive($0) }, loader: { _, _ in throw error })
    await #expect(throws: EarthCaptureError.self) { try await transport.load(url: #require(URL(string: "https://tile.googleapis.com/v1/3dtiles/root.json")), maximumBytes: 1024) }
    #expect(await recorded.failedStatus == 403)
}

private actor GoogleRejectionEvents
{
    var failedStatus: Int?
    func receive(_ event: EarthRequestEvent)
    { if case let .finished(_, .failed, _, status, _) = event { failedStatus = status } }
}
