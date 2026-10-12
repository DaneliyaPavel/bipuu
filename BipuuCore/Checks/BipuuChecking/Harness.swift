import Foundation

// Minimal check harness shared by the executables in this package (no XCTest / swift-testing,
// which need a full Xcode). Single-threaded use from the top-level async main only.
public nonisolated(unsafe) var failures = 0
public nonisolated(unsafe) var passed = 0

public func check(isolation: isolated (any Actor)? = #isolation, _ cond: @autoclosure () async throws -> Bool, _ msg: String = "",
                  file: StaticString = #fileID, line: UInt = #line) async throws {
    if try await cond() { passed += 1 } else { failures += 1; print("  FAIL \(file):\(line) \(msg)") }
}

public func checkThrows(isolation: isolated (any Actor)? = #isolation, file: StaticString = #fileID, line: UInt = #line,
                        _ body: () async throws -> Void) async throws {
    do { try await body(); failures += 1; print("  FAIL \(file):\(line) expected a throw") }
    catch { passed += 1 }
}

/// Expects `body` to throw exactly `expected`.
public func checkThrows<E: Error & Equatable>(isolation: isolated (any Actor)? = #isolation, _ expected: E, file: StaticString = #fileID, line: UInt = #line,
                                              _ body: () async throws -> Void) async throws {
    do { try await body(); failures += 1; print("  FAIL \(file):\(line) expected \(expected), nothing thrown") }
    catch let e as E where e == expected { passed += 1 }
    catch { failures += 1; print("  FAIL \(file):\(line) expected \(expected), got \(error)") }
}

public func run(isolation: isolated (any Actor)? = #isolation, _ name: String, _ body: () async throws -> Void) async {
    let before = failures
    do { try await body() } catch { failures += 1; print("  ERROR \(name): \(error)") }
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

public func finish() -> Never {
    print("\(passed) checks passed, \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}
