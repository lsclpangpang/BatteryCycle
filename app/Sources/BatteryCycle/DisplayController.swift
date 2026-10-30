import AppKit
import CoreGraphics
import IOKit
import os

/// 排查插拔问题用：`log stream --predicate 'subsystem == "com.local.batterycycle"'`
private let displayLog = Logger(subsystem: "com.local.batterycycle", category: "display")

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
    /// 断开状态下被拔掉了：列表里不显示，插回来时自动恢复。系统会一直记着它是断开的，
    /// 不恢复的话插回来也不亮、列表里也没有它，只能注销或重启
    var unplugged = false
    /// 记录时的开机会话：系统重启后断开状态就没了，上次开机留下的拔掉记录直接丢掉，不用一直查硬件
    var boot: String = DisplayController.bootSession

    init(name: String, model: DisplayModel) {
        self.name = name
        self.model = model
    }

    /// 旧版本存的记录没有后加的字段，按默认值读
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        model = try c.decode(DisplayModel.self, forKey: .model)
        confirmedAttached = try c.decodeIfPresent(Bool.self, forKey: .confirmedAttached) ?? false
        unplugged = try c.decodeIfPresent(Bool.self, forKey: .unplugged) ?? false
        boot = try c.decodeIfPresent(String.self, forKey: .boot) ?? ""
    }
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
    /// 恢复失败过一次的显示器；再失败就标记为拔掉（硬件里看不到时）或从列表移除
    private var failedEnable: Set<CGDirectDisplayID> = []
    /// 插回来自动恢复失败、已经提示过的显示器；同型号几台时会反复标记、重试，只提示一次
    private var restoreFailedNotified: Set<CGDirectDisplayID> = []
    /// 各型号开始「硬件里数量不够」的时间；持续一段时间才算拔掉，避免唤醒等瞬间的抖动
    private var shortSince: [DisplayModel: Date] = [:]
    /// 唤醒（包括屏幕熄灭后点亮）后硬件信息要一会儿才稳定，这段时间不判断插拔
    private var wokeAt = Date.distantPast
    /// 系统睡眠、屏幕熄灭期间显示器可能进入待机，硬件信息不可信，不判断插拔。
    /// 分开记：系统可能在屏幕仍熄灭时短暂唤醒（如定时维护）
    private var systemAsleep = false
    private var screensAsleep = false
    private var wakeObservers: [NSObjectProtocol] = []
    private var observer: NSObjectProtocol?
    private var timer: Timer?
    /// 上次记到日志里的显示器状态，变了才记，避免定时刷新刷屏
    private var lastSnapshot = ""

    init() {
        let data = UserDefaults.standard.data(forKey: "disabledDisplays")
        let stored = data.flatMap { try? JSONDecoder().decode([String: DisabledDisplay].self, from: $0) } ?? [:]
        disabled = Dictionary(uniqueKeysWithValues: stored.compactMap { key, record in
            guard !record.unplugged || record.boot == Self.bootSession else { return nil }
            return CGDirectDisplayID(key).map { ($0, record) }
        })
        displayLog.notice("启动 boot=\(Self.bootSession, privacy: .public) 已存记录=\(stored.count) 载入=\(self.disabled.count)")
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
                    if !asleep { self.wokeAt = Date() }
                }
            })
        }
        // 拔掉、插回已断开的显示器时系统不发屏幕变化通知，只能定时去硬件里查
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
            // 插回来恢复成功、注销重启后系统恢复显示，或者在别处被打开了，记录作废
            if active && disabled[id] != nil && !recentlyDisabled(id) {
                forget(id, "已在显示")
            }
            list.append((id, knownNames[id] ?? disabled[id]?.name ?? "外接显示器", active && disabled[id] == nil))
        }
        let activeExternals = online.filter { CGDisplayIsActive($0) != 0 && disabled[$0] == nil }
        var restoreFailed: [String] = []
        logSnapshot(online: online)
        if !disabled.isEmpty, hardwareSettled, let attached = Self.attachedModels() {
            // 先恢复之前拔掉、现在插回来的，再找新拔掉的；同一轮里刚标记拔掉的不会马上被当成插回来
            restoreFailed = restoreReplugged(attached: attached, activeExternals: activeExternals)
            markUnplugged(attached: attached, activeExternals: activeExternals)
        } else {
            shortSince = [:]
        }
        for (id, record) in disabled where !record.unplugged && !list.contains(where: { $0.id == id }) {
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

        if !restoreFailed.isEmpty {
            // 插回来没能恢复：显示器连着却黑着，展开列表露出它的开关（打开时会再刷新一次，那时已不算拔掉，不会重复提示）
            if !manageDisplays { manageDisplays = true }
            message = "插回的「\(restoreFailed.joined(separator: "、"))」没能自动恢复，请打开开关再试"
        }
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
                // 偶尔失败可以再试；连续两次失败多半是显示器已经拔掉：硬件里看不到就标记拔掉等插回来，否则记录没用了
                if failedEnable.insert(display.id).inserted {
                    message = "无法恢复「\(display.name)」（\(error)），请再试一次"
                } else if markIfUnplugged(display.id) {
                    message = "「\(display.name)」已拔掉，插回来时会自动恢复"
                } else {
                    forget(display.id, "手动恢复连续失败")
                    message = "仍无法恢复「\(display.name)」，已从列表移除，可注销重新登录恢复"
                }
            } else if !markIfUnplugged(display.id) {
                forget(display.id, "手动恢复成功")
            }
        } else if let error {
            message = "无法断开「\(display.name)」（\(error)）"
        } else {
            displayLog.notice("断开 \(display.id) 型号=\(model.vendor)/\(model.product)")
            disabled[display.id] = DisabledDisplay(name: knownNames[display.id] ?? display.name, model: model)
            disabledAt[display.id] = Date()
            failedEnable.remove(display.id)
        }
        reload()
    }

    private func recentlyDisabled(_ id: CGDirectDisplayID) -> Bool {
        Date().timeIntervalSince(disabledAt[id] ?? .distantPast) < 5
    }

    private func forget(_ id: CGDirectDisplayID, _ reason: String) {
        if disabled[id] != nil { displayLog.notice("删除记录 \(id) 原因=\(reason, privacy: .public)") }
        disabled[id] = nil
        disabledAt[id] = nil
        failedEnable.remove(id)
        restoreFailedNotified.remove(id)
    }

    /// 恢复操作之后：硬件里已经看不到这台（拔线后还没来得及标记），恢复不会生效，
    /// 标记为拔掉、等插回来再恢复，不能删记录。只在确认过断开后硬件信息还在时判断
    private func markIfUnplugged(_ id: CGDirectDisplayID) -> Bool {
        guard let record = disabled[id], !record.unplugged, record.confirmedAttached,
              let attached = Self.attachedModels() else { return false }
        let activeExternals = Self.onlineDisplays().filter {
            CGDisplayIsBuiltin($0) == 0 && CGDisplayIsActive($0) != 0 && disabled[$0] == nil
        }
        let others = disabled.filter { $0.key != id && !$0.value.unplugged && $0.value.model == record.model }.count
        let available = attached[record.model, default: 0] - Self.countModels(activeExternals)[record.model, default: 0] - others
        guard available <= 0 else { return false }
        displayLog.notice("标记拔掉 \(id)（恢复操作后硬件里看不到）")
        disabled[id]?.unplugged = true
        failedEnable.remove(id)
        return true
    }

    /// 系统睡眠、屏幕熄灭期间显示器可能进入待机，唤醒后硬件信息也要一会儿才稳定，这些时候不判断插拔
    private var hardwareSettled: Bool {
        !systemAsleep && !screensAsleep && Date().timeIntervalSince(wokeAt) > 20
    }

    /// 断开的显示器被拔掉后从列表隐藏。硬件里同型号的显示器数量 = 正在显示的 + 断开的，
    /// 少了并且持续 10 秒以上，就说明有断开的被拔掉了
    private func markUnplugged(attached: [DisplayModel: Int], activeExternals: [CGDirectDisplayID]) {
        let active = Self.countModels(activeExternals)
        let candidates = disabled.keys.filter { disabled[$0]?.unplugged == false && !recentlyDisabled($0) }
        let groups = Dictionary(grouping: candidates) { disabled[$0]!.model }
        for (model, ids) in groups {
            let available = attached[model, default: 0] - active[model, default: 0]
            if available >= ids.count {
                shortSince[model] = nil
                for id in ids where disabled[id]?.confirmedAttached == false {
                    displayLog.notice("确认断开后硬件里仍能看到 \(id)")
                    disabled[id]?.confirmedAttached = true
                }
                continue
            }
            guard ids.contains(where: { disabled[$0]?.confirmedAttached == true }) else { continue }
            let since = shortSince[model] ?? Date()
            shortSince[model] = since
            guard Date().timeIntervalSince(since) >= 10 else { continue }
            shortSince[model] = nil
            // 先尝试恢复：万一只是显示器待机让硬件信息暂时消失，或者同型号的几台里分不清拔掉的是哪台，
            // 还连着的会亮起来，下次刷新时记录作废。真拔掉的恢复不会生效（即使返回成功，系统仍记着它是断开的，
            // 插回来照样黑屏），所以记录留着、标记为拔掉，等插回来再恢复
            for id in ids {
                displayLog.notice("检测到拔掉 \(id)")
                _ = configure(id, enabled: true)
                disabled[id]?.unplugged = true
                failedEnable.remove(id)
            }
        }
    }

    /// 拔掉的显示器插回来后恢复显示：硬件里这个型号的数量比「正在显示的 + 还连着的断开显示器」多，就是插回来了。
    /// 返回没能恢复的显示器名称
    private func restoreReplugged(attached: [DisplayModel: Int], activeExternals: [CGDirectDisplayID]) -> [String] {
        let unplugged = disabled.filter { $0.value.unplugged }
        guard !unplugged.isEmpty else { return [] }
        var spare = attached
        for (model, count) in Self.countModels(activeExternals) {
            spare[model, default: 0] -= count
        }
        for record in disabled.values where !record.unplugged {
            spare[record.model, default: 0] -= 1
        }
        var failed: [String] = []
        for (model, ids) in Dictionary(grouping: unplugged.keys, by: { unplugged[$0]!.model }) {
            guard spare[model, default: 0] > 0 else { continue }
            shortSince[model] = nil
            // 同型号的几台分不清插回来的是哪台，全部尝试恢复（对不在的无害）。成功的亮起来后下次刷新时记录作废；
            // 没成功的回到列表里（开关是关的），可以手动再试。多出来的、或者硬件信息抖动其实没插回来的，10 秒后会再被标记为拔掉
            var anySucceeded = false
            for id in ids.sorted() {
                displayLog.notice("检测到插回 \(id)，尝试恢复")
                if configure(id, enabled: true) == nil { anySucceeded = true }
                disabled[id]?.unplugged = false
                failedEnable.remove(id)
            }
            if !anySucceeded && !restoreFailedNotified.isSuperset(of: ids) {
                restoreFailedNotified.formUnion(ids)
                failed += ids.sorted().compactMap { disabled[$0]?.name }
            }
        }
        return failed
    }

    private static func countModels(_ ids: [CGDirectDisplayID]) -> [DisplayModel: Int] {
        var counts: [DisplayModel: Int] = [:]
        for id in ids {
            counts[DisplayModel(vendor: CGDisplayVendorNumber(id), product: CGDisplayModelNumber(id)), default: 0] += 1
        }
        return counts
    }

    /// 返回是否全部恢复成功；失败的留在列表里。拔掉的这时恢复不会生效，留着记录，插回来时自动恢复
    private func enableAll() -> Bool {
        var failed: [String] = []
        for (id, record) in disabled where !record.unplugged {
            if configure(id, enabled: true) == nil {
                if !markIfUnplugged(id) { forget(id, "关闭管理时恢复成功") }
            } else {
                failed.append(record.name)
            }
        }
        if !failed.isEmpty {
            message = "无法恢复「\(failed.joined(separator: "、"))」，请再试一次或注销重新登录"
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
            displayLog.notice("配置 \(id) enabled=\(enabled) 调用失败=\(r)")
            return "错误 \(r)"
        }
        let done = CGCompleteDisplayConfiguration(config, .forSession)
        displayLog.notice("配置 \(id) enabled=\(enabled) 结果=\(done.rawValue)")
        return done == .success ? nil : "错误 \(done.rawValue)"
    }

    private func logSnapshot(online: [CGDirectDisplayID]) {
        let displays = online.map { id in
            "\(id)[\(CGDisplayIsActive(id) != 0 ? "显示" : "未显示") \(CGDisplayVendorNumber(id))/\(CGDisplayModelNumber(id))]"
        }
        let hardware = Self.attachedModels().map { counts in
            counts.map { "\($0.key.vendor)/\($0.key.product)×\($0.value)" }.sorted().joined(separator: " ")
        } ?? "查不到"
        let records = disabled.keys.sorted().map { id in
            let r = disabled[id]!
            return "\(id)[\(r.model.vendor)/\(r.model.product) 确认=\(r.confirmedAttached) 拔掉=\(r.unplugged)]"
        }
        let snapshot = "在线外接=\(displays.joined(separator: " ")) 硬件=\(hardware) 记录=\(records.joined(separator: " ")) 可判断=\(hardwareSettled)"
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        displayLog.notice("\(snapshot, privacy: .public)")
    }

    /// 本次开机的会话 UUID，读不到时为空。不用开机时间：系统校时会改动它
    nonisolated static let bootSession: String = {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }()

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
