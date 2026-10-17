import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: BatteryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LevelBar(pct: model.pct ?? 0, low: model.low, high: model.high, tint: model.tint)
            if let health = model.health {
                HealthRow(health: health)
            }
            // 只在放电阶段显示：这时它就是「从什么时候开始用电池」
            if model.phase == .discharge, let reached = model.reachedText {
                Label(reached, systemImage: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider()

            SwitchRow(title: "启用充放电循环", isOn: Binding(
                get: { model.enabled },
                set: { model.enabled = $0; model.saveConfig() }
            ))
            ThresholdSlider(title: "低于此电量开始充电", value: $model.low, range: BatteryModel.lowRange) {
                model.saveConfig()
            }
            .disabled(!model.enabled)
            ThresholdSlider(title: "充到此电量停止", value: $model.high, range: BatteryModel.highRange) {
                model.saveConfig()
            }
            .disabled(!model.enabled)

            FullChargeRow()

            Divider()

            SwitchRow(title: "登录时自动打开", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

            SwitchRow(title: "保持屏幕常亮", isOn: $model.keepDisplayOn)
            if model.keepDisplayOn {
                ThresholdSlider(title: "无操作多久后锁屏", value: $model.lockAfterMinutes,
                                range: BatteryModel.lockRange, unit: " 分钟") {}
            }

            SwitchRow(title: "到达上下限时通知", isOn: $model.notifyThresholds)

            if let notice = model.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let message = model.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            footer
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            model.loadConfig()
            model.refresh()
            model.checkDaemonVersion()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(model.percentText)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Label(model.title, systemImage: model.phaseSymbol)
                    .font(.headline)
                    .foregroundStyle(model.tint)
                Text(model.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if model.daemonOutdated && model.busy == nil {
                Text("App 已更新，后台服务还是旧版本，请更新一次")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !model.daemonInstalled || model.daemonOutdated || model.busy != nil {
                Button {
                    model.installDaemon()
                } label: {
                    HStack(spacing: 6) {
                        if model.busy != nil {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.busy ?? (model.daemonOutdated ? "更新后台服务" : "安装后台服务"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.busy != nil)
            }

            HStack {
                Circle()
                    .fill(model.daemonRunning ? Color.green : (model.daemonInstalled ? Color.red : Color.orange))
                    .frame(width: 6, height: 6)
                Text(model.daemonRunning ? "后台服务运行中" : (model.daemonInstalled ? "后台服务未运行" : "后台服务未安装"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("重新安装后台服务") { model.installDaemon() }
                        .disabled(model.busy != nil)
                    Button("卸载后台服务（恢复默认充电）") { model.uninstallDaemon() }
                        .disabled(model.busy != nil)
                    Divider()
                    Button("复制诊断信息") { model.copyDiagnostics() }
                    Divider()
                    Button("退出") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
    }
}

/// 电量条：浅色区域是循环区间，竖线标出上下限
struct LevelBar: View {
    let pct: Int
    let low: Int
    let high: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(.quaternary)
                    Rectangle()
                        .fill(tint.opacity(0.18))
                        .frame(width: w * CGFloat(high - low) / 100)
                        .offset(x: w * CGFloat(low) / 100)
                    Rectangle()
                        .fill(tint)
                        .frame(width: w * CGFloat(pct) / 100)
                    marker(at: low, width: w)
                    marker(at: high, width: w)
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)

            Text("循环区间 \(low)% – \(high)%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func marker(at value: Int, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.5))
            .frame(width: 2)
            .offset(x: width * CGFloat(value) / 100 - 1)
    }
}

/// 电池健康度和充电循环次数
struct HealthRow: View {
    let health: BatteryHealth

    var body: some View {
        HStack(spacing: 16) {
            Label("电池健康 \(health.percent)%", systemImage: "heart")
            Label("充电循环 \(health.cycles) 次", systemImage: "arrow.triangle.2.circlepath")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// 立即充满：点一次出现确认按钮，充满后服务自动回到循环
struct FullChargeRow: View {
    @EnvironmentObject var model: BatteryModel
    @State private var confirming = false

    var body: some View {
        Group {
            if model.fullChargeActive {
                Button("取消充满") { model.cancelFullCharge() }
                    .frame(maxWidth: .infinity)
            } else if confirming {
                VStack(alignment: .leading, spacing: 6) {
                    Text("充到 100% 后自动恢复 \(model.low)%–\(model.high)% 循环；12 小时内没充满会自动取消")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("取消") { confirming = false }
                        Spacer()
                        Button("确认充满") {
                            confirming = false
                            model.startFullCharge()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Button {
                    confirming = true
                } label: {
                    Label("立即充满电", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .disabled(!model.daemonRunning)
            }
        }
        .onDisappear { confirming = false }
    }
}

struct SwitchRow: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// 拖动时只更新数字，松手才保存，避免频繁写配置
struct ThresholdSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var unit = "%"
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)\(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: 5,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
        }
    }
}
