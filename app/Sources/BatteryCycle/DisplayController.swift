import AppKit
import CoreGraphics
import IOKit

struct ExternalDisplay: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let enabled: Bool
}

/// 显示器型号（EDID 里的厂商、产品编号），用来在硬件层面认出被断开的显示器
private struct DisplayModel: Codable, Hashable {
    let vendor: UInt32
    let product: UInt32
}

/// 本 App 断开的显示器。断开后系统里就查不到它的名字、型号了，只能靠这里记住
private struct DisabledDisplay: Codable {
    let name: String
    let model: DisplayModel
    /// 断开后在硬件里确实还能看到这个型号；之后看不到了才算拔掉，
    /// 这样即使某些系统上断开后硬件信息也消失，也不会误删还连着的显示器。存下来，App 重启后照样能判断
    var confirmedAttached = false
}

/// 断开 / 恢复外接显示器：和拔掉线的效果一样，系统不再输出画面，窗口挪到其他屏幕
@MainActor
final class DisplayController: ObservableObject {
    /// 在面板里列出外接显示器，可以逐个断开；默认关。关掉时恢复所有被断开的显示器
    @Published var manageDisplays = UserDefaults.standard.bool(forKey: "manageDisplays") {
        didSet {
            message = nil
            if !manageDisplays && !enableAll() {
                // 有显示器恢复失败：保持打开，否则列表收起后就没办法再恢复了
                manageDisplays = true
            }
            UserDefaults.standard.set(manageDisplays, forKey: "manageDisplays")
            reload()
        }
    }
    @Published private(set) var displays: [ExternalDisplay] = []
    @Published var message: String?

