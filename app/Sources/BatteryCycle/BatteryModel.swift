import AppKit
import Foundation
import IOKit.ps
import ServiceManagement
import SwiftUI

/// 后台服务 batteryd 写出的状态（/var/run/batteryd.json）
struct DaemonStatus: Decodable {
    let pct: Int
    let ac: Bool
    let phase: String
    let enabled: Bool
    let low: Int
    let high: Int
    let updated: TimeInterval
}

enum Phase {
    case offline, paused, charge, discharge
}

@MainActor
final class BatteryModel: ObservableObject {
    static let statusURL = URL(fileURLWithPath: "/var/run/batteryd.json")
    static let configURL = URL(fileURLWithPath: "/Library/Application Support/batteryd/config")
    static let daemonPlistPath = "/Library/LaunchDaemons/com.local.batteryd.plist"

    @Published var pct: Int?
    @Published var onAC = false
    @Published var status: DaemonStatus?
    @Published var enabled = true
    @Published var low = 10
    @Published var high = 75
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var message: String?
    /// 读不到服务状态的具体原因，显示在面板上
    @Published var statusProblem: String?
    @Published var daemonInstalled = false

    private var timer: Timer?

    init() {
        loadConfig()
        refresh()
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
            pct = battery.pct
            onAC = battery.ac
        }
        daemonInstalled = FileManager.default.fileExists(atPath: Self.daemonPlistPath)
        do {
            let data = try Data(contentsOf: Self.statusURL)
            let s = try JSONDecoder().decode(DaemonStatus.self, from: data)
            status = s
            let age = Int(Date().timeIntervalSince1970 - s.updated)
            statusProblem = age < 90 ? nil : "状态已 \(age) 秒没有更新"
        } catch let error as DecodingError {
            status = nil
            statusProblem = "状态文件无法解析：\(error)"
        } catch {
            status = nil
            statusProblem = "读不到 \(Self.statusURL.path)：\(error.localizedDescription)"
        }
    }

    /// 服务每 30 秒写一次状态，超过 90 秒没更新视为未运行
    var daemonRunning: Bool {
        status != nil && statusProblem == nil
    }

    var phase: Phase {
        guard daemonRunning, let s = status else { return .offline }
        switch s.phase {
        case "charge": return .charge
        case "discharge": return .discharge
        default: return .paused
        }
    }

    private static func readBattery() -> (pct: Int, ac: Bool)? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (cur * 100 / max, d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
        }
        return nil
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
        runPrivileged(script: "install.sh", failure: "安装失败")
    }

    func uninstallDaemon() {
        runPrivileged(script: "uninstall.sh", failure: "卸载失败")
    }

    private func runPrivileged(script: String, failure: String) {
        guard let path = Bundle.main.url(forResource: script, withExtension: nil)?.path else {
            message = "\(failure)：App 内缺少 \(script)"
            return
        }
        let escaped = path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"/bin/sh \" & quoted form of \"\(escaped)\" with administrator privileges"

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) != -128 {   // -128：用户点了取消
            message = "\(failure)：\(error[NSAppleScript.errorMessage] as? String ?? "未知错误")"
        } else {
            message = nil
        }
        // 服务启动后几秒内会写出状态文件
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.loadConfig()
            self?.refresh()
        }
    }

    // MARK: - 显示

    var percentText: String {
        pct.map { "\($0)%" } ?? "--"
    }

    var menuBarSymbol: String {
        if phase == .charge && onAC { return "battery.100percent.bolt" }
        switch pct ?? 0 {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var title: String {
        switch phase {
        case .offline: return daemonInstalled ? "后台服务未运行" : "需要安装后台服务"
        case .paused: return "已暂停"
        case .charge: return onAC ? "充电中" : "等待接通电源"
        case .discharge: return "放电中"
        }
    }

    var subtitle: String {
        switch phase {
        case .offline:
            if !daemonInstalled { return "首次使用，点击下方按钮安装，需要输入一次管理员密码" }
            return statusProblem ?? "后台服务没有响应"
        case .paused: return "按系统默认方式充电"
        case .charge: return "充到 \(high)% 后停止充电"
        case .discharge: return "插着电也用电池，降到 \(low)% 后开始充电"
        }
    }

    var phaseSymbol: String {
        switch phase {
        case .offline: return daemonInstalled ? "exclamationmark.triangle.fill" : "arrow.down.app.fill"
        case .paused: return "pause.circle.fill"
        case .charge: return "bolt.fill"
        case .discharge: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch phase {
        case .offline: return daemonInstalled ? .red : .accentColor
        case .paused: return .secondary
        case .charge: return .green
        case .discharge: return .orange
        }
    }
}
