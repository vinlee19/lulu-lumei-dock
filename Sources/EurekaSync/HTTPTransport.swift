import Foundation

/// 同步 HTTP 响应（body + 响应头，头键统一小写）
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

/// 同步 HTTP 传输协议：同步引擎全程跑在后台串行队列上，阻塞式最简单；
/// 测试注入 mock 也无需 async harness 支持。
public protocol HTTPTransport {
    func send(_ request: URLRequest, body: Data?) throws -> HTTPReply
}

/// 生产实现：URLSession + 信号量桥接。超时由调用方按请求设置 timeoutInterval。
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