    private var disabled: [CGDirectDisplayID: DisabledDisplay] {
        didSet {
            let stored = Dictionary(uniqueKeysWithValues: disabled.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(try? JSONEncoder().encode(stored), forKey: "disabledDisplays")
        }
    }
    /// 看到过的显示器名称，断开后仍能显示
    private var knownNames: [CGDirectDisplayID: String] = [:]
    /// 刚断开的时间：系统要过一会儿才把它标成不活跃，这段时间里不能当成「已自动恢复」
    private var disabledAt: [CGDirectDisplayID: Date] = [:]
    /// 恢复失败过一次的显示器；再失败就从列表移除
    private var failedEnable: Set<CGDirectDisplayID> = []
    /// 拔线检测里自动恢复失败过一次的显示器；和手动重试分开计，硬件数量恢复正常就清零
    private var autoFailed: Set<CGDirectDisplayID> = []
    /// 各型号开始「硬件里数量不够」的时间；持续一段时间才算拔掉，避免唤醒等瞬间的抖动
    private var shortSince: [DisplayModel: Date] = [:]
    /// 唤醒（包括屏幕熄灭后点亮）后硬件信息要一会儿才稳定，这段时间不判断拔线
    private var wokeAt = Date.distantPast
    /// 系统睡眠、屏幕熄灭期间显示器可能进入待机，硬件信息不可信，不判断拔线。
    /// 分开记：系统可能在屏幕仍熄灭时短暂唤醒（如定时维护）
    private var systemAsleep = false
    private var screensAsleep = false
    private var wakeObservers: [NSObjectProtocol] = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?

    init() {
        let data = UserDefaults.standard.data(forKey: "disabledDisplays")
        let stored = data.flatMap { try? JSONDecoder().decode([String: DisabledDisplay].self, from: $0) } ?? [:]
        disabled = Dictionary(uniqueKeysWithValues: stored.compactMap { key, record in
            CGDirectDisplayID(key).map { ($0, record) }
        })
        reload()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        let center = NSWorkspace.shared.notificationCenter
        let events: [(NSNotification.Name, ReferenceWritableKeyPath<DisplayController, Bool>, Bool)] = [
            (NSWorkspace.willSleepNotification, \.systemAsleep, true),
            (NSWorkspace.didWakeNotification, \.systemAsleep, false),
            (NSWorkspace.screensDidSleepNotification, \.screensAsleep, true),
            (NSWorkspace.screensDidWakeNotification, \.screensAsleep, false),
        ]
        for (name, flag, asleep) in events {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self[keyPath: flag] = asleep
                    // 熄灭前后记下的「数量不够」不能算进点亮后的持续时间
                    self.shortSince = [:]
                    self.autoFailed = []
                    if !asleep { self.wokeAt = Date() }
                }
            })
        }
        // 拔掉已断开的显示器时系统不发屏幕变化通知，只能定时去硬件里查
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.disabled.isEmpty else { return }
                self.reload()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reload() {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                knownNames[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
            }
        }

        let online = Self.onlineDisplays().filter { CGDisplayIsBuiltin($0) == 0 }
        var list: [(id: CGDirectDisplayID, name: String, enabled: Bool)] = []
        for id in online {
            let active = CGDisplayIsActive(id) != 0
            // 重新插线、重启后系统会自己恢复显示，记录作废
            if active && disabled[id] != nil && !recentlyDisabled(id) {
                forget(id)
            }
            list.append((id, knownNames[id] ?? disabled[id]?.name ?? "外接显示器", active && disabled[id] == nil))
        }
        forgetUnplugged(activeExternals: online.filter { CGDisplayIsActive($0) != 0 && disabled[$0] == nil })
        for (id, record) in disabled where !list.contains(where: { $0.id == id }) {
            list.append((id, record.name, false))
        }
        list.sort { $0.id < $1.id }

        // 两台同型号显示器名字相同，加序号区分
        var seen: [String: Int] = [:]
        let counts = Dictionary(list.map { ($0.name, 1) }, uniquingKeysWith: +)
        let result = list.map { item -> ExternalDisplay in
            guard counts[item.name, default: 0] > 1 else {
                return ExternalDisplay(id: item.id, name: item.name, enabled: item.enabled)
            }
            seen[item.name, default: 0] += 1
            return ExternalDisplay(id: item.id, name: "\(item.name) (\(seen[item.name]!))", enabled: item.enabled)
        }
        if displays != result { displays = result }
    }

    func setEnabled(_ display: ExternalDisplay, _ on: Bool) {
        message = nil
        if !on {
            var count: UInt32 = 0
            _ = CGGetActiveDisplayList(0, nil, &count)
            guard count > 1 else {
                message = "至少要留一块屏幕在显示"
                return
            }
        }
        // 断开前先记下型号，断开后就读不到了
        let model = DisplayModel(vendor: CGDisplayVendorNumber(display.id), product: CGDisplayModelNumber(display.id))
        let error = configure(display.id, enabled: on)
        if on {
            if let error {
                // 偶尔失败可以再试；连续两次失败多半是显示器已经拔掉，记录没用了
                if failedEnable.insert(display.id).inserted {
                    message = "无法恢复「\(display.name)」（\(error)），请再试一次"
                } else {
                    forget(display.id)
                    message = "仍无法恢复「\(display.name)」，已从列表移除，请重新插拔线"
                }
            } else {
                forget(display.id)
            }
        } else if let error {
            message = "无法断开「\(display.name)」（\(error)）"
        } else {
            disabled[display.id] = DisabledDisplay(name: knownNames[display.id] ?? display.name, model: model)
            disabledAt[display.id] = Date()
            failedEnable.remove(display.id)
        }
        reload()
    }

    private func recentlyDisabled(_ id: CGDirectDisplayID) -> Bool {
        Date().timeIntervalSince(disabledAt[id] ?? .distantPast) < 5
    }

    private func forget(_ id: CGDirectDisplayID) {
        disabled[id] = nil
        disabledAt[id] = nil
        failedEnable.remove(id)
        autoFailed.remove(id)
    }

    /// 断开的显示器被拔掉后从列表移除。硬件里同型号的显示器数量 = 正在显示的 + 断开的，
    /// 少了并且持续 10 秒以上，就说明有断开的被拔掉了
    private func forgetUnplugged(activeExternals: [CGDirectDisplayID]) {
        guard !systemAsleep, !screensAsleep, Date().timeIntervalSince(wokeAt) > 20 else {
            shortSince = [:]
            return
        }
        guard !disabled.isEmpty, let attached = Self.attachedModels() else { return }
        var active: [DisplayModel: Int] = [:]
        for id in activeExternals {
            active[DisplayModel(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id)), default: 0] += 1
        }
        let groups = Dictionary(grouping: disabled.keys.filter { !recentlyDisabled($0) }) { disabled[$0]!.model }
        for (model, ids) in groups {
            let available = attached[model, default: 0] - active[model, default: 0]
            if available >= ids.count {
                shortSince[model] = nil
                autoFailed.subtract(ids)
                for id in ids where disabled[id]?.confirmedAttached == false {
                    disabled[id]?.confirmedAttached = true
                }
                continue
            }
            guard ids.contains(where: { disabled[$0]?.confirmedAttached == true }) else { continue }
            let since = shortSince[model] ?? Date()
            shortSince[model] = since
            guard Date().timeIntervalSince(since) >= 10 else { continue }
            shortSince[model] = nil
            // 先尝试恢复再移除：真拔掉了恢复无害；万一只是显示器待机让硬件信息暂时消失，
            // 它会亮起来重新出现在列表里，而不是还连着、黑着却没了开关。
            // 同型号的几台里分不清拔掉的是哪台时也一样，恢复成功的会重新出现在列表里
            for id in ids {
                if configure(id, enabled: true) == nil {
                    forget(id)
                } else if available <= 0 && !autoFailed.insert(id).inserted {
                    // 这个型号断开的全都不在了，连续两轮恢复失败，确实拔掉了
                    forget(id)
                }
                // 其余失败的留着，下一轮数量对得上时再处理
            }
        }
    }

    /// 返回是否全部恢复成功；失败的留在列表里
    private func enableAll() -> Bool {
        var failed: [String] = []
        for (id, record) in disabled {
            if configure(id, enabled: true) == nil {
                forget(id)
            } else {
                failed.append(record.name)
            }
        }
        if !failed.isEmpty {
            message = "无法恢复「\(failed.joined(separator: "、"))」，请再试一次或重新插拔线"
        }
        return failed.isEmpty
    }

    /// 只在本次登录期间生效：注销、重启后显示器都会恢复，不会一直黑屏
    private func configure(_ id: CGDirectDisplayID, enabled: Bool) -> String? {
        guard let setEnabled = Self.configureDisplayEnabled else { return "系统不支持" }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return "无法开始配置" }
        let r = setEnabled(config, id, enabled)
        guard r == 0 else {
            _ = CGCancelDisplayConfiguration(config)
            return "错误 \(r)"
        }
        let done = CGCompleteDisplayConfiguration(config, .forSession)
        return done == .success ? nil : "错误 \(done.rawValue)"
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    /// 硬件上接着的显示器（含内建屏）按型号计数：Apple 芯片的帧缓冲在 IORegistry 里带有
    /// DisplayAttributes，拔掉后随之消失。查不到任何帧缓冲时返回 nil，不做判断
    private static func attachedModels() -> [DisplayModel: Int]? {
        var counts: [DisplayModel: Int] = [:]
        var seenEntries: Set<UInt64> = []
        var foundFramebuffer = false
        for className in ["IOMobileFramebuffer", "AppleCLCD2", "IOMobileFramebufferShim"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
            else { continue }
            defer { IOObjectRelease(iterator) }
            while true {
                let service = IOIteratorNext(iterator)
                if service == 0 { break }
                defer { IOObjectRelease(service) }
                var entryID: UInt64 = 0
                _ = IORegistryEntryGetRegistryEntryID(service, &entryID)
                if seenEntries.insert(entryID).inserted {
                    foundFramebuffer = true
                    if let attrs = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString,
                                                                   kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
                       let product = attrs["ProductAttributes"] as? [String: Any],
                       let vendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                       let productID = (product["ProductID"] as? NSNumber)?.uint32Value {
                        counts[DisplayModel(vendor: vendor, product: productID), default: 0] += 1
                    }
                }
            }
        }
        return foundFramebuffer ? counts : nil
    }

    /// 私有函数，BetterDisplay、displayplacer 断开显示器用的也是它；运行时查找，找不到就提示不支持
    private typealias ConfigureEnabled = @convention(c) (CGDisplayConfigRef, CGDirectDisplayID, Bool) -> Int32
    private static let configureDisplayEnabled: ConfigureEnabled? = {
        let candidates = [
            ("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", "SLSConfigureDisplayEnabled"),
            ("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", "CGSConfigureDisplayEnabled"),
        ]
        for (path, name) in candidates {
            if let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, name) {
                return unsafeBitCast(sym, to: ConfigureEnabled.self)
            }
        }
        return nil
    }()
}
