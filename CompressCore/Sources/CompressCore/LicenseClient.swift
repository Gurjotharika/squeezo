import Foundation

/// Talks to Dodo Payments' public license endpoints. They need no API key, so nothing secret ships in the app.
public struct LicenseClient: Sendable {
    public enum Environment: String, Sendable {
        case live, test

        var baseURL: URL { URL(string: "https://\(rawValue).dodopayments.com")! }
    }

    public enum LicenseError: LocalizedError, Equatable, Sendable {
        case invalidKey
        case inactive
        case activationLimit
        case offline
        case server(Int)

        public var errorDescription: String? {
            switch self {
            case .invalidKey: "That license key wasn't found. Check it and try again."
            case .inactive: "This license key isn't active. It may have been refunded or expired."
            case .activationLimit: "This key is already in use on the most Macs it allows. Deactivate it on another Mac first."
            case .offline: "Couldn't reach the license server. Check your connection and try again."
            case .server(let code): "The license server returned an error (\(code)). Try again later."
            }
        }
    }

    /// Sends a request and returns the status code and body. Replaceable so tests need no network.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, Int)

    public let environment: Environment
    private let transport: Transport

    public init(environment: Environment = .live, transport: @escaping Transport = LicenseClient.urlSession) {
        self.environment = environment
        self.transport = transport
    }

    public static let urlSession: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Registers this Mac against the key and returns the instance ID to keep for later checks.
    public func activate(key: String, deviceName: String) async throws -> String {
        let (data, status) = try await post("licenses/activate", ["license_key": key, "name": deviceName])
        switch status {
        case 200..<300:
            guard let id = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["id"] as? String else { throw LicenseError.server(status) }
            return id
        case 403: throw LicenseError.inactive
        case 404: throw LicenseError.invalidKey
        case 422: throw LicenseError.activationLimit
        default: throw LicenseError.server(status)
        }
    }

    /// Whether the key is still good and this Mac's activation still exists.
    public func validate(key: String, instanceID: String) async throws -> Bool {
        let (data, status) = try await post("licenses/validate", ["license_key": key, "license_key_instance_id": instanceID])
        switch status {
        case 200..<300:
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["valid"] as? Bool ?? false
        case 404, 422: return false
        default: throw LicenseError.server(status)
        }
    }

    /// Frees this Mac's activation so the key can be used elsewhere.
    public func deactivate(key: String, instanceID: String) async throws {
        let (_, status) = try await post("licenses/deactivate", ["license_key": key, "license_key_instance_id": instanceID])
        switch status {
        case 200..<300, 404: return
        case 403: throw LicenseError.inactive
        default: throw LicenseError.server(status)
        }
    }

    private func post(_ path: String, _ body: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: environment.baseURL.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await transport(request)
        } catch is URLError {
            throw LicenseError.offline
        }
    }
}
