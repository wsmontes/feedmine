# Country Feeds — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Integrate 97 country OPML files as a dynamic, data-driven Countries section with per-country and per-feed toggles.

**Architecture:** Add a `region` field to `FeedSource` tagged by OPMLParser from the file path. Add `disabledRegions: Set<String>` to FeedLoader/FeedState for bulk country toggles. Build two new SwiftUI screens (CountriesListScreen, CountryDetailScreen) that read from the loader's computed `availableCountries`.

**Tech Stack:** SwiftUI, Observation framework, existing FeedLoader/PersistenceManager infrastructure.

## Global Constraints

- Zero code changes required when adding/removing country OPML files
- Country categories must not mix with global topic categories in filter chips
- All Countries toggle adds all country feeds to the main feed
- Per-country toggles override the All Countries master for that country
- Per-feed toggles work inside each country for individual source control
- Persist `disabledRegions` via FeedState / PersistenceManager
- Use existing patterns: `@Observable`, `@Environment`, `@AppStorage`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Models/FeedSource.swift` | Modify | Add `region` field |
| `Services/PersistenceManager.swift` | Modify | Add `disabledRegions` to FeedState, bump schema |
| `Services/OPMLParser.swift` | Modify | Tag sources with region from file path |
| `Models/Country.swift` | Create | Country struct + flag/name mapping |
| `Services/FeedLoader.swift` | Modify | disabledRegions, toggleRegion, availableCountries |
| `Views/CountriesListScreen.swift` | Create | Country list with master + per-country toggles |
| `Views/CountryDetailScreen.swift` | Create | Per-country feed list grouped by category |
| `Views/SettingsSheetView.swift` | Modify | Add Countries navigation row |

---

### Task 1: Add `region` to FeedSource and FeedState

**Files:**
- Modify: `feedmine/Models/FeedSource.swift`
- Modify: `feedmine/Services/PersistenceManager.swift:4-21`

**Interfaces:**
- Produces: `FeedSource.region: String`, `FeedState.disabledRegions: [String]`

- [ ] **Step 1: Add `region` to FeedSource**

Add the new property. Default to `"global"` so existing persisted sources (decoded from JSON without the field) get the correct value.

```swift
// feedmine/Models/FeedSource.swift — add after `category`:

    let region: String  // "global" | "countries/brazil"

    init(title: String, url: String, category: String, region: String = "global") {
        self.title = title
        self.url = url
        self.category = category
        self.region = region
    }

    // CodingKeys so existing JSON (without "region") decodes with the default.
    enum CodingKeys: String, CodingKey {
        case title, url, category, region
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        category = try c.decode(String.self, forKey: .category)
        region = (try? c.decode(String.self, forKey: .region)) ?? "global"
    }
```

- [ ] **Step 2: Add `disabledRegions` to FeedState**

```swift
// feedmine/Services/PersistenceManager.swift — inside FeedState, add after disabledSourceIDs:
    var disabledRegions: [String] = []
```

- [ ] **Step 3: Bump schema version for migration**

```swift
// In FeedState:
    var schemaVersion: Int = 3  // was 2
```

Add migration in `migrateIfNeeded`:

```swift
// In PersistenceManager.migrateIfNeeded, add:
    if state.schemaVersion < 3 {
        state.schemaVersion = 3
        state.disabledRegions = []
        print("[Persistence] Migrated schema v2 → v3 (added disabledRegions)")
    }
```

Also update `loadPersistedState()` free function:

```swift
// In loadPersistedState(), after the v1→v2 migration block:
    if state.schemaVersion < 3 {
        state.schemaVersion = 3
        state.disabledRegions = []
    }
