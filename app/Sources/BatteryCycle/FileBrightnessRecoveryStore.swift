import Foundation

/// Written before changing either display setting; retained until the recorded policy is restored.
struct FileBrightnessRecoveryStore: BrightnessRecoveryStore {
    let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("BatteryCycle/brightness-recovery.json")) {
        self.url = url
    }

    func load() throws -> BrightnessRecoveryRecord? {
        do {
            return try JSONDecoder().decode(BrightnessRecoveryRecord.self, from: Data(contentsOf: url))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch {
            throw StoreError(operation: "读取", underlying: error)
        }
    }

    func save(_ record: BrightnessRecoveryRecord) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(record).write(to: url, options: .atomic)
        } catch {
            throw StoreError(operation: "保存", underlying: error)
        }
    }

    func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            return
        } catch {
            throw StoreError(operation: "清除", underlying: error)
        }
    }

    private struct StoreError: LocalizedError {
        let operation: String
        let underlying: Error
        var errorDescription: String? { "无法\(operation)屏幕亮度恢复记录：\(underlying.localizedDescription)" }
    }
}
