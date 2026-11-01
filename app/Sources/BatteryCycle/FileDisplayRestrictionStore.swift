import Foundation
import Darwin

struct FileDisplayRestrictionStore: DisplayRestrictionStoring {
    let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BatteryCycle/display-output-recovery.json")) {
        self.url = url
    }

    func load() throws -> DisplayRestrictionState? {
        do { return try JSONDecoder().decode(DisplayRestrictionState.self, from: Data(contentsOf: url)) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch { throw StorageError("读取", error) }
    }

    func save(_ state: DisplayRestrictionState) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(state).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { throw StorageError("保存", error) }
    }

    private struct StorageError: LocalizedError {
        let operation: String
        let underlying: Error
        init(_ operation: String, _ underlying: Error) { self.operation = operation; self.underlying = underlying }
        var errorDescription: String? { "无法\(operation)外接屏恢复记录：\(underlying.localizedDescription)" }
    }
}

protocol DisplayRestrictionLeasing: AnyObject {
    func acquire() throws
    func release()
}

/// A lifetime flock prevents two app copies from overwriting each other's recovery journal.
final class FileDisplayRestrictionLease: DisplayRestrictionLeasing {
    private let url: URL
    private var descriptor: Int32?

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BatteryCycle/display-output-control.lock")) {
        self.url = url
    }

    func acquire() throws {
        guard descriptor == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let opened = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard opened >= 0 else { throw LeaseError("无法打开外接屏控制锁") }
        var keep = false
        defer { if !keep { _ = close(opened) } }
        var info = stat()
        guard fstat(opened, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_uid == geteuid(), fchmod(opened, mode_t(0o600)) == 0 else {
            throw LeaseError("外接屏控制锁不可用，未更改显示器设置")
        }
        var result: Int32
        repeat { result = flock(opened, LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
        guard result == 0 else {
            throw LeaseError("另一个 BatteryCycle 正在管理外接屏，请退出其他副本后重试")
        }
        descriptor = opened
        keep = true
    }

    func release() {
        guard let descriptor else { return }
        self.descriptor = nil
        _ = close(descriptor)
    }

    deinit { release() }

    private struct LeaseError: LocalizedError {
        let errorDescription: String?
        init(_ description: String) { errorDescription = description }
    }
}
