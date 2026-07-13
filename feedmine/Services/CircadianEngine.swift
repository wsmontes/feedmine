import SwiftUI
import Observation

// MARK: - Period & Palette Types

enum CircadianPeriod: String, CaseIterable {
    case dawn, morning, afternoon, evening, night

    static func from(hour: Int) -> CircadianPeriod {
        switch hour {
        case 5..<8:  .dawn
        case 8..<12: .morning
        case 12..<17: .afternoon
        case 17..<21: .evening
        default:      .night
        }
    }

    var label: String {
        switch self {
        case .dawn:      String(localized: "Dawn", comment: "Circadian period")
        case .morning:   String(localized: "Morning", comment: "Circadian period")
        case .afternoon: String(localized: "Afternoon", comment: "Circadian period")
        case .evening:   String(localized: "Evening", comment: "Circadian period")
        case .night:     String(localized: "Night", comment: "Circadian period")
        }
    }

    var emoji: String {
        switch self {
        case .dawn:      "🌅"
        case .morning:   "☀️"
        case .afternoon: "🔆"
        case .evening:   "🌅"
        case .night:     "🌙"
        }
    }

    /// San Francisco weight varies subtly by period
    var fontWeight: Font.Weight {
        switch self {
        case .dawn:      .light
        case .morning:   .regular
        case .afternoon: .medium
        case .evening:   .regular
        case .night:     .light
        }
    }

    /// Subtle letter-spacing drift (in points)
    var letterSpacing: CGFloat {
        switch self {
        case .dawn:      0.3
        case .morning:   0
        case .afternoon: -0.1
        case .evening:   0.1
        case .night:     0.5
        }
    }

    /// Body line-height multiplier
    var lineHeight: CGFloat {
        switch self {
        case .dawn:      1.50
        case .morning:   1.45
        case .afternoon: 1.35
        case .evening:   1.50
        case .night:     1.55
        }
    }

    /// Card internal padding
    var cardPadding: CGFloat {
        switch self {
        case .dawn:      16
        case .morning:   14
        case .afternoon: 14
        case .evening:   18
        case .night:     22
        }
    }

    /// Gap between cards in LazyVStack
    var cardGap: CGFloat {
        switch self {
        case .dawn:      16
        case .morning:   12
        case .afternoon: 10
        case .evening:   14
        case .night:     18
        }
    }

    /// Card corner radius
    var cardRadius: CGFloat {
        switch self {
        case .dawn:      14
        case .morning:   14
        case .afternoon: 10
        case .evening:   14
        case .night:     16
        }
    }
}

enum PaletteFamily: String, CaseIterable {
    case warmEarth, coolSky, botanical, lavenderHour, monochrome

    var label: String {
        switch self {
        case .warmEarth:    String(localized: "Warm Earth", comment: "Palette family name")
        case .coolSky:      String(localized: "Cool Sky", comment: "Palette family name")
        case .botanical:    String(localized: "Botanical", comment: "Palette family name")
        case .lavenderHour: String(localized: "Lavender Hour", comment: "Palette family name")
        case .monochrome:   String(localized: "Monochrome", comment: "Palette family name")
        }
    }

    var subtitle: String {
        switch self {
        case .warmEarth:    String(localized: "Amber → Deep Coral · Brand", comment: "Palette family subtitle")
        case .coolSky:      String(localized: "Ice blue → Indigo", comment: "Palette family subtitle")
        case .botanical:    String(localized: "Moss → Pine", comment: "Palette family subtitle")
        case .lavenderHour: String(localized: "Lavender → Amethyst", comment: "Palette family subtitle")
        case .monochrome:   String(localized: "Warm gray · Subdued", comment: "Palette family subtitle")
        }
    }

