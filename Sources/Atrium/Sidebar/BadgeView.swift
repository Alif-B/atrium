import SwiftUI
import AtriumCore

struct BadgeView: View {
    let badge: BadgeText

    var body: some View {
        switch badge {
        case .dot:
            Circle()
                .fill(Color(nsColor: .systemRed))
                .frame(width: DesignTokens.dotBadgeSize, height: DesignTokens.dotBadgeSize)
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
        case .count, .text:
            Text(badge.display)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 4.5)
                .frame(minWidth: DesignTokens.badgeHeight, minHeight: DesignTokens.badgeHeight)
                .background(Capsule().fill(Color(nsColor: .systemRed)))
                .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
                .contentTransition(.numericText())
                .animation(Motion.badgeCount, value: badge)
        }
    }
}
