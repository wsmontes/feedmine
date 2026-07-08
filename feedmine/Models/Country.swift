import Foundation

struct Country: Identifiable, Hashable {
    var id: String { region }
    let region: String          // "countries/brazil"
    let name: String            // Localized display name
    let flag: String            // "🇧🇷"
    let feedCount: Int
    let categories: [String]
    /// Sub-regions within this country (e.g., states, provinces).
    /// Empty when the country has no region-level OPML files.
    let regions: [Region]

    var slug: String {
        region.replacingOccurrences(of: "countries/", with: "")
    }

    var hasRegions: Bool { !regions.isEmpty }
}

enum CountryStore {
    /// Map OPML filename slug → emoji flag
    private static let metadata: [String: String] = [
        "algeria": "🇩🇿",
        "angola": "🇦🇴",
        "argentina": "🇦🇷",
        "armenia": "🇦🇲",
        "australia": "🇦🇺",
        "austria": "🇦🇹",
        "azerbaijan": "🇦🇿",
        "bangladesh": "🇧🇩",
        "belarus": "🇧🇾",
        "belgium": "🇧🇪",
        "bolivia": "🇧🇴",
        "brazil": "🇧🇷",
        "bulgaria": "🇧🇬",
        "cambodia": "🇰🇭",
        "canada": "🇨🇦",
        "chile": "🇨🇱",
        "china": "🇨🇳",
        "colombia": "🇨🇴",
        "costa-rica": "🇨🇷",
        "croatia": "🇭🇷",
        "cuba": "🇨🇺",
        "cyprus": "🇨🇾",
        "czech-republic": "🇨🇿",
        "denmark": "🇩🇰",
        "dominican-republic": "🇩🇴",
        "ecuador": "🇪🇨",
        "egypt": "🇪🇬",
        "el-salvador": "🇸🇻",
        "estonia": "🇪🇪",
        "ethiopia": "🇪🇹",
        "finland": "🇫🇮",
        "france": "🇫🇷",
        "georgia": "🇬🇪",
        "germany": "🇩🇪",
        "ghana": "🇬🇭",
        "greece": "🇬🇷",
        "guatemala": "🇬🇹",
        "haiti": "🇭🇹",
        "honduras": "🇭🇳",
        "hungary": "🇭🇺",
        "iceland": "🇮🇸",
        "india": "🇮🇳",
        "indonesia": "🇮🇩",
        "iran": "🇮🇷",
        "iraq": "🇮🇶",
        "ireland": "🇮🇪",
        "israel": "🇮🇱",
        "italy": "🇮🇹",
        "ivory-coast": "🇨🇮",
        "jamaica": "🇯🇲",
        "japan": "🇯🇵",
        "kazakhstan": "🇰🇿",
        "kenya": "🇰🇪",
        "latvia": "🇱🇻",
        "lithuania": "🇱🇹",
        "luxembourg": "🇱🇺",
        "malaysia": "🇲🇾",
        "malta": "🇲🇹",
        "mexico": "🇲🇽",
        "morocco": "🇲🇦",
        "myanmar": "🇲🇲",
        "nepal": "🇳🇵",
        "netherlands": "🇳🇱",
        "new-zealand": "🇳🇿",
        "nicaragua": "🇳🇮",
        "nigeria": "🇳🇬",
        "norway": "🇳🇴",
        "pakistan": "🇵🇰",
        "panama": "🇵🇦",
        "paraguay": "🇵🇾",
        "peru": "🇵🇪",
        "philippines": "🇵🇭",
        "poland": "🇵🇱",
        "portugal": "🇵🇹",
        "puerto-rico": "🇵🇷",
        "qatar": "🇶🇦",
        "romania": "🇷🇴",
        "russia": "🇷🇺",
        "saudi-arabia": "🇸🇦",
        "serbia": "🇷🇸",
        "singapore": "🇸🇬",
        "slovakia": "🇸🇰",
        "slovenia": "🇸🇮",
        "south-africa": "🇿🇦",
        "south-korea": "🇰🇷",
        "spain": "🇪🇸",
        "sri-lanka": "🇱🇰",
        "sudan": "🇸🇩",
        "sweden": "🇸🇪",
        "switzerland": "🇨🇭",
        "taiwan": "🇹🇼",
        "thailand": "🇹🇭",
        "tunisia": "🇹🇳",
        "turkey": "🇹🇷",
        "uae": "🇦🇪",
        "ukraine": "🇺🇦",
        "united-kingdom": "🇬🇧",
        "usa": "🇺🇸",
        "uruguay": "🇺🇾",
        "venezuela": "🇻🇪",
        "vietnam": "🇻🇳",
    ]

