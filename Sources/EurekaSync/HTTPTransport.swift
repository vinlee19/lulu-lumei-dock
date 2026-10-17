import Foundation

/// Synchronous HTTP response (body + response headers, header keys lowercased)
public struct HTTPReply {
    public var status: Int
    public var body: Data
    public var headers: [String: String]

    public init(status: Int, body: Data, headers: [String: String] = [:]) {
        self.status = status
        self.body = body
        self.headers = headers
    }
}

/// Synchronous HTTP transport protocol: the sync engine runs entirely on a background serial
/// queue, so blocking is simplest;
/// injecting a mock in tests needs no async harness support either.
public protocol HTTPTransport {
    func send(_ request: URLRequest, body: Data?) throws -> HTTPReply
}

/// Production implementation: URLSession + a semaphore bridge. Callers set timeoutInterval per
/// request.
public struct URLSessionTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest, body: Data?) throws -> HTTPReply {
        var request = request
        if let body {
            request.httpBody = body
        }
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<HTTPReply, Error> = .failure(URLError(.unknown))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else {
                let http = response as? HTTPURLResponse
                var headers: [String: String] = [:]
                for (key, value) in http?.allHeaderFields ?? [:] {
                    if let key = key as? String, let value = value as? String {
                        headers[key.lowercased()] = value
                    }
                }
                result = .success(HTTPReply(
                    status: http?.statusCode ?? 0, body: data ?? Data(), headers: headers))
            }
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()
        return try result.get()
    }
}
