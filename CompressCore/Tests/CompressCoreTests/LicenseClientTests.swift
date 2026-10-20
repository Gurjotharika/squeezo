import Foundation
import Testing
@testable import CompressCore

@Suite struct LicenseClientTests {
    private func client(status: Int, body: String = "{}", capture: (@Sendable (URLRequest) -> Void)? = nil) -> LicenseClient {
        LicenseClient(environment: .test) { request in
            capture?(request)
            return (Data(body.utf8), status)
        }
    }

    @Test func activateReturnsTheInstanceID() async throws {
        let id = try await client(status: 200, body: #"{"id":"lki_abc"}"#).activate(key: "K", deviceName: "Mac")
        #expect(id == "lki_abc")
    }

    @Test func activateMapsStatusCodes() async {
        for (status, expected) in [(404, LicenseClient.LicenseError.invalidKey), (403, .inactive), (422, .activationLimit), (500, .server(500))] {
            await #expect(throws: expected) { try await client(status: status).activate(key: "K", deviceName: "Mac") }
        }
    }

    @Test func validateReadsTheValidFlag() async throws {
        #expect(try await client(status: 200, body: #"{"valid":true}"#).validate(key: "K", instanceID: "i"))
        #expect(try await !client(status: 200, body: #"{"valid":false}"#).validate(key: "K", instanceID: "i"))
        #expect(try await !client(status: 404).validate(key: "K", instanceID: "i"))
    }

    @Test func serverErrorsDuringValidationAreNotTreatedAsInvalid() async {
        await #expect(throws: LicenseClient.LicenseError.server(503)) { try await client(status: 503).validate(key: "K", instanceID: "i") }
    }

    @Test func offlineIsReported() async {
        let offline = LicenseClient { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: LicenseClient.LicenseError.offline) { try await offline.validate(key: "K", instanceID: "i") }
    }

    @Test func requestsGoToTheRightHostWithTheRightBody() async throws {
        final class Box: @unchecked Sendable { var request: URLRequest? }
        let box = Box()
        _ = try await client(status: 200, body: #"{"id":"x"}"#) { box.request = $0 }.activate(key: "KEY", deviceName: "My Mac")
        #expect(box.request?.url?.absoluteString == "https://test.dodopayments.com/licenses/activate")
        let body = try JSONSerialization.jsonObject(with: box.request?.httpBody ?? Data()) as? [String: String]
        #expect(body == ["license_key": "KEY", "name": "My Mac"])
    }
}
