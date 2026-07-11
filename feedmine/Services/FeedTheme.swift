import SwiftUI

/// Resolves the two color values that differ per feed — accent and page background.
/// Everything else (fonts, card geometry, period) still comes from CircadianEngine.shared,
/// because typography/layout are global, only color is per-feed.
struct FeedTheme {
    /// nil = main feed → mirror CircadianEngine.shared exactly (adaptive).
    /// non-nil = secondary feed → fixed family, still period-aware for legibility.
    let family: PaletteFamily?

    @MainActor var accent: Color {
        let engine = CircadianEngine.shared
        guard let family else { return engine.accent }
        return engine.isCircadianOn ? family.accent(for: engine.period) : family.accent(for: .morning)
    }

    @MainActor var pageBackground: Color {
        let engine = CircadianEngine.shared
        guard let family else { return engine.pageBackground }
        return engine.isCircadianOn ? family.pageTint(for: engine.period) : Color(hex: "#FAF8F5")
    }
}

private struct FeedThemeKey: EnvironmentKey {
    static let defaultValue = FeedTheme(family: nil)  // main / adaptive
}

extension EnvironmentValues {
    var feedTheme: FeedTheme {
        get { self[FeedThemeKey.self] }
        set { self[FeedThemeKey.self] = newValue }
    }
}

private struct FeedNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var feedName: String? {
        get { self[FeedNameKey.self] }
        set { self[FeedNameKey.self] = newValue }
    }
}
