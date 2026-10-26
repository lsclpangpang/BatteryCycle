import Foundation
import Darwin

#if BRIGHTNESS_LEASE_HELPER
@main private struct LeaseProcessHelper {
    static func main() throws {
        let args = CommandLine.arguments
        let lease = FileBrightnessControlLease(url: URL(fileURLWithPath: args[2]))
        if args[1] != "idle" {
            do { try lease.acquire() } catch { exit(73) }
        }
        if args[1] == "attempt" { return }
        try Data().write(to: URL(fileURLWithPath: args[3]))
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: args[4]), Date() < deadline {
            usleep(10_000)
        }
        lease.release()
    }
}
#else
#if canImport(XCTest) && !BRIGHTNESS_LEASE_STANDALONE
import XCTest
@testable import BatteryCycle
#elseif BRIGHTNESS_LEASE_STANDALONE
private var leaseFailures = 0
private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
    if lhs != rhs { leaseFailures += 1; print("FAIL: \(lhs) != \(rhs)") }
}
private func XCTFail(_ message: String) { leaseFailures += 1; print("FAIL: \(message)") }
class XCTestCase {}
@main private struct LeaseTestRunner {
    static func main() throws {
        let tests = BrightnessControlLeaseTests()
        try tests.testSeparateObjectsCannotOwnSameFile()
        try tests.testAcquireAndReleaseAreIdempotent()
        try tests.testFailedOwnerCannotReleaseSuccessfulOwner()
        try tests.testReleasePreservesFileIdentity()
        try tests.testDeinitializationReleasesOwnership()
        try tests.testIndependentProcessCannotAcquireHeldFile()
        try tests.testChildNormalExitAllowsTakeover()
        try tests.testKilledChildAllowsTakeover()
        try tests.testDescriptorDoesNotSurviveExec()
        try tests.testSymlinkCannotRedirectLock()
        try tests.testDirectoryCannotBeUsedAsLockFile()
        print("BrightnessControlLease: 11 checks, \(leaseFailures) failures")
        if leaseFailures > 0 { exit(1) }
    }
}
#endif