    /// Map OPML slug → ISO 3166-1 alpha-2 region code for use with Locale.localizedString(forRegionCode:)
    private static let slugToRegionCode: [String: String] = [
        "algeria": "DZ", "angola": "AO", "argentina": "AR", "armenia": "AM",
        "australia": "AU", "austria": "AT", "azerbaijan": "AZ", "bangladesh": "BD",
        "belarus": "BY", "belgium": "BE", "bolivia": "BO", "brazil": "BR",
        "bulgaria": "BG", "cambodia": "KH", "canada": "CA", "chile": "CL",
        "china": "CN", "colombia": "CO", "costa-rica": "CR", "croatia": "HR",
        "cuba": "CU", "cyprus": "CY", "czech-republic": "CZ", "denmark": "DK",
        "dominican-republic": "DO", "ecuador": "EC", "egypt": "EG", "el-salvador": "SV",
        "estonia": "EE", "ethiopia": "ET", "finland": "FI", "france": "FR",
        "georgia": "GE", "germany": "DE", "ghana": "GH", "greece": "GR",
        "guatemala": "GT", "haiti": "HT", "honduras": "HN", "hungary": "HU",
        "iceland": "IS", "india": "IN", "indonesia": "ID", "iran": "IR",
        "iraq": "IQ", "ireland": "IE", "israel": "IL", "italy": "IT",
        "ivory-coast": "CI", "jamaica": "JM", "japan": "JP", "kazakhstan": "KZ",
        "kenya": "KE", "latvia": "LV", "lithuania": "LT", "luxembourg": "LU",
        "malaysia": "MY", "malta": "MT", "mexico": "MX", "morocco": "MA",
        "myanmar": "MM", "nepal": "NP", "netherlands": "NL", "new-zealand": "NZ",
        "nicaragua": "NI", "nigeria": "NG", "norway": "NO", "pakistan": "PK",
        "panama": "PA", "paraguay": "PY", "peru": "PE", "philippines": "PH",
        "poland": "PL", "portugal": "PT", "puerto-rico": "PR", "qatar": "QA",
        "romania": "RO", "russia": "RU", "saudi-arabia": "SA", "serbia": "RS",
        "singapore": "SG", "slovakia": "SK", "slovenia": "SI", "south-africa": "ZA",
        "south-korea": "KR", "spain": "ES", "sri-lanka": "LK", "sudan": "SD",
        "sweden": "SE", "switzerland": "CH", "taiwan": "TW", "thailand": "TH",
        "tunisia": "TN", "turkey": "TR", "uae": "AE", "ukraine": "UA",
        "united-kingdom": "GB", "uruguay": "UY", "venezuela": "VE", "vietnam": "VN",
        "usa": "US",
    ]

    // MARK: - Public API

    /// Returns the localized country name using the system's locale-aware API.
    /// Falls back to capitalized slug if the region code is unknown.
    static func countryName(for slug: String) -> String {
        if let code = slugToRegionCode[slug],
           let localized = Locale.current.localizedString(forRegionCode: code) {
            return localized
        }
        // Fallback: capitalize slug
        return slug.capitalized.replacingOccurrences(of: "-", with: " ")
    }

    /// Returns the emoji flag for a country slug.
    static func countryFlag(for slug: String) -> String {
        metadata[slug] ?? "🌐"
    }
}
