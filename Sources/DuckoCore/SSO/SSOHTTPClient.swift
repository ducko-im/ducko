import Foundation

/// Sends the OAuth requests of a browser sign-in. Only https goes out, and no redirect is followed.
protocol SSOHTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionSSOHTTPClient: SSOHTTPClient {
    private let session: URLSession

    init(configuration: URLSessionConfiguration = .ephemeral) {
        configuration.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: configuration)
    }

    /// A transport failure or timeout means the provider could not be reached. A redirect fails as a response Ducko
    /// cannot use, since following one would re-send a POST body, tokens included, to wherever it points.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.scheme?.lowercased() == "https" else { throw SSOError.malformedResponse }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: RedirectRefusal())
        } catch is URLError {
            throw SSOError.providerUnreachable
        }
        guard let http = response as? HTTPURLResponse, !(300 ..< 400).contains(http.statusCode) else {
            throw SSOError.malformedResponse
        }
        return (data, http)
    }
}

/// Hands back no request for any redirect, so the redirect response itself completes the task.
final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession, task _: URLSessionTask, willPerformHTTPRedirection _: HTTPURLResponse, newRequest _: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

extension SSOHTTPClient {
    /// Sends `request` and decodes a JSON object body for any status except a server error or a rate limit, which
    /// throws `providerUnreachable`.
    func sendForJSON(_ request: URLRequest) async throws -> (json: [String: Any], status: Int) {
        let (data, response) = try await send(request)
        return try (jsonBody(data, of: response), response.statusCode)
    }
}

/// The JSON object body of a response the provider could answer.
func jsonBody(_ data: Data, of response: HTTPURLResponse) throws -> [String: Any] {
    if response.isTemporaryRefusal { throw SSOError.providerUnreachable }
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SSOError.malformedResponse
    }
    return json
}

extension HTTPURLResponse {
    /// A server error or a rate limit, which can clear by itself.
    var isTemporaryRefusal: Bool {
        statusCode == 429 || (500 ..< 600).contains(statusCode)
    }
}

extension URLRequest {
    /// A POST of `fields` as `application/x-www-form-urlencoded`.
    static func formPost(to url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(fields.map { "\(formEncoded($0))=\(formEncoded($1))" }.joined(separator: "&").utf8)
        return request
    }

    private static func formEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: Unicode.Scalar(0) ... Unicode.Scalar(127)))
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