    func accent(for period: CircadianPeriod) -> Color {
        switch (self, period) {
        case (.warmEarth, .dawn):      Color(hex: "#FFB238")  // brand Amber
        case (.warmEarth, .morning):   Color(hex: "#FF9A3C")  // amber→coral
        case (.warmEarth, .afternoon): Color(hex: "#FF7A45")  // brand Coral
        case (.warmEarth, .evening):   Color(hex: "#E8483C")  // brand Deep Coral
        case (.warmEarth, .night):     Color(hex: "#B8403A")  // deeper coral

        case (.coolSky, .dawn):      Color(hex: "#7BA4C4")
        case (.coolSky, .morning):   Color(hex: "#5B8FAD")
        case (.coolSky, .afternoon): Color(hex: "#4A7C9B")
        case (.coolSky, .evening):   Color(hex: "#3D5F80")
        case (.coolSky, .night):     Color(hex: "#2C3E5A")

        case (.botanical, .dawn):      Color(hex: "#7AAA7A")
        case (.botanical, .morning):   Color(hex: "#5E9465")
        case (.botanical, .afternoon): Color(hex: "#4A7A4A")
        case (.botanical, .evening):   Color(hex: "#3D5E3D")
        case (.botanical, .night):     Color(hex: "#2E4A2E")

        case (.lavenderHour, .dawn):      Color(hex: "#B8A4C8")
        case (.lavenderHour, .morning):   Color(hex: "#9B82B5")
        case (.lavenderHour, .afternoon): Color(hex: "#7E5F9E")
        case (.lavenderHour, .evening):   Color(hex: "#684C8A")
        case (.lavenderHour, .night):     Color(hex: "#4A3570")

        case (.monochrome, .dawn):      Color(hex: "#B0A89E")
        case (.monochrome, .morning):   Color(hex: "#9E9690")
        case (.monochrome, .afternoon): Color(hex: "#8C8580")
        case (.monochrome, .evening):   Color(hex: "#7A7370")
        case (.monochrome, .night):     Color(hex: "#686260")
        }
    }

    /// Subtle page background tint per period (over base #FAF8F5)
    func pageTint(for period: CircadianPeriod) -> Color {
        switch (self, period) {
        case (_, .dawn):      Color(hex: "#FAF8F5")
        case (_, .morning):   Color(hex: "#FAF8F5")
        case (_, .afternoon): Color(hex: "#F8F5F0")
        case (_, .evening):   Color(hex: "#F5F0E8")
        case (_, .night):     Color(hex: "#F0EBE4")
        }
    }
}

enum FontStyle: String, CaseIterable {
    case system, newYork, sfMono, georgia

    var label: String {
        switch self {
        case .system:  String(localized: "System", comment: "Font style name")
        case .newYork: String(localized: "New York", comment: "Font style name")
        case .sfMono:  String(localized: "SF Mono", comment: "Font style name")
        case .georgia: String(localized: "Georgia", comment: "Font style name")
        }
    }
}

// MARK: - CircadianEngine Singleton

@MainActor
@Observable
final class CircadianEngine {
    static let shared = CircadianEngine()

    var isCircadianOn: Bool {
        didSet { UserDefaults.standard.set(isCircadianOn, forKey: "circadianPaletteOn") }
    }
    var paletteFamilyRaw: String {
        didSet { UserDefaults.standard.set(paletteFamilyRaw, forKey: "paletteFamily") }
    }
    var isCircadianTypographyOn: Bool {
        didSet { UserDefaults.standard.set(isCircadianTypographyOn, forKey: "circadianTypographyOn") }
    }
    var fontStyleRaw: String {
        didSet { UserDefaults.standard.set(fontStyleRaw, forKey: "fontStyle") }
    }

    private(set) var period: CircadianPeriod = .morning
    private var lastHour: Int = -1

    private init() {
        let d = UserDefaults.standard
        if d.object(forKey: "circadianPaletteOn") == nil { d.set(true, forKey: "circadianPaletteOn") }
        if d.object(forKey: "circadianTypographyOn") == nil { d.set(true, forKey: "circadianTypographyOn") }
        isCircadianOn = d.bool(forKey: "circadianPaletteOn")
        paletteFamilyRaw = d.string(forKey: "paletteFamily") ?? PaletteFamily.warmEarth.rawValue
        isCircadianTypographyOn = d.bool(forKey: "circadianTypographyOn")
        fontStyleRaw = d.string(forKey: "fontStyle") ?? FontStyle.system.rawValue
        refresh()
    }

    var paletteFamily: PaletteFamily {
        PaletteFamily(rawValue: paletteFamilyRaw) ?? .warmEarth
    }