```

- [ ] **Step 4: Build and verify it compiles**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 5: Commit**

```bash
git add feedmine/Models/FeedSource.swift feedmine/Services/PersistenceManager.swift
git commit -m "feat: add region field to FeedSource and disabledRegions to FeedState"
```

---

### Task 2: Tag sources with region in OPMLParser

**Files:**
- Modify: `feedmine/Services/OPMLParser.swift:23-27`

**Interfaces:**
- Consumes: `FeedSource(region:)` from Task 1
- Produces: OPML files under `countries/` get region `"countries/<filename>"`, root files get `"global"`

- [ ] **Step 1: Compute region from file URL**

```swift
// In OPMLParser.parseAll(), inside the for-loop over opmlFiles, add before parseFile call:
    let region: String
    let pathComponents = fileURL.pathComponents
    if pathComponents.contains("countries"), let idx = pathComponents.lastIndex(of: "countries") {
        let countryFile = pathComponents.last ?? fileName
        let countryName = (countryFile as NSString).deletingPathExtension
        region = "countries/\(countryName)"
    } else {
        region = "global"
    }
```

- [ ] **Step 2: Pass region to FeedSource initializer**

The OPMLDelegate currently creates `FeedSource(title:url:category:)`. It needs to accept and use `region`.

```swift
// In OPMLDelegate, add a property:
    var region: String = "global"

// In OPMLParser.parseFile, set it before parsing:
    delegate.region = region

// In OPMLDelegate.parser(didStartElement:), pass region:
    sources.append(
        FeedSource(
            title: title.isEmpty ? category : title,
            url: xmlUrl,
            category: category,
            region: region
        )
    )
```

Also update `parseAll()` to pass region:

```swift
// Before the parseFile call in the for loop:
    let (sources, invalids) = try parseFile(url: fileURL, fallbackCategory: fileName.capitalized, region: region)

// Update parseFile signature:
    private static func parseFile(url: URL, fallbackCategory: String, region: String) throws -> (sources: [FeedSource], invalidCount: Int)
```

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 4: Commit**

```bash
git add feedmine/Services/OPMLParser.swift
git commit -m "feat: tag OPML sources with region from file path"
```

---

### Task 3: Country model + flag/name mapping

**Files:**
- Create: `feedmine/Models/Country.swift`

**Interfaces:**
- Produces: `Country` struct, `CountryStore.countryName(for:)`, `CountryStore.countryFlag(for:)`

- [ ] **Step 1: Create Country.swift**

```swift
// feedmine/Models/Country.swift
import Foundation

struct Country: Identifiable, Hashable {
    var id: String { region }
    let region: String          // "countries/brazil"
    let name: String            // "Brazil"
    let flag: String            // "🇧🇷"
    let feedCount: Int
    let categories: [String]

    /// The file-slug extracted from the region (e.g. "brazil" from "countries/brazil")
    var slug: String {
        region.replacingOccurrences(of: "countries/", with: "")
    }
}

