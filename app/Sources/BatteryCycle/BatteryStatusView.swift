import SwiftUI

struct BatteryStatusHeader: View {
    let pct: Int?
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    var showDisclosure = true
    var expanded = false

    var body: some View {
        HStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(pct.map(String.init) ?? "—")
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                if pct != nil {
                    Text("%")
                        .font(.system(size: 18, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
                    .fixedSize(horizontal: false, vertical: true)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if showDisclosure {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Color.primary.opacity(0.04), in: Circle())
            }
        }
    }
}

/// 关闭循环时只显示实际电量；开启后再显示循环区间和上下限。
struct LevelBar: View {
    let pct: Int?
    let low: Int
    let high: Int
    let tint: Color
    let showsCycleRange: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.primary.opacity(0.08))
                    if showsCycleRange {
                        Rectangle()
                            .fill(tint.opacity(0.18))
                            .frame(width: w * CGFloat(high - low) / 100)
                            .offset(x: w * CGFloat(low) / 100)
                    }
                    Rectangle()
                        .fill(tint)
                        .frame(width: w * CGFloat(min(max(pct ?? 0, 0), 100)) / 100)
                    if showsCycleRange {
                        marker(at: low, width: w)
                        marker(at: high, width: w)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: showsCycleRange ? 8 : 6)

            if showsCycleRange {
                Text("循环区间 \(low)% – \(high)%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func marker(at value: Int, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.5))
            .frame(width: 2)
            .offset(x: width * CGFloat(value) / 100 - 1)
    }
}
