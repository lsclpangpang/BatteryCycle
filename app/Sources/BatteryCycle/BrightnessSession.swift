import Foundation

/// Use the panel's persistent UUID, never its position in the display list or the main display ID.
struct BrightnessSnapshot: Codable, Equatable {
    let displayID: String
    let brightness: Float
    let automaticBrightness: Bool
}

/// Recovery policy is separate from a hardware snapshot. Once a brightness key takes over,
/// even crash recovery must leave the user's new brightness alone and restore only automation.
struct BrightnessRecoveryRecord: Codable, Equatable {
    let displayID: String
    let brightness: Float
    let automaticBrightness: Bool
    let restoresBrightness: Bool

    init(displayID: String, brightness: Float, automaticBrightness: Bool, restoresBrightness: Bool = true) {
        self.displayID = displayID
        self.brightness = brightness
        self.automaticBrightness = automaticBrightness
        self.restoresBrightness = restoresBrightness
    }

    init(snapshot: BrightnessSnapshot, restoresBrightness: Bool = true) {
        self.init(displayID: snapshot.displayID, brightness: snapshot.brightness,
                  automaticBrightness: snapshot.automaticBrightness, restoresBrightness: restoresBrightness)
    }

    var snapshot: BrightnessSnapshot {
        BrightnessSnapshot(displayID: displayID, brightness: brightness, automaticBrightness: automaticBrightness)
    }

    private enum CodingKeys: String, CodingKey {
        case displayID, brightness, automaticBrightness, restoresBrightness
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayID = try values.decode(String.self, forKey: .displayID)
        brightness = try values.decode(Float.self, forKey: .brightness)
        automaticBrightness = try values.decode(Bool.self, forKey: .automaticBrightness)
        // Previous app versions saved the three snapshot fields directly.
        restoresBrightness = try values.contains(.restoresBrightness)
            ? values.decode(Bool.self, forKey: .restoresBrightness) : true
    }
}

protocol BrightnessBackend {
    func snapshot() throws -> BrightnessSnapshot
    func setBrightness(_ value: Float, displayID: String) throws
    func setAutomaticBrightness(_ enabled: Bool, displayID: String) throws
}

protocol BrightnessRecoveryStore {
    func load() throws -> BrightnessRecoveryRecord?
    func save(_ record: BrightnessRecoveryRecord) throws
    func clear() throws
}

private struct BrightnessSessionError: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { errorDescription = description }
}

/// Synchronous transaction logic. The owner serializes calls and suspends enforcement during sleep.
/// A saved recovery record is written before either system setting changes and cleared only after
/// the recorded restoration policy has been applied and verified.
final class MinimumBrightnessSession {
    private let backend: any BrightnessBackend
    private let store: any BrightnessRecoveryStore
    private var original: BrightnessRecoveryRecord?
    private var recoveryStateKnown = false
    private var restorationVerified = false
    private let uptime: () -> TimeInterval
    private var enabledAt: TimeInterval = 0
    private struct MinimumWrite {
        let brightness: Float
        let sampledAt: TimeInterval
        let finishedAt: TimeInterval
    }
    private var lastMinimumWrite: MinimumWrite?
    private var manualCorrection: MinimumWrite?
    private(set) var isEnabled = false

    /// A live lock has a recovery record too, but needs no recovery action in the UI.
    var needsRecovery: Bool { !isEnabled && (original != nil || !recoveryStateKnown) }
    private static let tolerance: Float = 0.002

    init(backend: any BrightnessBackend, store: any BrightnessRecoveryStore,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.backend = backend
        self.store = store
        self.uptime = uptime
    }

    func enable() throws {
        guard !isEnabled else { return }
        try loadRecovery()
        guard original == nil else {
            throw BrightnessSessionError("上次的屏幕设置尚未恢复，请先重试恢复")
        }
        let before = try checkedSnapshot()
        let recovery = BrightnessRecoveryRecord(snapshot: before)
        do {
            try store.save(recovery)
        } catch {
            // A failed save may still have reached disk. Re-read before any future enable so an
            // uncertain result can never overwrite the one recovery record we may already have.
            recoveryStateKnown = false
            throw BrightnessSessionError("无法保存屏幕恢复记录，未调整亮度：\(error.localizedDescription)")
        }
        original = recovery
        restorationVerified = false
        enabledAt = uptime()
        lastMinimumWrite = nil
        manualCorrection = nil
        do {
            try applyMinimum(displayID: before.displayID, forceBrightnessWrite: true)
            isEnabled = true
        } catch {
            try failAndRestore(error)
        }
    }