#if canImport(XCTest) || BRIGHTNESS_LEASE_STANDALONE
final class BrightnessControlLeaseTests: XCTestCase {
    func testSeparateObjectsCannotOwnSameFile() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("nested/brightness-control.lock")
            let first = FileBrightnessControlLease(url: url)
            let second = FileBrightnessControlLease(url: url)
            defer { first.release(); second.release() }
            try first.acquire()
            expectRejected { try second.acquire() }
            first.release()
            try second.acquire()
            expectRejected { try first.acquire() }
        }
    }

    func testAcquireAndReleaseAreIdempotent() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            let first = FileBrightnessControlLease(url: url)
            let second = FileBrightnessControlLease(url: url)
            defer { first.release(); second.release() }
            first.release()
            try first.acquire()
            try first.acquire()
            first.release()
            first.release()
            try second.acquire()
            expectRejected { try first.acquire() }
        }
    }

    func testFailedOwnerCannotReleaseSuccessfulOwner() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            let first = FileBrightnessControlLease(url: url)
            let failed = FileBrightnessControlLease(url: url)
            let third = FileBrightnessControlLease(url: url)
            defer { first.release(); third.release() }
            try first.acquire()
            expectRejected { try failed.acquire() }
            failed.release()
            expectRejected { try third.acquire() }
        }
    }

    func testReleasePreservesFileIdentity() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            let lease = FileBrightnessControlLease(url: url)
            try lease.acquire()
            let before = try FileManager.default.attributesOfItem(atPath: url.path)
            lease.release()
            let after = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(after[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
        }
    }

    func testDeinitializationReleasesOwnership() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            var first: FileBrightnessControlLease? = FileBrightnessControlLease(url: url)
            try first?.acquire()
            first = nil
            let second = FileBrightnessControlLease(url: url)
            try second.acquire()
            second.release()
        }
    }

    func testIndependentProcessCannotAcquireHeldFile() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            let lease = FileBrightnessControlLease(url: url)
            try lease.acquire()
            defer { lease.release() }
            let child = try startChild(mode: "attempt", lock: url, directory: directory)
            XCTAssertEqual(try waitForChild(child) >> 8, 73)
        }
    }

    func testChildNormalExitAllowsTakeover() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            let child = try startChild(mode: "hold", lock: url, directory: directory)
            defer { reapIfNeeded(child) }
            try waitForReady(directory)
            let parent = FileBrightnessControlLease(url: url)
            expectRejected { try parent.acquire() }
            try Data().write(to: directory.appendingPathComponent("release"))
            XCTAssertEqual(try waitForChild(child), 0)
            try parent.acquire()
            parent.release()
        }
    }

    func testKilledChildAllowsTakeover() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            let child = try startChild(mode: "hold", lock: url, directory: directory)
            defer { reapIfNeeded(child) }
            try waitForReady(directory)
            let parent = FileBrightnessControlLease(url: url)
            expectRejected { try parent.acquire() }
            XCTAssertEqual(kill(child, SIGKILL), 0)
            XCTAssertEqual(try waitForChild(child) & 0x7f, SIGKILL)
            try parent.acquire()
            parent.release()
        }
    }

    func testDescriptorDoesNotSurviveExec() throws {
        try withDirectory { directory in
            let url = directory.appendingPathComponent("control.lock")
            let first = FileBrightnessControlLease(url: url)
            try first.acquire()
            // posix_spawn has no close-fd actions: this catches a missing close-on-exec flag.
            let child = try startChild(mode: "idle", lock: url, directory: directory)
            defer { reapIfNeeded(child) }
            try waitForReady(directory)
            first.release()
            let second = FileBrightnessControlLease(url: url)
            try second.acquire()
            second.release()
            try Data().write(to: directory.appendingPathComponent("release"))
            XCTAssertEqual(try waitForChild(child), 0)
        }
    }

    func testSymlinkCannotRedirectLock() throws {
        try withDirectory { directory in
            let target = directory.appendingPathComponent("target")
            try Data("untouched".utf8).write(to: target)
            let link = directory.appendingPathComponent("control.lock")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let lease = FileBrightnessControlLease(url: link)
            expectRejected { try lease.acquire() }
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "untouched")
        }
    }

    func testDirectoryCannotBeUsedAsLockFile() throws {
        try withDirectory { directory in
            let lease = FileBrightnessControlLease(url: directory)
            expectRejected { try lease.acquire() }
        }
    }

    private func expectRejected(_ operation: () throws -> Void) {
        do { try operation(); XCTFail("A conflicting or invalid lease must be rejected") } catch { }
    }

    private func withDirectory(_ operation: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("brightness-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private func startChild(mode: String, lock: URL, directory: URL) throws -> pid_t {
        guard let executable = ProcessInfo.processInfo.environment["BATTERYCYCLE_BRIGHTNESS_LEASE_HELPER"] else {
            throw NSError(domain: "LeaseTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Run app/test-brightness-lease.sh to build the child-process helper"])
        }
        let arguments = [executable, mode, lock.path, directory.appendingPathComponent("ready").path,
                         directory.appendingPathComponent("release").path]
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for argument in argv { free(argument) } }
        var child: pid_t = 0
        var environment: [UnsafeMutablePointer<CChar>?] = [nil]
        let result = posix_spawn(&child, executable, nil, nil, &argv, &environment)
        guard result == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(result)) }
        return child
    }

    private func waitForReady(_ directory: URL) throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path) {
            guard Date() < deadline else { throw NSError(domain: "LeaseTests", code: 2) }
            usleep(10_000)
        }
    }

    private func waitForChild(_ child: pid_t) throws -> Int32 {
        let deadline = Date().addingTimeInterval(5)
        var status: Int32 = 0
        while true {
            let result = waitpid(child, &status, WNOHANG)
            if result == child { return status }
            if result == -1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            guard Date() < deadline else { throw NSError(domain: "LeaseTests", code: 3) }
            usleep(10_000)
        }
    }

    private func reapIfNeeded(_ child: pid_t) {
        var status: Int32 = 0
        if waitpid(child, &status, WNOHANG) == 0 {
            _ = kill(child, SIGKILL)
            _ = waitpid(child, &status, 0)
        }
    }
}
#endif
#endif
