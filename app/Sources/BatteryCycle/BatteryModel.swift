import AppKit
import Foundation
import IOKit
import IOKit.ps
import ServiceManagement
import SwiftUI

/// 后台服务 batteryd 写出的状态（/var/run/batteryd.json）
struct DaemonStatus: Decodable, Equatable {
    let pct: Int
    let ac: Bool
    let phase: String
    let enabled: Bool
    let low: Int
    let high: Int
    let updated: TimeInterval
    /// 上次充到上限的时间（0 表示还没有）和当时的上限值；旧版服务没有这两项
    let reachedAt: TimeInterval?
    let reachedPct: Int?
    /// 故障原因（SMC 写入失败、读不到电量），空串表示正常；旧版服务没有这一项
    let fault: String?
}

/// 电池健康：当前满电容量占设计容量的百分比，以及充电循环次数
struct BatteryHealth: Equatable {
    let percent: Int
    let cycles: Int
}

enum Phase {
    case offline, fault, paused, charge, discharge, full
}

@MainActor
final class BatteryModel: ObservableObject {
    static let statusURL = URL(fileURLWithPath: "/var/run/batteryd.json")
    static let configURL = URL(fileURLWithPath: "/Library/Application Support/batteryd/config")
    /// 存在时后台服务临时充到 100%，充满后由服务删除
    static let fullChargeURL = URL(fileURLWithPath: "/Library/Application Support/batteryd/fullcharge")
    static let daemonPlistPath = "/Library/LaunchDaemons/com.local.batteryd.plist"
    static let daemonBinaryPath = "/usr/local/bin/batteryd"

    @Published var pct: Int?
    @Published var onAC = false
    /// 系统报告电池正在充电（不论是本 App 的充电阶段还是暂停时系统自己充）
    @Published var isCharging = false
    @Published var health: BatteryHealth?
    @Published var status: DaemonStatus?
    @Published var enabled = true
    @Published var low = 10
    @Published var high = 75
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var message: String?
    /// 一般提示（灰色），几秒后自动消失
    @Published var notice: String?
    /// 到达上下限时也发通知；每天好几次，默认关
    @Published var notifyThresholds = UserDefaults.standard.bool(forKey: "notifyThresholds") {
        didSet { UserDefaults.standard.set(notifyThresholds, forKey: "notifyThresholds") }
    }
    /// 读不到服务状态的具体原因，显示在面板上
    @Published var statusProblem: String?
    @Published var daemonInstalled = false
    /// 已安装的后台服务和 App 内置的不一致（更新 App 后忘了重新安装）
    @Published var daemonOutdated = false
    /// 正在安装 / 卸载时的提示，非 nil 时禁用相关按钮
    @Published var busy: String?

    private var timer: Timer?
    /// 上一次读到的有效状态，和新状态比较得出要通知的事件
    private var lastFresh: DaemonStatus?
    private var offlineSince: Date?
    private var notifiedOffline = false
    /// 用户自己点了取消充满，就不再通知「充满请求已取消」
    private var userCancelledFull = false

