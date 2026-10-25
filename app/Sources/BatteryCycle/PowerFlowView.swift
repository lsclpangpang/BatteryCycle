import AppKit
import SwiftUI

enum PowerFlowRoute: Hashable { case direct, charge, discharge }

enum PowerFlowAnimationVisibility {
    static func hasMeasurement(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
        frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0
    }

    static func isVisible(menuVisible: Bool, frame: CGRect, viewportHeight: CGFloat) -> Bool {
        guard menuVisible else { return false }
        // MenuBarExtra can leave the frame preference at its default value.
        // Missing geometry is not evidence that an expanded view is offscreen.
        guard hasMeasurement(frame) else { return true }
        return frame.intersects(CGRect(x: 0, y: 0, width: 300, height: viewportHeight))
    }
}

/// Presentation uses observed supply state, never the cycle target or battery percentage.
struct PowerFlowPresentation {
    let telemetry: PowerTelemetry
    let ports: [PortStatus]

    var routes: Set<PowerFlowRoute> {
        switch telemetry.source {
        case .charging: return [.direct, .charge]
        case .external: return [.direct]
        case .battery: return [.discharge]
        case .hybrid: return [.direct, .discharge]
        case .unknown: return []
        }
    }

    var showsBypass: Bool { routes.contains(.direct) }
    var stateTitle: String {
        switch telemetry.source {
        case .charging: return "充电中"
        case .external: return "外接供电"
        case .battery: return "电池供电"
        case .hybrid: return "共同供电"
        case .unknown: return "状态待确认"
        }
    }
    var chargerText: String {
        if telemetry.source == .battery {
            let powerPorts = ports.filter { $0.kind == .usbC || $0.kind == .magSafe }
            if !powerPorts.isEmpty && powerPorts.allSatisfy({ $0.connection == .disconnected }) {
                return "未连接"
            }
            // A connected USB peripheral is not evidence of a connected charger.
            return "未使用外接"
        }
        guard let watts = telemetry.inputWatts else { return "暂不可用" }
        return "输入" + Self.watts(watts)
    }
    var batteryText: String {
        switch telemetry.source {
        case .external: return "待命"
        case .unknown: return "暂不可用"
        case .charging:
            guard let watts = telemetry.batteryWatts, watts > 0 else { return "充电中" }
            return "充入" + Self.watts(watts)
        case .battery, .hybrid:
            guard let watts = telemetry.batteryWatts, watts < 0 else { return "暂不可用" }
            return "输出" + Self.watts(-watts)
        }
    }
    var computerText: String {
        switch telemetry.source {
        case .charging, .external: return "外接供电"
        case .battery: return "电池供电"
        case .hybrid: return "共同供电"
        case .unknown: return "待确认"
        }
    }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "暂不可用" }
        if value == 0 { return "0 W" }
        // Do not round a small positive reading to a misleading zero.
        if value < 0.1 { return "小于 0.1 W" }
        let digits = value < 100 ? 1 : 0
        return "约 \(value.formatted(.number.precision(.fractionLength(0...digits)))) W"
    }
}

struct PowerFlowView: View {
    let telemetry: PowerTelemetry
    let ports: [PortStatus]
    var animationsEnabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false
    @State private var awake = true

    private var presentation: PowerFlowPresentation {
        PowerFlowPresentation(telemetry: telemetry, ports: ports)
    }
    private var animate: Bool {
        animationsEnabled && visible && awake && !reduceMotion && !presentation.routes.isEmpty
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("电力流向").fontWeight(.medium)
                Spacer()
                Text(presentation.stateTitle).foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            if animate {
                TimelineView(.animation(minimumInterval: 1.0 / 24)) { timeline in
                    diagram(at: timeline.date.timeIntervalSinceReferenceDate)
                }
            } else {
                diagram(at: nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("电力流向，\(presentation.stateTitle)")
        .accessibilityValue("充电器：\(presentation.chargerText)；电池：\(presentation.batteryText)；电脑：\(presentation.computerText)")
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in awake = false }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in awake = true }
    }