    var fontStyle: FontStyle {
        FontStyle(rawValue: fontStyleRaw) ?? .system
    }

    /// The currently active accent color
    var accent: Color {
        guard isCircadianOn else { return paletteFamily.accent(for: .morning) }
        return paletteFamily.accent(for: period)
    }

    /// Page background color
    var pageBackground: Color {
        guard isCircadianOn else { return Color(hex: "#FAF8F5") }
        return paletteFamily.pageTint(for: period)
    }

    /// Active font weight (nil = don't override, use system default)
    var activeFontWeight: Font.Weight? {
        guard isCircadianTypographyOn else { return nil }
        return period.fontWeight
    }

    /// Active letter spacing (0 = default)
    var activeLetterSpacing: CGFloat {
        guard isCircadianTypographyOn else { return 0 }
        return period.letterSpacing
    }

    // Convenience pass-throughs for current period
    var cardPadding: CGFloat { period.cardPadding }
    var cardGap: CGFloat { period.cardGap }
    var cardRadius: CGFloat { period.cardRadius }
    var bodyLineHeight: CGFloat { period.lineHeight }

    private var transitionTask: Task<Void, Never>?

    /// Re-evaluate period from system clock and schedule a re-refresh at the next hour boundary.
    func refresh() {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour != lastHour else { return }
        lastHour = hour
        let newPeriod = CircadianPeriod.from(hour: hour)
        if newPeriod != period {
            withAnimation(.easeInOut(duration: 2.0)) {
                period = newPeriod
            }
        }

        // Schedule re-refresh at next hour boundary
        transitionTask?.cancel()
        let now = Date()
        let calendar = Calendar.current
        if let nextHour = calendar.nextDate(after: now, matching: DateComponents(minute: 0, second: 0), matchingPolicy: .nextTime) {
            let delay = nextHour.timeIntervalSince(now)
            transitionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    // MARK: - Font Factory

    /// Returns a Font for the given role, respecting the selected font style and circadian weight.
    func font(for role: FontRole, size: CGFloat? = nil) -> Font {
        let baseSize = size ?? role.defaultSize
        let weight = isCircadianTypographyOn ? period.fontWeight : role.defaultWeight
        switch fontStyle {
        case .system:
            return .system(size: baseSize, weight: weight)
        case .newYork:
            return .custom("New York", size: baseSize).weight(weight)
        case .sfMono:
            return .system(size: baseSize, weight: weight, design: .monospaced)
        case .georgia:
            // Georgia for headlines/articles, SF for body
            if role == .cardTitle || role == .articleHeadline || role == .sectionHeader || role == .momentCard {
                return .custom("Georgia", size: baseSize).weight(weight)
            }
            return .system(size: baseSize, weight: weight)
        }
    }

    /// Returns the HIG-recommended tracking (letter-spacing) for a given font size.
    func tracking(for size: CGFloat) -> CGFloat {
        switch size {
        case 34...:   return -1.05  // Large Title
        case 28..<34: return -0.80  // Title 1
        case 22..<28: return -0.50  // Title 2
        case 20..<22: return -0.45  // Title 3
        case 17..<20: return -0.43  // Headline / Body
        case 15..<17: return -0.24  // Subhead
        case 13..<15: return -0.08  // Footnote
        case ..<13:    return +0.12  // Caption (positive tracking for legibility)
        default:       return 0
        }
    }
}

enum FontRole {
    case momentCard, sectionHeader, cardTitle, articleHeadline, cardBody, cardMeta, uiLabel

    var defaultSize: CGFloat {
        switch self {
        case .momentCard:      14
        case .sectionHeader:   13
        case .cardTitle:       17
        case .articleHeadline: 19
        case .cardBody:        14
        case .cardMeta:        11
        case .uiLabel:         14
        }
    }

    var defaultWeight: Font.Weight {
        switch self {
        case .momentCard:       .regular
        case .sectionHeader:    .semibold
        case .cardTitle:        .semibold
        case .articleHeadline:  .bold
        case .cardBody:         .regular
        case .cardMeta:         .regular
        case .uiLabel:          .medium
        }
    }
}
