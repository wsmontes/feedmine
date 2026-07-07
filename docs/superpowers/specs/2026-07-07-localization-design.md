# Localization Design — FeedMine

**Date:** 2026-07-07
**Status:** Approved
**Approach:** String Catalogs + AppleLanguages Override (Approach 1)

## 1. Overview

Add full internationalization (i18n) to FeedMine using Apple's standard localization stack: **String Catalogs** (`.xcstrings`), `String(localized:)`, and `Locale` APIs. The app auto-detects the system language on first launch and offers an in-app language picker in Settings. Changing the language requires a manual app restart (standard iOS pattern for apps that allow a language different from the system).

### Supported Languages

All ~40 languages that iOS natively supports:

| Code | Language | Code | Language |
|---|---|---|---|
| `ar` | العربية | `it` | Italiano |
| `ca` | Català | `ja` | 日本語 |
| `zh-Hans` | 简体中文 | `ko` | 한국어 |
| `zh-Hant` | 繁體中文 | `ms` | Melayu |
| `hr` | Hrvatski | `nb` | Norsk Bokmål |
| `cs` | Čeština | `pl` | Polski |
| `da` | Dansk | `pt-BR` | Português (Brasil) |
| `nl` | Nederlands | `pt-PT` | Português (Portugal) |
| `en` | English (source) | `ro` | Română |
| `en-GB` | English (UK) | `ru` | Русский |
| `fi` | Suomi | `sk` | Slovenčina |
| `fr` | Français | `es` | Español |
| `fr-CA` | Français (Canada) | `es-419` | Español (Latinoamérica) |
| `de` | Deutsch | `sv` | Svenska |
| `el` | Ελληνικά | `th` | ไทย |
| `he` | עברית | `tr` | Türkçe |
| `hi` | हिन्दी | `uk` | Українська |
| `hu` | Magyar | `vi` | Tiếng Việt |
| `id` | Indonesia | | |

English (`en`) is the source/development language. All others receive translated strings.

## 2. Architecture

### 2.1 New File: `Services/LocaleManager.swift`

A `@Observable` singleton that manages language selection state. Injected into the SwiftUI environment at app launch.

```swift
@Observable
final class LocaleManager {
    static let shared = LocaleManager()

    let supportedLanguages: [Language]  // all ~40 entries
    var selectedLanguage: Language      // current effective language

    func onAppLaunch()                  // resolve language: UserDefaults > system prefs > en fallback
    func selectLanguage(_ language: Language)  // save to AppleLanguages, trigger restart alert

    private static func resolveLanguage() -> Language { /* chain */ }
}
```

### 2.2 Data Type: `Language`

```swift
struct Language: Identifiable, Equatable {
    let code: String            // BCP-47: "en", "pt-BR", "zh-Hans"
    let displayName: String     // Native name: "English", "Português (Brasil)", "简体中文"
    var id: String { code }
}
```

### 2.3 Language Resolution Flow

```
App Launch
  └─ LocaleManager.resolveLanguage()
       ├─ 1. UserDefaults "AppleLanguages" first element matches supportedLanguage?
       │      └─ YES → use it
       ├─ 2. Iterate Locale.preferredLanguages, match against supportedLanguages
       │      └─ Match → use it
       └─ 3. Fallback: English (en)
```

### 2.4 Injection Point

`feedmineApp.swift` — no changes needed beyond adding `.environment(localeManager)` if views consume it. The `AppleLanguages` key in `UserDefaults` drives everything at the Bundle level; views don't need to consult `LocaleManager` for string lookup.

```swift
@main
struct FeedmineApp: App {
    @State private var localeManager = LocaleManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(localeManager)
        }
    }
}
```

## 3. String Catalog

### 3.1 File: `feedmine/Resources/Localizable.xcstrings`

Created in Xcode: `File > New > File > String Catalog`. Initial source language: English. All ~40 languages added as targets.

The compiler automatically extracts:
- SwiftUI `Text("...")`, `Label("...")`, `Button("...")`, `Toggle("...")`, `TextField("...")`
- `String(localized:comment:)` calls
- `LocalizedStringKey` usage

### 3.2 Extraction Strategy

| Pattern | Action |
|---|---|
| `Text("Settings")` | **No change.** Xcode extracts automatically. |
| `Text("\(count) articles read")` | Wrap with inflection: `Text("^[\(count) article](inflect: true) read")` |
| `Button("Done")` | **No change.** |
| `Toggle("Adaptive Palette", ...)` | **No change.** |
| `.navigationTitle("Settings")` | **No change.** |
| `String(localized: "Morning", comment: "Time of day")` | Use in enum computed properties |
| Alert titles / confirmation dialogs | **No change.** |

### 3.3 Build Settings (project.yml)

```yaml
settings:
  SWIFT_EMIT_LOC_STRINGS: "YES"        # already default in Xcode 16
  DEVELOPMENT_TEAM: "955573A4YH"
```

No additional build settings required. String Catalog is automatically bundled.