    private func diagram(at time: TimeInterval?) -> some View {
        let bypass = presentation.showsBypass
        let inset: CGFloat = bypass ? 30 : 0
        return GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                FlowRoutes(routes: presentation.routes, time: time, nodeY: inset + 14)
                HStack(alignment: .top, spacing: 0) {
                    node(symbol: "powerplug", title: "充电器", metric: presentation.chargerText,
                         active: bypass)
                    node(symbol: "battery.100", title: "电池", metric: presentation.batteryText,
                         active: presentation.routes.contains(.charge) || presentation.routes.contains(.discharge))
                    node(symbol: "laptopcomputer", title: "电脑", metric: presentation.computerText,
                         active: !presentation.routes.isEmpty)
                }
                .frame(width: geometry.size.width)
                .offset(y: inset)
            }
        }
        .frame(height: 70 + inset)
    }

    private func node(symbol: String, title: String, metric: String, active: Bool) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(active ? Color.green : .secondary)
                .frame(height: 28)
            Text(title).font(.system(size: 11))
            Text(metric)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FlowRoutes: View {
    let routes: Set<PowerFlowRoute>
    let time: TimeInterval?
    let nodeY: CGFloat

    var body: some View {
        Canvas { context, size in
            let left = size.width / 6, middle = size.width / 2, right = size.width * 5 / 6
            for route in [PowerFlowRoute.direct, .charge, .discharge] where routes.contains(route) {
                var path = Path()
                let end: CGPoint
                let arrowDown: Bool
                let length: CGFloat
                switch route {
                case .direct:
                    path.move(to: CGPoint(x: left, y: nodeY - 19))
                    path.addLine(to: CGPoint(x: left, y: 12))
                    path.addQuadCurve(to: CGPoint(x: left + 6, y: 6), control: CGPoint(x: left, y: 6))
                    path.addLine(to: CGPoint(x: right - 6, y: 6))
                    path.addQuadCurve(to: CGPoint(x: right, y: 12), control: CGPoint(x: right, y: 6))
                    end = CGPoint(x: right, y: nodeY - 19)
                    path.addLine(to: end)
                    arrowDown = true
                    length = right - left + 2 * (nodeY - 25)
                case .charge:
                    path.move(to: CGPoint(x: left + 20, y: nodeY))
                    end = CGPoint(x: middle - 23, y: nodeY)
                    path.addLine(to: end)
                    arrowDown = false
                    length = end.x - left - 20
                case .discharge:
                    path.move(to: CGPoint(x: middle + 23, y: nodeY))
                    end = CGPoint(x: right - 24, y: nodeY)
                    path.addLine(to: end)
                    arrowDown = false
                    length = end.x - middle - 23
                }
                context.stroke(path, with: .color(.green.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                var arrow = Path()
                arrow.move(to: CGPoint(x: end.x - 3, y: end.y - (arrowDown ? 4 : 3)))
                if !arrowDown { arrow = Path(); arrow.move(to: CGPoint(x: end.x - 4, y: end.y - 3)) }
                arrow.addLine(to: end)
                arrow.addLine(to: CGPoint(x: end.x + (arrowDown ? 3 : -4), y: end.y + (arrowDown ? -4 : 3)))
                context.stroke(arrow, with: .color(.green), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))

                if let time, length > 0 {
                    // Constant speed expresses direction, not measured wattage.
                    let offset = CGFloat(time.truncatingRemainder(dividingBy: 1.2) / 1.2) * 22
                    for distance in stride(from: offset, to: length, by: 22) {
                        let fraction = max(0.001, min(0.999, distance / length))
                        if let point = path.trimmedPath(from: 0, to: fraction).currentPoint {
                            context.fill(Path(ellipseIn: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)), with: .color(.green))
                        }
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}
