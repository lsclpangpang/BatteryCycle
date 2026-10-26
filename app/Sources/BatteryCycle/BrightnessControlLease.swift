import Foundation
import Darwin

/// The controller holds ownership before recovery and for its entire lifetime.
protocol BrightnessControlLeasing: AnyObject {
    func acquire() throws
    func release()
}

/// A separate, persistent inode protects both hardware control and the replaceable journal.
/// Calls are serialized by the owning controller. Closing the descriptor (including process
/// death) releases ownership; never unlink the file, which could create two independent locks.
final class FileBrightnessControlLease: BrightnessControlLeasing {
    private let url: URL
    private var descriptor: Int32?

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BatteryCycle/brightness-control.lock")) {
        self.url = url
    }

    func acquire() throws {
        guard descriptor == nil else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw LeaseError.storage("创建屏幕控制目录", error.localizedDescription)
        }
        let opened = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard opened >= 0 else { throw posixError("打开屏幕控制锁", errno) }
        var keepDescriptor = false
        defer { if !keepDescriptor { _ = close(opened) } }

        var info = stat()
        guard fstat(opened, &info) == 0 else { throw posixError("检查屏幕控制锁", errno) }
        guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_uid == geteuid() else {
            throw LeaseError.storage("检查屏幕控制锁", "锁文件不是当前用户拥有的普通文件")
        }
        guard fchmod(opened, mode_t(0o600)) == 0 else { throw posixError("设置屏幕控制锁权限", errno) }

        var result: Int32
        repeat { result = flock(opened, LOCK_EX | LOCK_NB) } while result != 0 && errno == EINTR
        guard result == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { throw LeaseError.inUse }
            throw posixError("取得屏幕控制权", code)
        }
        descriptor = opened
        keepDescriptor = true
    }

    func release() {
        guard let opened = descriptor else { return }
        descriptor = nil
        // close releases flock and avoids unlocking any other instance's descriptor.
        _ = close(opened)
    }

    deinit { release() }

    private func posixError(_ operation: String, _ code: Int32) -> LeaseError {
        LeaseError.storage(operation, String(cString: strerror(code)))
    }

    private enum LeaseError: LocalizedError {
        case inUse
        case storage(String, String)

        var errorDescription: String? {
            switch self {
            case .inUse:
                return "另一个 BatteryCycle 正在管理屏幕亮度，请退出其他副本后重试"
            case let .storage(operation, reason):
                return "无法\(operation)，未调整屏幕：\(reason)"
            }
        }
    }
}
