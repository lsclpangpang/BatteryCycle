import SwiftUI

struct MenuView: View {
    @EnvironmentObject var model: BatteryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            LevelBar(pct: model.pct ?? 0, low: model.low, high: model.high, tint: model.tint)

            Divider()

            SwitchRow(title: "启用充放电循环", isOn: Binding(
                get: { model.enabled },
                set: { model.enabled = $0; model.saveConfig() }
            ))
            ThresholdSlider(title: "低于此电量开始充电", value: $model.low, range: 5...40) {
                model.saveConfig()
            }
            .disabled(!model.enabled)
            ThresholdSlider(title: "充到此电量停止", value: $model.high, range: 50...100) {
                model.saveConfig()
            }
            .disabled(!model.enabled)

            Divider()

            SwitchRow(title: "登录时自动打开", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))

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
            if !model.daemonRunning {
                Button {
                    model.installDaemon()
                } label: {
                    Text("安装后台服务").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            HStack {
                Circle()
                    .fill(model.daemonRunning ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(model.daemonRunning ? "后台服务运行中" : "后台服务未运行")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("重新安装后台服务") { model.installDaemon() }
                    Button("卸载后台服务（恢复默认充电）") { model.uninstallDaemon() }
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
    let onCommit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)%")
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