enum CountryStore {
    /// Map OPML filename slug → (display name, emoji flag)
    private static let metadata: [String: (name: String, flag: String)] = [
        "algeria": ("Algeria", "🇩🇿"),
        "angola": ("Angola", "🇦🇴"),
        "argentina": ("Argentina", "🇦🇷"),
        "armenia": ("Armenia", "🇦🇲"),
        "australia": ("Australia", "🇦🇺"),
        "austria": ("Austria", "🇦🇹"),
        "azerbaijan": ("Azerbaijan", "🇦🇿"),
        "bangladesh": ("Bangladesh", "🇧🇩"),
        "belarus": ("Belarus", "🇧🇾"),
        "belgium": ("Belgium", "🇧🇪"),
        "bolivia": ("Bolivia", "🇧🇴"),
        "brazil": ("Brazil", "🇧🇷"),
        "bulgaria": ("Bulgaria", "🇧🇬"),
        "cambodia": ("Cambodia", "🇰🇭"),
        "canada": ("Canada", "🇨🇦"),
        "chile": ("Chile", "🇨🇱"),
        "china": ("China", "🇨🇳"),
        "colombia": ("Colombia", "🇨🇴"),
        "costa-rica": ("Costa Rica", "🇨🇷"),
        "croatia": ("Croatia", "🇭🇷"),
        "cuba": ("Cuba", "🇨🇺"),
        "cyprus": ("Cyprus", "🇨🇾"),
        "czech-republic": ("Czech Republic", "🇨🇿"),
        "denmark": ("Denmark", "🇩🇰"),
        "dominican-republic": ("Dominican Republic", "🇩🇴"),
        "ecuador": ("Ecuador", "🇪🇨"),
        "egypt": ("Egypt", "🇪🇬"),
        "el-salvador": ("El Salvador", "🇸🇻"),
        "estonia": ("Estonia", "🇪🇪"),
        "ethiopia": ("Ethiopia", "🇪🇹"),
        "finland": ("Finland", "🇫🇮"),
        "france": ("France", "🇫🇷"),
        "georgia": ("Georgia", "🇬🇪"),
        "germany": ("Germany", "🇩🇪"),
        "ghana": ("Ghana", "🇬🇭"),
        "greece": ("Greece", "🇬🇷"),
        "guatemala": ("Guatemala", "🇬🇹"),
        "haiti": ("Haiti", "🇭🇹"),
        "honduras": ("Honduras", "🇭🇳"),
        "hungary": ("Hungary", "🇭🇺"),
        "iceland": ("Iceland", "🇮🇸"),
        "india": ("India", "🇮🇳"),
        "indonesia": ("Indonesia", "🇮🇩"),
        "iran": ("Iran", "🇮🇷"),
        "iraq": ("Iraq", "🇮🇶"),
        "ireland": ("Ireland", "🇮🇪"),
        "israel": ("Israel", "🇮🇱"),
        "italy": ("Italy", "🇮🇹"),
        "ivory-coast": ("Ivory Coast", "🇨🇮"),
        "jamaica": ("Jamaica", "🇯🇲"),
        "japan": ("Japan", "🇯🇵"),
        "kazakhstan": ("Kazakhstan", "🇰🇿"),
        "kenya": ("Kenya", "🇰🇪"),
        "latvia": ("Latvia", "🇱🇻"),
        "lithuania": ("Lithuania", "🇱🇹"),
        "luxembourg": ("Luxembourg", "🇱🇺"),
        "malaysia": ("Malaysia", "🇲🇾"),
        "malta": ("Malta", "🇲🇹"),
        "mexico": ("Mexico", "🇲🇽"),
        "morocco": ("Morocco", "🇲🇦"),
        "myanmar": ("Myanmar", "🇲🇲"),
        "nepal": ("Nepal", "🇳🇵"),
        "netherlands": ("Netherlands", "🇳🇱"),
        "new-zealand": ("New Zealand", "🇳🇿"),
        "nicaragua": ("Nicaragua", "🇳🇮"),
        "nigeria": ("Nigeria", "🇳🇬"),
        "norway": ("Norway", "🇳🇴"),
        "pakistan": ("Pakistan", "🇵🇰"),
        "panama": ("Panama", "🇵🇦"),
        "paraguay": ("Paraguay", "🇵🇾"),
        "peru": ("Peru", "🇵🇪"),
        "philippines": ("Philippines", "🇵🇭"),
        "poland": ("Poland", "🇵🇱"),
        "portugal": ("Portugal", "🇵🇹"),
        "puerto-rico": ("Puerto Rico", "🇵🇷"),
        "qatar": ("Qatar", "🇶🇦"),
        "romania": ("Romania", "🇷🇴"),
        "russia": ("Russia", "🇷🇺"),
        "saudi-arabia": ("Saudi Arabia", "🇸🇦"),
        "serbia": ("Serbia", "🇷🇸"),
        "singapore": ("Singapore", "🇸🇬"),
        "slovakia": ("Slovakia", "🇸🇰"),
        "slovenia": ("Slovenia", "🇸🇮"),
        "south-africa": ("South Africa", "🇿🇦"),
        "south-korea": ("South Korea", "🇰🇷"),
        "spain": ("Spain", "🇪🇸"),
        "sri-lanka": ("Sri Lanka", "🇱🇰"),
        "sudan": ("Sudan", "🇸🇩"),
        "sweden": ("Sweden", "🇸🇪"),
        "switzerland": ("Switzerland", "🇨🇭"),
        "taiwan": ("Taiwan", "🇹🇼"),
        "thailand": ("Thailand", "🇹🇭"),
        "tunisia": ("Tunisia", "🇹🇳"),
        "turkey": ("Turkey", "🇹🇷"),
        "uae": ("UAE", "🇦🇪"),
        "ukraine": ("Ukraine", "🇺🇦"),
        "united-kingdom": ("United Kingdom", "🇬🇧"),
        "uruguay": ("Uruguay", "🇺🇾"),
        "venezuela": ("Venezuela", "🇻🇪"),
        "vietnam": ("Vietnam", "🇻🇳"),
    ]

