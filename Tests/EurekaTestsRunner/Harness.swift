import Foundation

// Minimal test harness: the CLT toolchain has no XCTest, so assertions and the summary are
// hand-rolled. The layout (one `xxxTests(_:)` function per module + expect assertions) keeps a
// future XCTest migration easy.

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

func expectEqual<T: Equatable>(
    _ actual: T,
    _ expected: T,
    _ message: @autoclosure () -> String,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    if actual != expected {
        throw ExpectationError(
            description: "\(message()): got \(actual), expected \(expected) at \(file):\(line)")
    }
}

/// Fixture file URL (Fixtures ship in Bundle.module as .copy resources)
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
