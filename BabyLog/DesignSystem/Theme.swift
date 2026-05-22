import SwiftUI

/// Design tokens for BabyLog. A warm, soft palette that reads well in both
/// light and dark mode and gives each feature a distinct identity.
enum Theme {

    // MARK: - Per-domain accent colors

    static let feed: Color        = Color(red: 0.2379, green: 0.6145, blue: 0.8088)
    static let pumping: Color     = Color(red: 0.8810, green: 0.5297, blue: 0.5580)
    static let growth: Color      = Color(red: 0.2619, green: 0.6634, blue: 0.4321)
    static let milestone: Color   = Color(red: 0.8891, green: 0.6798, blue: 0.2932)
    static let medical: Color     = Color(red: 0.5981, green: 0.4395, blue: 0.7705)
    static let assistant: Color   = Color(red: 0.5932, green: 0.5550, blue: 0.8232)
    static let diaper: Color      = Color(red: 0.2379, green: 0.6145, blue: 0.8088)
    static let appointment: Color = Color(red: 0.5981, green: 0.4395, blue: 0.7705)
    static let settings: Color    = Color(red: 0.55, green: 0.56, blue: 0.62)

    // MARK: - Spacing & radii

    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 18
    }

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
    }
}

/// Warm empty-state panel with a large tinted icon. Keeps the exact title
/// strings UI tests look for (`No Feeds Yet`, `No Diaper Changes Yet`, etc.)
/// as a plain `staticText` so XCUI queries remain stable.
struct WarmEmptyState: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, Theme.Space.xl)
    }
}

#Preview("Warm empty state") {
    WarmEmptyState(
        title: "No Feeds Yet",
        message: "Log a feed above to get started.",
        systemImage: "cup.and.heat.waves",
        tint: Theme.feed
    )
}
