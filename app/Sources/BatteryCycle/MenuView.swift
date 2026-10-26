import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: BatteryModel
    @EnvironmentObject var displays: DisplayController
    @EnvironmentObject var brightness: BrightnessController
    @State private var powerExpanded = false
    @State private var isVisible = false
    @State private var sizing = MenuSizing()
    @State private var powerFrame: CGRect = .zero

    var body: some View {
        ScrollView(.vertical) {
            content
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { geometry in
                    Color.clear
                        .onAppear { sizing.measureContent(geometry.size.height) }
                        .onChange(of: geometry.size.height) { sizing.measureContent($0) }
                })
        }
        .frame(width: 300, height: viewportHeight)
        .coordinateSpace(name: "menuViewport")
        .onPreferenceChange(PowerFlowFrame.self) { powerFrame = $0 }
        .onAppear {
            isVisible = true
            updateScreenHeight()
            model.loadConfig()
            model.refresh()
            model.refreshPorts()
            model.checkDaemonVersion()
            displays.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            if isVisible { updateScreenHeight(preferWindow: true) }
        }
        .onDisappear {
            isVisible = false
            powerExpanded = false
            powerFrame = .zero
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                powerFrame = .zero
                powerExpanded.toggle()
                model.refreshPorts()
            } label: {
                header
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(model.percentText)，\(model.title)，电力流向")
            .accessibilityValue(powerExpanded ? "已展开" : "已收起")
            .help("点击展开或收起电力流向")
            LevelBar(pct: model.pct ?? 0, low: model.low, high: model.high, tint: model.tint)
            if powerExpanded {
                PowerFlowView(telemetry: model.power, ports: model.ports, animationsEnabled: powerIsVisible)
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: PowerFlowFrame.self, value: geometry.frame(in: .named("menuViewport")))
                    })
            }
            // 只在放电阶段显示：这时它就是「从什么时候开始用电池」
            HardwareSummaryView(
                health: model.health,
                ports: model.ports,
                reachedText: model.phase == .discharge ? model.reachedText : nil
            )

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
                                range: BatteryModel.lockRange, step: 1, unit: " 分钟") {}
            }

            VStack(alignment: .leading, spacing: 6) {
                SwitchRow(title: "屏幕亮度降到最低", isOn: Binding(
                    get: { brightness.isEnabled },
                    set: { brightness.setEnabled($0) }
                ))
                .disabled(brightness.needsRecovery)
                Text(brightness.isEnabled
                     ? "自动亮度已暂停；直接按亮度加减键即可退出并调节"
                     : "仅调整内置屏幕；支持亮度按键直接调节")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if brightness.needsKeyboardPermission {
                    Button("允许亮度键调节") { brightness.requestKeyboardPermission() }
                        .font(.caption)
                    Text("首次使用需允许“输入监控”，仅用于识别亮度功能键")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let message = brightness.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if brightness.needsRecovery {
                    Button("重试恢复屏幕设置") { brightness.recover() }
                        .font(.caption)
                }
            }

            SwitchRow(title: "管理外接显示器", isOn: $displays.manageDisplays)
            if displays.manageDisplays {
                ExternalDisplayList()
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
    }

    private var powerIsVisible: Bool {
        PowerFlowAnimationVisibility.isVisible(menuVisible: isVisible, frame: powerFrame,
                                               viewportHeight: viewportHeight)
    }

    private var viewportHeight: CGFloat { sizing.viewportHeight }

    private func updateScreenHeight(preferWindow: Bool = false) {
        let screen = (preferWindow ? NSApp.keyWindow?.screen : nil)
            ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        if let screen { sizing.updateScreenHeight(screen.visibleFrame.height) }
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
            Spacer(minLength: 0)
            Image(systemName: powerExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
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

private struct PowerFlowFrame: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if PowerFlowAnimationVisibility.hasMeasurement(next) { value = next }
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

/// 每台外接显示器一个开关，关掉就断开（不再输出画面）
struct ExternalDisplayList: View {
    @EnvironmentObject var displays: DisplayController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if displays.displays.isEmpty {
                Text("没有检测到外接显示器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(displays.displays) { display in
                SwitchRow(title: display.name, isOn: Binding(
                    get: { display.enabled },
                    set: { displays.setEnabled(display, $0) }
                ))
            }
            if let message = displays.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.leading, 12)
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
                .accessibilityLabel(title)
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
    var step = 5
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
                step: Double(step),
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
        }
    }
}