    static func countryName(for slug: String) -> String {
        metadata[slug]?.name ?? slug.capitalized.replacingOccurrences(of: "-", with: " ")
    }

    static func countryFlag(for slug: String) -> String {
        metadata[slug]?.flag ?? "🌐"
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Commit**

```bash
git add feedmine/Models/Country.swift
git commit -m "feat: Country model with flag/name mapping for 97 countries"
```

---

### Task 4: FeedLoader — disabledRegions, country methods

**Files:**
- Modify: `feedmine/Services/FeedLoader.swift`

**Interfaces:**
- Consumes: `FeedSource.region`, `Country` from Tasks 1-3
- Produces: `disabledRegions`, `availableCountries`, `toggleRegion()`, `isRegionEnabled()`, `toggleAllCountries()`, `countryFeeds(for:)`

- [ ] **Step 1: Add `disabledRegions` property and persistence**

```swift
// In FeedLoader, add after disabledSourceIDs:
    var disabledRegions: Set<String> = []

// In buildState(), add after disabledSourceIDs:
    disabledRegions: Array(disabledRegions),

// In restoreState(from:), add after disabledSourceIDs:
    disabledRegions = Set(state.disabledRegions)
```

- [ ] **Step 2: Update `enabledSources` to respect disabledRegions**

```swift
// Replace existing enabledSources:
    var enabledSources: [FeedSource] {
        sources.filter { source in
            if disabledSourceIDs.contains(source.url) { return false }
            if source.region != "global" && disabledRegions.contains(source.region) { return false }
            return true
        }
    }
```

- [ ] **Step 3: Update `availableCategories` to exclude country feeds**

```swift
// Replace existing availableCategories:
    var availableCategories: [String] {
        let cats = Set(sources
            .filter { $0.region == "global" }
            .map(\.category))
            .sorted()
        return cats
    }
```

- [ ] **Step 4: Add country query methods**

```swift
// Add after availableCategories:
    var availableCountries: [Country] {
        let grouped = Dictionary(grouping: sources, by: \.region)
        return grouped
            .filter { $0.key.hasPrefix("countries/") }
            .compactMap { region, feeds -> Country? in
                let slug = region.replacingOccurrences(of: "countries/", with: "")
                let categories = Array(Set(feeds.map(\.category))).sorted()
                return Country(
                    region: region,
                    name: CountryStore.countryName(for: slug),
                    flag: CountryStore.countryFlag(for: slug),
                    feedCount: feeds.count,
                    categories: categories
                )
            }
            .sorted { $0.name < $1.name }
    }

    func countryFeeds(for region: String) -> [FeedSource] {
        sources
            .filter { $0.region == region }
            .sorted { $0.category < $1.category || ($0.category == $1.category && $0.title < $1.title) }
    }

    func toggleRegion(_ region: String) {
        if disabledRegions.contains(region) {
            disabledRegions.remove(region)
        } else {
            disabledRegions.insert(region)
        }
        PersistenceManager.shared.save(buildState())
    }

    func isRegionEnabled(_ region: String) -> Bool {
        !disabledRegions.contains(region)
    }

    func toggleAllCountries() {
        let allCountryRegions = Set(sources
            .filter { $0.region.hasPrefix("countries/") }
            .map(\.region))
        // If ANY country is enabled → disable all. Otherwise enable all.
        let anyEnabled = allCountryRegions.contains(where: { !disabledRegions.contains($0) })
        if anyEnabled {
            disabledRegions.formUnion(allCountryRegions)
        } else {
            disabledRegions.subtract(allCountryRegions)
        }
        PersistenceManager.shared.save(buildState())
    }

    /// True when at least one country region is enabled
    var isAnyCountryEnabled: Bool {
        sources.contains { $0.region.hasPrefix("countries/") && !disabledRegions.contains($0.region) }
    }
```

- [ ] **Step 5: Build and verify**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 5: Commit**

```bash
git add feedmine/Services/FeedLoader.swift
git commit -m "feat: FeedLoader disabledRegions + country query methods"
```

---

### Task 5: CountriesListScreen

**Files:**
- Create: `feedmine/Views/CountriesListScreen.swift`

**Interfaces:**
- Consumes: `FeedLoader.availableCountries`, `toggleAllCountries()`, `toggleRegion()`, `isRegionEnabled()`, `isAnyCountryEnabled`

- [ ] **Step 1: Create CountriesListScreen.swift**

```swift
// feedmine/Views/CountriesListScreen.swift
import SwiftUI

struct CountriesListScreen: View {
    @Environment(FeedLoader.self) private var loader

    var body: some View {
        List {
            // Master toggle
            Section {
                HStack {
                    Label("All Countries", systemImage: "globe.americas.fill")
                        .font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { loader.isAnyCountryEnabled },
                        set: { _ in loader.toggleAllCountries() }
                    ))
                    .labelsHidden()
                    .tint(.green)
                }
            }

            // Per-country list
            Section {
                ForEach(loader.availableCountries) { country in
                    NavigationLink {
                        CountryDetailScreen(country: country)
                    } label: {
                        HStack(spacing: 12) {
                            Text(country.flag).font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(country.name).font(.body)
                                Text("\(country.feedCount) feeds").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { loader.isRegionEnabled(country.region) },
                                set: { _ in loader.toggleRegion(country.region) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                }
            } footer: {
                let total = loader.availableCountries.map(\.feedCount).reduce(0, +)
                Text("\(loader.availableCountries.count) countries · \(total) feeds")
            }
        }
        .navigationTitle("Countries")
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Commit**

```bash
git add feedmine/Views/CountriesListScreen.swift
git commit -m "feat: CountriesListScreen with master + per-country toggles"
```

---

### Task 6: CountryDetailScreen

**Files:**
- Create: `feedmine/Views/CountryDetailScreen.swift`

**Interfaces:**
- Consumes: `Country`, `FeedLoader.countryFeeds(for:)`, `isSourceEnabled()`, `toggleSource()`

- [ ] **Step 1: Create CountryDetailScreen.swift**

```swift
// feedmine/Views/CountryDetailScreen.swift
import SwiftUI

struct CountryDetailScreen: View {
    @Environment(FeedLoader.self) private var loader
    let country: Country

    private var feedsByCategory: [(String, [FeedSource])] {
        let grouped = Dictionary(grouping: loader.countryFeeds(for: country.region), by: \.category)
        return grouped.sorted { $0.key < $1.key }
    }

    var body: some View {
        List {
            ForEach(feedsByCategory, id: \.0) { category, sources in
                Section {
                    ForEach(sources, id: \.url) { source in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.title).font(.subheadline)
                                Text(source.url)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { loader.isSourceEnabled(source.url) },
                                set: { _ in loader.toggleSource(source.url) }
                            ))
                            .labelsHidden()
                            .tint(.green)
                        }
                    }
                } header: {
                    Label("\(category) (\(sources.count))", systemImage: categoryIcon(category))
                }
            }
        }
        .navigationTitle("\(country.flag) \(country.name)")
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack {
                    Text("\(country.flag) \(country.name)").font(.headline)
                    Text("\(country.feedCount) feeds").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func categoryIcon(_ category: String) -> String {
        let lower = category.lowercased()
        if lower.contains("news") { return "newspaper.fill" }
        if lower.contains("sport") { return "sportscourt.fill" }
        if lower.contains("tech") || lower.contains("programming") { return "laptopcomputer" }
        if lower.contains("science") { return "flask.fill" }
        if lower.contains("movie") || lower.contains("film") || lower.contains("cinema") { return "film.fill" }
        if lower.contains("music") { return "music.note.list" }
        if lower.contains("food") { return "fork.knife" }
        if lower.contains("travel") { return "airplane" }
        if lower.contains("culture") || lower.contains("art") { return "theatermasks.fill" }
        if lower.contains("business") || lower.contains("economy") { return "chart.bar.fill" }
        if lower.contains("design") || lower.contains("architecture") { return "paintbrush.fill" }
        if lower.contains("environment") || lower.contains("nature") { return "leaf.fill" }
        if lower.contains("history") { return "book.fill" }
        if lower.contains("photo") { return "camera.fill" }
        if lower.contains("podcast") || lower.contains("audio") { return "headphones" }
        if lower.contains("youtube") || lower.contains("video") { return "play.rectangle.fill" }
        if lower.contains("blog") { return "pencil.and.outline" }
        if lower.contains("apple") { return "apple.logo" }
        if lower.contains("diy") || lower.contains("craft") { return "hammer.fill" }
        if lower.contains("game") || lower.contains("gaming") { return "gamecontroller.fill" }
        return "antenna.radiowaves.left.and.right"
    }
}
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Commit**

