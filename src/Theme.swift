import SwiftUI

enum Theme {
    static let accent = Color(red: 0.96, green: 0.49, blue: 0.18)
    static let accentSoft = Color(red: 0.96, green: 0.49, blue: 0.18).opacity(0.18)
    static let success = Color(red: 0.30, green: 0.85, blue: 0.50)
    static let warn = Color(red: 0.99, green: 0.72, blue: 0.20)
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.36)

    static let cardBG = Color.white.opacity(0.04)
    static let cardStroke = Color.white.opacity(0.08)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.08)

    static func percentColor(_ p: Double) -> Color {
        if p >= 90 { return danger }
        if p >= 70 { return warn }
        return success
    }
}

// MARK: - 재사용 컴포넌트

struct Card<Content: View>: View {
    let title: String?
    let content: () -> Content
    init(_ title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let t = title {
                Text(t.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundColor(Theme.textSecondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.cardBG))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.cardStroke, lineWidth: 1))
    }
}

struct StatChip: View {
    let label: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Theme.textTertiary)
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ProgressBar: View {
    let percent: Double      // 0~100+
    let color: Color
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(colors: [color.opacity(0.85), color],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(2, geo.size.width * CGFloat(min(percent, 100)) / 100))
            }
        }
        .frame(height: height)
    }
}

struct KVRow: View {
    let label: String
    let value: String
    var valueColor: Color = Theme.textPrimary
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundColor(Theme.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(valueColor)
        }
    }
}

struct TokenBarRow: View {
    let label: String
    let value: Int
    let max: Int
    let color: Color
    var ratio: Double { max > 0 ? Double(value) / Double(max) * 100 : 0 }
    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            ProgressBar(percent: ratio, color: color, height: 6).frame(maxWidth: .infinity)
            Text(formatNum(value))
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 64, alignment: .trailing)
        }
    }
}
