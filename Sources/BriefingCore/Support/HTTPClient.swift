import Foundation

public protocol HTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
}

public enum HTTPError: Error, CustomStringConvertible {
    case status(Int, URL)

    public var description: String {
        switch self {
        case .status(let code, let url): "HTTP \(code) from \(url.host() ?? url.absoluteString)"
        }
    }
}

public struct URLSessionHTTPClient: HTTPClient {
    private let session: URLSession

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "Briefing/0.1 (macOS)"]
        session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.status(http.statusCode, url)
        }
        return data
    }
}