    func disable() throws {
        isEnabled = false
        try loadRecovery()
        try restoreOriginal()
    }

    /// App launches always recover the previous session, rather than silently dimming again.
    func recover() throws {
        try disable()
    }

    func enforce() throws {
        guard isEnabled, let original else { return }
        do {
            try applyMinimum(displayID: original.displayID)
        } catch {
            try failAndRestore(error)
        }
    }

    /// Called only for a genuine brightness-key event. Stop enforcement immediately, but let
    /// macOS process the key before finishing. The original brightness is never restored.
    /// A recent value overwritten by our own enforcement can be repaired once, in memory only.
    func beginManualAdjustment(keyTimestamp: TimeInterval? = nil, increasesBrightness: Bool = false) throws {
        guard isEnabled, let previous = original else {
            // A later down press is intentional, including when it returns the panel to zero.
            if !increasesBrightness { manualCorrection = nil }
            return
        }
        isEnabled = false
        let handoff = BrightnessRecoveryRecord(snapshot: previous.snapshot, restoresBrightness: false)
        original = handoff
        restorationVerified = false
        do {
            try store.save(handoff)
            if increasesBrightness, let keyTimestamp, keyTimestamp.isFinite,
               keyTimestamp > 0, keyTimestamp >= enabledAt,
               let write = lastMinimumWrite,
               keyTimestamp <= write.sampledAt, write.sampledAt <= write.finishedAt,
               uptime() >= write.finishedAt, uptime() - keyTimestamp <= 2 {
                manualCorrection = write
            }
            lastMinimumWrite = nil
        } catch {
            manualCorrection = nil
            lastMinimumWrite = nil
            let saveError = error
            // Never resume locking after a real key event, even if storage is unavailable.
            // Restore automation and remove the old full-recovery record if possible; keep
            // the in-memory handoff policy for every retry in this process.
            do {
                try restoreOriginal()
            } catch {
                throw BrightnessSessionError("已交由亮度键控制，但手动接管记录保存失败，原设置尚未完全恢复。请重试恢复后再退出：\(saveError.localizedDescription)；\(error.localizedDescription)")
            }
            throw BrightnessSessionError("已交由亮度键控制并恢复自动亮度设置，但手动接管记录保存失败：\(saveError.localizedDescription)")
        }
    }

    func finishManualAdjustment() throws {
        // A stale delayed callback must never cancel a lock the user subsequently enabled.
        guard !isEnabled, original?.restoresBrightness == false else { return }
        try restoreOriginal()
    }

    private func loadRecovery() throws {
        guard !recoveryStateKnown else { return }
        do {
            let saved = try store.load()
            if let saved { try validate(saved.snapshot) }
            original = saved
            restorationVerified = false
            recoveryStateKnown = true
        } catch {
            throw BrightnessSessionError("无法读取屏幕恢复记录，请重试恢复：\(error.localizedDescription)")
        }
    }

    private func applyMinimum(displayID: String, forceBrightnessWrite: Bool = false) throws {
        var sampledAt = uptime()
        var current = try checkedSnapshot(matching: displayID)
        let automationWasEnabled = current.automaticBrightness
        if current.automaticBrightness {
            try backend.setAutomaticBrightness(false, displayID: displayID)
            sampledAt = uptime()
            current = try checkedSnapshot(matching: displayID)
            guard !current.automaticBrightness else {
                throw BrightnessSessionError("系统自动亮度未能暂停")
            }
        }
        // Activation always requests the actual minimum. The tolerance only accommodates
        // hardware readback quantization and avoids repeated writes while already locked.
        if forceBrightnessWrite || !near(current.brightness, 0) {
            let overwritten = current.brightness
            try backend.setBrightness(0, displayID: displayID)
            // Activation and changes observed while ALS was enabled are not attributable to
            // a manual key. Do not resurrect those values when a later key arrives.
            lastMinimumWrite = !forceBrightnessWrite && !automationWasEnabled && !near(overwritten, 0)
                ? MinimumWrite(brightness: overwritten, sampledAt: sampledAt, finishedAt: uptime()) : nil
            current = try checkedSnapshot(matching: displayID)
        }
        guard !current.automaticBrightness, near(current.brightness, 0) else {
            throw BrightnessSessionError("无法保持屏幕最低亮度")
        }
    }