## 4. Enum Localization

All enums with user-facing strings replace rawValue usage with a `label` computed property backed by `String(localized:)`.

### 4.1 `AppContext.swift` — Time/Weather/Session Enums

Each of these enums gets a `label` property:

- `TimeOfDay` — "Night", "Dawn", "Morning", "Afternoon", "Evening", "Late Night"
- `Season` — "Spring", "Summer", "Autumn", "Winter"
- `WeatherCondition` — "Clear", "Partly Cloudy", "Rain", "Thunderstorm", "Snow", etc.
- `TemperatureFeel` — "Cold", "Cool", "Mild", "Warm", "Hot", "Scorching"
- `MoonPhase` — "New", "Waxing Crescent", "Full", etc.
- `Weekday` — "Sunday" through "Saturday"
- `Month` — "January" through "December"
- `SpecialDate` — "New Year's Day", "Christmas", "Halloween", etc.
- `Holiday` — "Today", "Tomorrow", "This Week"
- `SessionLevel` — "Just Opened", "Settling In", "Engaged", etc.
- `SessionStreak` — "First Time", "New Streak"
- `RoutineMatch` — "Exact", "Approximate", etc.
- `ReadingPace` — "Skimming", "Steady", "Deep"
- `BatteryState` — "Charging", "Full", "Low", etc.
- `Connectivity` — "Wi‑Fi", "Cellular", "Offline"

### 4.2 `CircadianEngine.swift` — UI Enums

- `CircadianPeriod.label` — already exists, but uses hardcoded English. Replace with `String(localized:)`.
- `PaletteFamily.label` / `.subtitle` — replace with `String(localized:)`.
- `FontStyle.label` — replace with `String(localized:)`.

### 4.3 `MomentGreeting.swift` — Dynamic Greetings

**Strategy:** The greeting system uses ~200+ English templates and slot fillers. Rather than translating every template combination (which would be explosive), we localize the **slot fillers** and keep the **template structure** language-neutral.

- Slot functions (`greetingSlot`, `weekdaySlot`, `seasonSlot`, etc.) return `String(localized:)` values
- Templates remain as `[slot]` markers — the filled result is a localized sentence
- This works because all ~40 languages share the same slot-insertion grammar

Example transformation for `greetingSlot`:
```swift
// Before
case .morning: greetings = ["Good morning", "Morning", "Rise and read", ...]

// After — each variant is a separate String(localized:) call
case .morning: greetings = [
    String(localized: "Good morning", comment: "Morning greeting variant"),
    String(localized: "Morning", comment: "Morning greeting variant"),
    String(localized: "Rise and read", comment: "Morning greeting variant"),
    ...
]
```

This preserves the variety/randomization per language while keeping translations manageable.

## 5. Country Name Localization

`CountryStore.countryName(for:)` replaces the static English-only dictionary with `Locale.localizedString(forRegionCode:)`.

### 5.1 Slug → Region Code Mapping

Add a lookup dictionary:

```swift
private static let slugToRegionCode: [String: String] = [
    "brazil": "BR", "germany": "DE", "france": "FR",
    "japan": "JP", "south-korea": "KR", "united-kingdom": "GB",
    // ... all ~100 country slugs mapped to ISO 3166-1 alpha-2 codes
]
```

### 5.2 New Implementation

```swift
static func countryName(for slug: String) -> String {
    if let code = slugToRegionCode[slug],
       let localized = Locale.localizedString(forRegionCode: code) {
        return localized
    }
    // Fallback for slugs without region codes or unrecognized codes
    return slug.capitalized.replacingOccurrences(of: "-", with: " ")
}
```

### 5.3 Benefits

- Country names automatically in all ~40 languages
- Zero manual translation maintenance
- Correct localized names (e.g., "Alemanha" in PT, "Deutschland" in DE, "ドイツ" in JA)
- Flags remain emoji-based (unchanged)

## 6. Settings UI — Language Picker

### 6.1 Location

New `Section("Language")` in `SettingsSheetView.swift`, placed between "Appearance" and "Circadian Design".

### 6.2 Main Row

Displays current language with native name. Tapping pushes a language selection list.

```swift
Section {
    NavigationLink {
        languagePickerView
    } label: {
        HStack {
            Text("Language")
            Spacer()
            Text(localeManager.selectedLanguage.displayName)
                .foregroundStyle(.secondary)
        }
    }
} header: {
    Text("Language")
} footer: {
    Text("Changing the language requires restarting the app.")
}
```

### 6.3 Selection Screen

A searchable `List` of all ~40 languages, each showing native name + code. Current selection marked with checkmark. Selecting a new language sets `AppleLanguages` and shows a restart alert.