    init() {
        Notifier.shared.setup()
        loadConfig()
        refresh()
        checkDaemonVersion()
        // .common 模式：面板打开时也照常刷新
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - 读取

    func refresh() {
        if let battery = Self.readBattery() {
            update(\.pct, battery.pct)
            update(\.onAC, battery.ac)
            update(\.isCharging, battery.charging)
        }
        update(\.health, Self.readHealth())
        update(\.daemonInstalled, FileManager.default.fileExists(atPath: Self.daemonPlistPath))
        do {
            let data = try Data(contentsOf: Self.statusURL)
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let s = try decoder.decode(DaemonStatus.self, from: data)
            update(\.status, s)
            let age = Int(Date().timeIntervalSince1970 - s.updated)
            update(\.statusProblem, age < 90 ? nil : "状态已 \(age) 秒没有更新")
        } catch let error as DecodingError {
            update(\.status, nil)
            update(\.statusProblem, "状态文件无法解析：\(error)")
        } catch {
            update(\.status, nil)
            update(\.statusProblem, "读不到 \(Self.statusURL.path)：\(error.localizedDescription)")
        }
        detectEvents()
    }

    // MARK: - 通知

    private func detectEvents() {
        // 服务停止：持续 15 秒才通知，避开重新安装、睡眠唤醒时的短暂空档；
        // 只在本次运行中见过服务正常时才通知，App 刚启动时服务没开由面板提示即可
        if daemonInstalled && busy == nil && !daemonRunning {
            let since = offlineSince ?? Date()
            offlineSince = since
            if !notifiedOffline, lastFresh != nil, Date().timeIntervalSince(since) >= 15 {
                notifiedOffline = true
                Notifier.shared.send("后台服务已停止", "电池不再受控制。\(statusProblem ?? "")")
            }
            return
        }
        offlineSince = nil
        guard daemonRunning, let s = status else { return }
        notifiedOffline = false
        defer { lastFresh = s }
        guard let old = lastFresh else { return }

        let fault = s.fault ?? ""
        if !fault.isEmpty && fault != (old.fault ?? "") {
            Notifier.shared.send("无法控制充电", fault)
        }

        let reachedNew = (s.reachedAt ?? 0) > 0 && s.reachedAt != old.reachedAt
        if old.phase == "full" && s.phase != "full" {
            if reachedNew && s.reachedPct == 100 {
                Notifier.shared.send("已充满", "电量已到 100%，恢复 \(s.low)%–\(s.high)% 循环")
            } else if !userCancelledFull {
                Notifier.shared.send("充满请求已取消", "12 小时内没有充满，已恢复循环")
            }
            userCancelledFull = false
        } else if notifyThresholds {
            if reachedNew, let p = s.reachedPct {
                Notifier.shared.send("已充到 \(p)%", "停止充电，开始用电池")
            }
            if old.phase == "discharge" && s.phase == "charge" {
                Notifier.shared.send("已降到 \(s.pct)%", "开始充电，充到 \(s.high)% 停止")
            }
        }
    }

    // MARK: - 诊断

    /// 汇总版本、状态、设置和最近日志，复制到剪贴板，出问题时直接粘贴
    func copyDiagnostics() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var lines = [
            "BatteryCycle \(version)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)，机型 \(Self.hardwareModel())",
            "后台服务：\(daemonInstalled ? "已安装" : "未安装")\(daemonOutdated ? "（需要更新）" : "")，"
                + (daemonRunning ? "运行中" : (statusProblem ?? "未运行")),
            "面板：\(title)，电量 \(percentText)，\(onAC ? "接通电源" : "电池供电")，\(isCharging ? "正在充电" : "未充电")",
        ]
        if let h = health {
            lines.append("电池健康 \(h.percent)%，充电循环 \(h.cycles) 次")
        }
        lines += ["", "== \(Self.statusURL.path) ==", Self.readText(Self.statusURL.path)]
        lines += ["== \(Self.configURL.path) ==", Self.readText(Self.configURL.path)]
        if FileManager.default.fileExists(atPath: Self.fullChargeURL.path) {
            lines.append("（存在充满请求 \(Self.fullChargeURL.lastPathComponent)）")
        }
        lines += ["== \(Self.logPath) 最近内容 ==", Self.readTail(Self.logPath, bytes: 6000)]

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        showNotice("诊断信息已复制，可以直接粘贴")
    }

    static let logPath = "/var/log/batteryd.log"

    private static func readText(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "（读不到）"
    }