    private func failAndRestore(_ cause: Error) throws {
        isEnabled = false
        do {
            try restoreOriginal()
        } catch {
            throw BrightnessSessionError("最低亮度模式已停止：\(cause.localizedDescription)；\(error.localizedDescription)")
        }
        throw BrightnessSessionError("无法锁定最低亮度，原设置已恢复：\(cause.localizedDescription)")
    }

    private func restoreOriginal() throws {
        guard let original else { return }
        if !restorationVerified {
            // Even an initial read/UUID failure ends this one-shot correction attempt.
            let correction = manualCorrection
            manualCorrection = nil
            let current = try checkedSnapshot(matching: original.displayID)
            // Temporarily suspend an externally re-enabled sensor while checking the restored
            // brightness. If suspension fails, the verified final values below decide whether
            // recovery succeeded; still attempt both restorations independently.
            if original.restoresBrightness, current.automaticBrightness {
                try? backend.setAutomaticBrightness(false, displayID: original.displayID)
            }
            var failures: [String] = []
            if original.restoresBrightness {
                do {
                    try backend.setBrightness(original.brightness, displayID: original.displayID)
                    let restored = try checkedSnapshot(matching: original.displayID)
                    guard near(restored.brightness, original.brightness) else {
                        throw BrightnessSessionError("恢复后的亮度与原值不一致")
                    }
                } catch {
                    failures.append("亮度恢复失败：\(error.localizedDescription)")
                }
            } else if let correction {
                if !current.automaticBrightness, near(current.brightness, 0),
                   uptime() >= correction.finishedAt, uptime() - correction.finishedAt <= 2 {
                    do {
                        try backend.setBrightness(correction.brightness, displayID: original.displayID)
                        let corrected = try checkedSnapshot(matching: original.displayID)
                        guard near(corrected.brightness, correction.brightness) else {
                            throw BrightnessSessionError("亮度按键的调整未能保留")
                        }
                    } catch {
                        failures.append("按键亮度恢复失败：\(error.localizedDescription)")
                    }
                }
            }
            do {
                try backend.setAutomaticBrightness(original.automaticBrightness, displayID: original.displayID)
                let restored = try checkedSnapshot(matching: original.displayID)
                guard restored.automaticBrightness == original.automaticBrightness else {
                    throw BrightnessSessionError("自动亮度设置未恢复")
                }
                // Re-enabling the original ambient-light setting may immediately change the
                // brightness. It was verified above while the sensor was suspended.
                if original.restoresBrightness, !original.automaticBrightness,
                   !near(restored.brightness, original.brightness) {
                    throw BrightnessSessionError("恢复后的亮度发生变化")
                }
            } catch {
                failures.append("自动亮度恢复失败：\(error.localizedDescription)")
            }
            guard failures.isEmpty else {
                throw BrightnessSessionError("原设置尚未完全恢复，请重试恢复。\(failures.joined(separator: "；"))")
            }
            restorationVerified = true
        }
        do {
            try store.clear()
        } catch {
            // Retrying removal must not overwrite brightness changes made by the user after
            // settings were already successfully restored in this process.
            throw BrightnessSessionError("屏幕设置已恢复，但恢复记录未能清除，请重试恢复：\(error.localizedDescription)")
        }
        self.original = nil
        restorationVerified = false
        lastMinimumWrite = nil
        manualCorrection = nil
    }

    private func checkedSnapshot(matching displayID: String? = nil) throws -> BrightnessSnapshot {
        let snapshot = try backend.snapshot()
        try validate(snapshot)
        if let displayID, snapshot.displayID != displayID {
            throw BrightnessSessionError("内置屏幕与恢复记录不匹配，未调整亮度")
        }
        return snapshot
    }

    private func validate(_ snapshot: BrightnessSnapshot) throws {
        guard !snapshot.displayID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              snapshot.brightness.isFinite, (0...1).contains(snapshot.brightness) else {
            throw BrightnessSessionError("屏幕亮度或标识无效，未调整亮度")
        }
    }

    private func near(_ first: Float, _ second: Float) -> Bool {
        abs(first - second) <= Self.tolerance
    }
}
