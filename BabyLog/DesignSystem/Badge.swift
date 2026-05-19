import SwiftUI

/// Small pill badge with icon + label, tinted by a theme color.
struct Badge: View {
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// Large prominent daily-total card used at the top of history lists.
struct DailyTotalCard<Trailing: View>: View {
    let title: String
    let primary: String
    let secondary: String?
    var accent: Color = .accentColor
    var accentIcon: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let accentIcon {
                ZStack {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Image(systemName: accentIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                }
                .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text(primary)
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let secondary {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(accent.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

extension DailyTotalCard where Trailing == EmptyView {
    init(
        title: String,
        primary: String,
        secondary: String? = nil,
        accent: Color = .accentColor,
        accentIcon: String? = nil
    ) {
        self.init(
            title: title,
            primary: primary,
            secondary: secondary,
            accent: accent,
            accentIcon: accentIcon,
            trailing: { EmptyView() }
        )
    }
}