```bash
git add feedmine/Views/CountryDetailScreen.swift
git commit -m "feat: CountryDetailScreen with per-feed toggles grouped by category"
```

---

### Task 7: Add Countries row to Settings

**Files:**
- Modify: `feedmine/Views/SettingsSheetView.swift`

- [ ] **Step 1: Add Countries navigation row**

```swift
// In SettingsSheetView, add a new Section before the "Data" section:

    // MARK: - Feeds
    Section("Feeds") {
        NavigationLink {
            CountriesListScreen()
        } label: {
            Label("Countries", systemImage: "globe")
        }
    }
```

- [ ] **Step 2: Build and verify**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 3: Commit**

```bash
git add feedmine/Views/SettingsSheetView.swift
git commit -m "feat: add Countries navigation row to Settings"
```

---

### Task 8: Integration — build, run, verify end-to-end

- [ ] **Step 1: Full clean build**

```bash
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' clean build 2>&1 | tail -10
```

Expected: **BUILD SUCCEEDED**

- [ ] **Step 2: Verify on simulator**

```bash
# Launch app
xcrun simctl boot "iPhone 16" 2>/dev/null
open -a Simulator
xcodebuild -project feedmine.xcodeproj -scheme feedmine -destination 'platform=iOS Simulator,name=iPhone 16' test 2>&1 | tail -20
```

- [ ] **Step 3: Manual verification checklist**
  1. Open Settings → tap Countries → see list of 97 countries with flags
  2. Toggle "All Countries" → all enabled, all disabled
  3. Toggle individual country (Brazil) → verify toggle works
  4. Tap Brazil → see feeds grouped by category (News, Sports, Tech, etc.)
  5. Toggle individual feed off → verify it's disabled
  6. Go back to main feed, enable Brazil → verify Brazilian articles appear
  7. Disable Brazil → verify no Brazilian articles in feed
  8. Kill app, reopen → verify country toggles persist

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "feat: country feeds integration — end-to-end verified"
```
