import Foundation

// 极简测试 harness：CLT 工具链没有 XCTest，自建断言与汇总。
// 组织方式（每模块一个 `xxxTests(_:)` 函数 + expect 断言）兼容未来迁移 XCTest。

final class TestRunner {
    private(set) var failures: [String] = []
    private(set) var passed = 0
    private var currentSuite = ""
    private var currentTest = ""

    func suite(_ name: String) {
        currentSuite = name
        print("\n## \(name)")
    }

    func test(_ name: String, _ body: () throws -> Void) {
        currentTest = name
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch {
            let message = "\(currentSuite) / \(name): \(error)"
            failures.append(message)
            print("  ✗ \(name): \(error)")
        }
    }

    func finish() -> Never {
        print("\n\(passed) passed, \(failures.count) failed")
        if !failures.isEmpty {
            print("\n失败明细:")
            for failure in failures { print("  - \(failure)") }
        }
        exit(failures.isEmpty ? 0 : 1)
    }
}

struct ExpectationError: Error, CustomStringConvertible {
    let description: String
}

func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "expectation failed",
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if !condition() {
        throw ExpectationError(description: "\(message()) at \(file):\(line)")
    }
}

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if actual != expected {
        throw ExpectationError(description: "got \(actual), expected \(expected) at \(file):\(line)")
    }
}

/// 取 fixture 文件 URL（Fixtures 以 .copy 资源打进 Bundle.module）
func fixtureURL(_ relativePath: String) throws -> URL {
    guard let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else {
        throw ExpectationError(description: "Fixtures 资源目录不存在")
    }
    let url = base.appendingPathComponent(relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        throw ExpectationError(description: "fixture 不存在: \(relativePath)")
    }
    return url
}

func fixtureData(_ relativePath: String) throws -> Data {
    try Data(contentsOf: fixtureURL(relativePath))
}

func fixtureString(_ relativePath: String) throws -> String {
    guard let string = String(data: try fixtureData(relativePath), encoding: .utf8) else {
        throw ExpectationError(description: "fixture 非 UTF-8: \(relativePath)")
    }
    return string
}