```swift
private var languagePickerView: some View {
    List {
        ForEach(localeManager.supportedLanguages) { language in
            Button {
                if language.code != localeManager.selectedLanguage.code {
                    localeManager.selectLanguage(language)
                    showRestartAlert = true
                }
            } label: {
                HStack {
                    Text(language.displayName)
                    Spacer()
                    Text(language.code)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if language.code == localeManager.selectedLanguage.code {
                        Image(systemName: "checkmark")
                            .foregroundStyle(CircadianEngine.shared.accent)
                    }
                }
            }
        }
    }
    .navigationTitle(String(localized: "Language", comment: "Language picker title"))
    .alert(String(localized: "Restart Required", comment: "Alert title"),
           isPresented: $showRestartAlert) {
        Button(String(localized: "OK", comment: "Dismiss alert")) { }
    } message: {
        Text("Please restart FeedMine to apply the new language.")
    }
}
```

## 7. Right-to-Left (RTL) Support

SwiftUI automatically mirrors layouts for RTL languages (Arabic, Hebrew). The app's use of `HStack`, `Spacer()`, and semantic layout means **no code changes are required** for RTL.

### 7.1 Verification Items

- `NavigationLink` chevrons automatically flip → ✅
- `HStack` ordering reverses → ✅
- Emoji (flags, symbols) are neutral — do NOT flip → ✅
- `Image(systemName:)` icons are directional and DO flip correctly → ✅

### 7.2 Pseudo-localization Testing

Test with Arabic pseudo-locale in Xcode scheme settings to catch any hardcoded `.leading`/`.trailing` assumptions (none found in current codebase).

## 8. Pluralization

String Catalog handles plural rules natively. Strings with counts use the `^[` inflection syntax:

```swift
// Before
Text("\(loader.readItemIDs.count) articles read")

// After — compiler extracts plural variants into .xcstrings
Text("^[\(loader.readItemIDs.count) article](inflect: true) read")
```

The `.xcstrings` editor provides a visual UI to fill in each language's plural forms:
- English: "1 article" / "2 articles"
- Arabic: 6 forms (zero, one, two, few, many, other)
- Russian: 4 forms (one, few, many, other)
- Chinese: 1 form (no plural distinction)

## 9. Date, Number & Measurement Formatting

No changes required. The app already uses locale-aware formatting:

```swift
Text(date, style: .relative)   // "2 hours ago" → auto-localized
Text(date, style: .date)       // locale-aware date format
```

`Locale.current` respects the `AppleLanguages` setting, so these APIs produce correctly localized output automatically.

## 10. Files Changed (Summary)

| File | Change Type | Description |
|---|---|---|
| `Resources/Localizable.xcstrings` | **NEW** | String Catalog with all ~40 languages |
| `Services/LocaleManager.swift` | **NEW** | Language selection & resolution service |
| `feedmineApp.swift` | Minor | Inject `LocaleManager` into environment |
| `Services/AppContext.swift` | Moderate | Add `label` computed properties to ~15 enums |
| `Services/CircadianEngine.swift` | Minor | Replace hardcoded enum labels with `String(localized:)` |
| `Services/MomentGreeting.swift` | Major | Convert all greeting/count/pace/etc. slot strings to `String(localized:)` |
| `Models/Country.swift` | Moderate | Replace static `metadata` dict → `Locale.localizedString(forRegionCode:)` + slug→regionCode mapping |
| `Views/SettingsSheetView.swift` | Moderate | Add language section + picker sheet |
| `Views/*.swift` (~15 files) | Minimal | Fix interpolation strings for pluralization (~5-10 spots); all `Text("...")` remain unchanged |
| `project.yml` | Minor | No required changes (defaults already correct) |

## 11. Testing Strategy

### 11.1 Pseudo-localization
- Run app with pseudo-localization via Xcode Scheme (Product > Scheme > Edit Scheme > Run > Options > App Language)
- Verify: no truncated labels, all UI elements respond to longer strings
- Verify: RTL layout works with Arabic pseudo-locale

### 11.2 Manual Testing
- Switch language to Portuguese, restart, verify main screens
- Switch to Arabic, restart, verify RTL layout and text
- Switch to a language not in system prefs (e.g., system = German, app = Japanese) → restart → verify Japanese is used

### 11.3 Automated
- Future: snapshot tests with different locales
- Verify that `LocaleManager.resolveLanguage()` correctly follows the chain for edge cases (empty UserDefaults, unsupported system language, etc.)

## 12. Rollout Phases

### Phase 1 — Infrastructure (this PR)
- `LocaleManager` service
- `Localizable.xcstrings` created with English source
- All ~40 languages registered in the catalog
- Language picker in Settings
- Enum `label` properties with `String(localized:)`
- Country name via `Locale.localizedString(forRegionCode:)`
- Greeting slot strings via `String(localized:)`

### Phase 2 — Translation
- Populate translations for **Portuguese (pt-BR)** — the developer's language
- Populate translations for **Spanish (es)** — second priority

### Phase 3 — Community / Professional Translation
- Remaining ~37 languages translated over time
- Could use XLIFF export → professional translation service → import
- English remains the fallback for any untranslated string (automatic behavior of `.xcstrings`)
