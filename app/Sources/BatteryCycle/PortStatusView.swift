import SwiftUI

/// 连接状态独立于电池充电状态；暂停充电不会让插口看起来被拔掉。
struct HardwareSummaryView: View {
    let health: BatteryHealth?
    let ports: [PortStatus]
    var reachedText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if health != nil || reachedText != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let health {
                        HealthRow(health: health)
                    }
                    if let reachedText {
                        Label(reachedText, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                Divider()
            }
            if ports.isEmpty {
                Text("插口状态暂不可用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: min(5, ports.count)),
                    spacing: 12
                ) {
                    ForEach(ports) { port in
                        PortStatusCell(port: port)
                            .padding(.vertical, 5)
                    }
                }
            }
        }
    }
}

private struct PortStatusCell: View {
    let port: PortStatus

    private var color: Color {
        port.connection == .connected ? .green : .secondary
    }

    var body: some View {
        VStack(spacing: 5) {
            PortGlyph(kind: port.kind)
                .foregroundStyle(color)
                .frame(width: 25, height: 14)
            // 保持原面板宽度；完整的位置和接口名称用两行展示，不缩成难读的小字。
            Text(port.label.replacingOccurrences(of: " USB-C", with: "\nUSB-C"))
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28)
            HStack(spacing: 3) {
                Circle()
                    .fill(color.opacity(port.connection == .connected ? 1 : 0.6))
                    .frame(width: 4, height: 4)
                Text(port.connection.title)
                    .font(.system(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(port.label)
        .accessibilityValue(port.connection.title)
        .help("\(port.label)：\(port.connection.title)\n表示插口是否连接，不代表正在供电或充电。")
    }
}

/// 使用原生矢量绘制，适配深色模式及 Retina 显示，不依赖系统版本新增的符号。
private struct PortGlyph: View {
    let kind: PortKind

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(x: 1, y: 2, width: size.width - 2, height: size.height - 4)
            var outline = Path()
            switch kind {
            case .usbC:
                outline.addRoundedRect(in: rect, cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
            case .magSafe:
                outline.addRoundedRect(in: rect, cornerSize: CGSize(width: 2.5, height: 2.5))
            case .hdmi:
                outline.move(to: CGPoint(x: rect.minX, y: rect.minY))
                outline.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                outline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - 3))
                outline.addLine(to: CGPoint(x: rect.maxX - 4, y: rect.maxY))
                outline.addLine(to: CGPoint(x: rect.minX + 4, y: rect.maxY))
                outline.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - 3))
                outline.closeSubpath()
            }
            context.stroke(outline, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            if kind == .magSafe {
                for index in 0..<5 {
                    let x = rect.minX + 4 + CGFloat(index) * (rect.width - 8) / 4
                    context.fill(Path(ellipseIn: CGRect(x: x - 1, y: rect.midY - 1, width: 2, height: 2)), with: .foreground)
                }
            } else {
                var contact = Path()
                contact.move(to: CGPoint(x: rect.minX + 5, y: rect.midY))
                contact.addLine(to: CGPoint(x: rect.maxX - 5, y: rect.midY))
                context.stroke(contact, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .accessibilityHidden(true)
    }
}