    /// 日志可能很大，只读末尾，并去掉被截断的第一行
    private static func readTail(_ path: String, bytes: UInt64) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "（读不到）" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        var text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        if size > bytes, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    private func showNotice(_ text: String) {
        notice = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.notice == text { self?.notice = nil }
        }
    }

    private func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<BatteryModel, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// 服务每 30 秒写一次状态，超过 90 秒没更新视为未运行
    var daemonRunning: Bool {
        status != nil && statusProblem == nil
    }

    /// 正在一次性充满；出故障时 phase 显示故障，但仍要能取消
    var fullChargeActive: Bool {
        daemonRunning && status?.phase == "full"
    }

    /// 逐字节比较已安装的 batteryd 和 App 内置的那份，不需要维护版本号
    func checkDaemonVersion() {
        guard daemonInstalled,
              let bundled = Bundle.main.url(forResource: "batteryd", withExtension: nil),
              let a = try? Data(contentsOf: bundled),
              let b = try? Data(contentsOf: URL(fileURLWithPath: Self.daemonBinaryPath))
        else {
            update(\.daemonOutdated, false)
            return
        }
        update(\.daemonOutdated, a != b)
    }

    var phase: Phase {
        guard daemonRunning, let s = status else { return .offline }
        if let fault = s.fault, !fault.isEmpty { return .fault }
        switch s.phase {
        case "charge": return .charge
        case "discharge": return .discharge
        case "full": return .full
        default: return .paused
        }
    }

    private static func readBattery() -> (pct: Int, ac: Bool, charging: Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (cur * 100 / max,
                    d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                    d[kIOPSIsChargingKey] as? Bool ?? false)
        }
        return nil
    }

    /// 从 IORegistry 的 AppleSmartBattery 读取；Apple Silicon 上 MaxCapacity 恒为 100，
    /// 实际满电容量（mAh）在 AppleRawMaxCapacity
    private static func readHealth() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
        }
        guard let design = int("DesignCapacity"), design > 0,
              let full = int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity"),
              let cycles = int("CycleCount")
        else { return nil }
        return BatteryHealth(percent: Int((Double(full) * 100 / Double(design)).rounded()), cycles: cycles)
    }

    // MARK: - 设置

    func loadConfig() {
        guard let text = try? String(contentsOf: Self.configURL, encoding: .utf8) else { return }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1]) else { continue }
            switch parts[0] {
            case "enabled": enabled = value != 0
            case "low": low = value
            case "high": high = value
            default: break
            }
        }
    }

    /// 先写临时文件再 rename，后台服务监听目录变化，设置立即生效
    func saveConfig() {
        let text = "enabled=\(enabled ? 1 : 0)\nlow=\(low)\nhigh=\(high)\n"
        let tmp = Self.configURL.deletingLastPathComponent().appendingPathComponent("config.tmp")
        do {
            try text.write(to: tmp, atomically: false, encoding: .utf8)
            guard rename(tmp.path, Self.configURL.path) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            message = nil
        } catch {
            message = "无法保存设置，请先安装后台服务"
        }
    }

    /// 立即充满：创建标记文件，后台服务监听到目录变化后马上开始充电
    func startFullCharge() {
        userCancelledFull = false
        if FileManager.default.createFile(atPath: Self.fullChargeURL.path, contents: Data()) {
            message = nil
        } else {
            message = "无法开始充满，请先安装后台服务"
        }
        refreshSoon()
    }

    func cancelFullCharge() {
        userCancelledFull = true
        do {
            try FileManager.default.removeItem(at: Self.fullChargeURL)
            message = nil
        } catch CocoaError.fileNoSuchFile {
            // 服务刚好充满并已删除
        } catch {
            message = "无法取消充满：\(error.localizedDescription)"
        }
        refreshSoon()
    }

    /// 服务收到变化后很快写出新状态，不必等 3 秒的定时刷新
    private func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refresh()
        }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            message = nil
        } catch {
            message = "无法设置登录启动：\(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: - 后台服务

    /// 用 App 内置的脚本安装后台服务（弹出系统密码框）
    func installDaemon() {
        runPrivileged(script: "install.sh", action: "安装")
    }

    func uninstallDaemon() {
        runPrivileged(script: "uninstall.sh", action: "卸载")
    }

    /// 在后台进程里用 osascript 申请管理员权限执行脚本，界面不会被卡住
    private func runPrivileged(script: String, action: String) {
        guard busy == nil else { return }
        guard let path = Bundle.main.url(forResource: script, withExtension: nil)?.path else {
            message = "\(action)失败：App 内缺少 \(script)"
            return
        }
        let shell = "/bin/sh '\(path.replacingOccurrences(of: "'", with: "'\\''"))' > /var/log/batteryd-install.log 2>&1"
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.terminationHandler = { [weak self] p in
            let output = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let status = p.terminationStatus
            Task { @MainActor in
                self?.finishPrivileged(action: action, status: status, output: output)
            }
        }

        busy = "正在\(action)…"
        message = nil
        do {
            try process.run()
        } catch {
            busy = nil
            message = "\(action)失败：\(error.localizedDescription)"
        }
    }

    private func finishPrivileged(action: String, status: Int32, output: String) {
        busy = nil
        if status != 0 && !output.contains("-128") {   // -128：用户点了取消
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            message = "\(action)失败：\(detail)（详情见 /var/log/batteryd-install.log）"
        }
        // 服务启动后几秒内会写出状态文件
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.loadConfig()
            self?.refresh()
            self?.checkDaemonVersion()
        }
    }

    // MARK: - 显示

    var percentText: String {
        pct.map { "\($0)%" } ?? "--"
    }

    /// 菜单栏图标：仿系统样式，百分比在左，电池在右；电池内部按实际电量填充，
    /// 正在充电时叠加闪电。整张画成模板图，深浅色菜单栏自动适配
    var menuBarImage: NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        let text = percentText as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = text.size(withAttributes: attrs)
        let body = NSSize(width: 22, height: 11)
        let nubWidth: CGFloat = 2
        let spacing: CGFloat = 4
        let height = ceil(max(body.height, textSize.height))
        let size = NSSize(width: ceil(textSize.width + spacing + body.width + nubWidth), height: height)
        let level = CGFloat(min(max(pct ?? 0, 0), 100)) / 100
        let charging = isCharging

        // 坐标都取整到整点，1x 和 2x 屏上线条和文字都落在像素格上，不会发虚
        return Self.renderTemplate(size: size) {
            text.draw(at: NSPoint(x: 0, y: round((height - textSize.height) / 2)), withAttributes: attrs)
            Self.drawBattery(in: NSRect(origin: NSPoint(x: ceil(textSize.width) + spacing,
                                                        y: floor((height - body.height) / 2)), size: body),
                             nubWidth: nubWidth, level: level, charging: charging)
        }
    }

    /// 按 1x/2x/3x 各画一份位图，系统按屏幕取最合适的一份。
    /// 不用延迟绘制的 NSImage：SwiftUI 可能把它按 1x 栅格化后再放大，在 Retina 屏上发虚
    private static func renderTemplate(size: NSSize, draw: () -> Void) -> NSImage {
        let image = NSImage(size: size)
        for scale: CGFloat in [1, 2, 3] {
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { continue }
            rep.size = size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            draw()
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        image.isTemplate = true
        return image
    }

    private static func drawBattery(in rect: NSRect, nubWidth: CGFloat, level: CGFloat, charging: Bool) {
        // 外框（半透明，和系统一样比填充浅）
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        outline.lineWidth = 1
        NSColor.black.withAlphaComponent(0.4).setStroke()
        outline.stroke()

        // 正极触点
        let nub = NSRect(x: rect.maxX, y: floor(rect.midY - 2), width: nubWidth, height: 4)
        NSColor.black.withAlphaComponent(0.4).setFill()
        NSBezierPath(roundedRect: nub, xRadius: 1, yRadius: 1).fill()

        // 电量填充：宽度按百分比，有电时至少留一条细线可见
        let inner = rect.insetBy(dx: 2, dy: 2)
        if level > 0 {
            let fill = NSRect(x: inner.minX, y: inner.minY,
                              width: max(inner.width * level, 1.5), height: inner.height)
            NSColor.black.setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        }

        guard charging else { return }
        // 闪电：比电池略高、上下探出外框，先挖出一圈空隙再画实心闪电
        let bolt = NSBezierPath()
        let x = rect.minX, y = rect.minY
        bolt.move(to: NSPoint(x: x + 14, y: y + 12.5))
        bolt.line(to: NSPoint(x: x + 7.5, y: y + 4.6))
        bolt.line(to: NSPoint(x: x + 11.3, y: y + 4.6))
        bolt.line(to: NSPoint(x: x + 8.5, y: y - 1.5))
        bolt.line(to: NSPoint(x: x + 15, y: y + 6.6))
        bolt.line(to: NSPoint(x: x + 11.2, y: y + 6.6))
        bolt.close()
        bolt.lineJoinStyle = .round
        // 用 clear 混合模式描一圈粗边，把闪电周围约 1.5pt 的填充和外框擦成透明
        let cg = NSGraphicsContext.current?.cgContext
        cg?.saveGState()
        cg?.setBlendMode(.clear)
        bolt.lineWidth = 3
        bolt.stroke()
        bolt.fill()
        cg?.restoreGState()
        NSColor.black.setFill()
        bolt.fill()
    }

    /// 例如「上次充到 75%：今天 14:32」
    var reachedText: String? {
        guard let s = status, let at = s.reachedAt, at > 0, let p = s.reachedPct else { return nil }
        let date = Date(timeIntervalSince1970: at)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'今天' HH:mm"
        } else if Calendar.current.isDateInYesterday(date) {
            formatter.dateFormat = "'昨天' HH:mm"
        } else {
            formatter.dateFormat = "M月d日 HH:mm"
        }
        return "上次充到 \(p)%：\(formatter.string(from: date))"
    }

    var title: String {
        switch phase {
        case .offline: return daemonInstalled ? "后台服务未运行" : "需要安装后台服务"
        case .fault: return "无法控制充电"
        case .paused: return "已暂停"
        case .charge: return onAC ? "充电中" : "等待接通电源"
        case .discharge: return "放电中"
        case .full: return onAC ? "正在充满" : "等待接通电源"
        }
    }

    var subtitle: String {
        switch phase {
        case .offline:
            if !daemonInstalled { return "首次使用，点击下方按钮安装，需要输入一次管理员密码" }
            return statusProblem ?? "后台服务没有响应"
        case .fault: return "\(status?.fault ?? "")，充电可能不受控制，详情见 /var/log/batteryd.log"
        case .paused: return "按系统默认方式充电"
        case .charge: return "充到 \(high)% 后停止充电"
        case .discharge: return "插着电也用电池，降到 \(low)% 后开始充电"
        case .full: return "充到 100% 后自动恢复循环"
        }
    }

    var phaseSymbol: String {
        switch phase {
        case .offline: return daemonInstalled ? "exclamationmark.triangle.fill" : "arrow.down.app.fill"
        case .fault: return "exclamationmark.octagon.fill"
        case .paused: return "pause.circle.fill"
        case .charge: return "bolt.fill"
        case .discharge: return "arrow.down.circle.fill"
        case .full: return "bolt.circle.fill"
        }
    }

    var tint: Color {
        switch phase {
        case .offline: return daemonInstalled ? .red : .accentColor
        case .fault: return .red
        case .paused: return .secondary
        case .charge: return .green
        case .discharge: return .orange
        case .full: return .blue
        }
    }
}
