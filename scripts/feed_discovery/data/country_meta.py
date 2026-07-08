from __future__ import annotations

# slug -> (cctld, lang, use_cctld). ddg_region derives as f"{cctld}-{lang}".
# Auto-generated defaults — refine ccTLD/lang/allowlist by hand as needed.
COUNTRY_META: dict[str, tuple[str, str, bool]] = {
    "algeria": ("dz", "ar", True), "angola": ("ao", "pt", True),
    "argentina": ("ar", "es", True), "armenia": ("am", "hy", True),
    "australia": ("au", "en", True), "austria": ("at", "de", True),
    "azerbaijan": ("az", "az", True), "bangladesh": ("bd", "bn", True),
    "belarus": ("by", "be", True), "belgium": ("be", "nl", True),
    "bolivia": ("bo", "es", True), "brazil": ("br", "pt", True),
    "bulgaria": ("bg", "bg", True), "cambodia": ("kh", "km", True),
    "canada": ("ca", "en", True), "chile": ("cl", "es", True),
    "china": ("cn", "zh", True), "colombia": ("co", "es", True),
    "costa-rica": ("cr", "es", True), "croatia": ("hr", "hr", True),
    "cuba": ("cu", "es", True), "cyprus": ("cy", "el", True),
    "czech-republic": ("cz", "cs", True), "denmark": ("dk", "da", True),
    "dominican-republic": ("do", "es", True), "ecuador": ("ec", "es", True),
    "egypt": ("eg", "ar", True), "el-salvador": ("sv", "es", True),
    "estonia": ("ee", "et", True), "ethiopia": ("et", "am", True),
    "finland": ("fi", "fi", True), "france": ("fr", "fr", True),
    "georgia": ("ge", "ka", True), "germany": ("de", "de", True),
    "ghana": ("gh", "en", True), "greece": ("gr", "el", True),
    "guatemala": ("gt", "es", True), "haiti": ("ht", "fr", True),
    "honduras": ("hn", "es", True), "hungary": ("hu", "hu", True),
    "iceland": ("is", "is", True), "india": ("in", "en", True),
    "indonesia": ("id", "id", True), "iran": ("ir", "fa", True),
    "iraq": ("iq", "ar", True), "ireland": ("ie", "en", True),
    "israel": ("il", "he", True), "italy": ("it", "it", True),
    "ivory-coast": ("ci", "fr", True), "jamaica": ("jm", "en", True),
    "japan": ("jp", "ja", True), "kazakhstan": ("kz", "kk", True),
    "kenya": ("ke", "en", True), "latvia": ("lv", "lv", True),
    "lithuania": ("lt", "lt", True), "luxembourg": ("lu", "fr", True),
    "malaysia": ("my", "ms", True), "malta": ("mt", "en", True),
    "mexico": ("mx", "es", True), "morocco": ("ma", "ar", True),
    "myanmar": ("mm", "my", True), "nepal": ("np", "ne", True),
    "netherlands": ("nl", "nl", True), "new-zealand": ("nz", "en", True),
    "nicaragua": ("ni", "es", True), "nigeria": ("ng", "en", True),
    "norway": ("no", "no", True), "pakistan": ("pk", "ur", True),
    "panama": ("pa", "es", True), "paraguay": ("py", "es", True),
    "peru": ("pe", "es", True), "philippines": ("ph", "en", True),
    "poland": ("pl", "pl", True), "portugal": ("pt", "pt", True),
    "puerto-rico": ("pr", "es", True), "qatar": ("qa", "ar", True),
    "romania": ("ro", "ro", True), "russia": ("ru", "ru", True),
    "saudi-arabia": ("sa", "ar", True), "serbia": ("rs", "sr", True),
    "singapore": ("sg", "en", True), "slovakia": ("sk", "sk", True),
    "slovenia": ("si", "sl", True), "south-africa": ("za", "en", True),
    "south-korea": ("kr", "ko", True), "spain": ("es", "es", True),
    "sri-lanka": ("lk", "si", True), "sudan": ("sd", "ar", True),
    "sweden": ("se", "sv", True), "switzerland": ("ch", "de", True),
    "taiwan": ("tw", "zh", True), "thailand": ("th", "th", True),
    "tunisia": ("tn", "ar", True), "turkey": ("tr", "tr", True),
    "uae": ("ae", "ar", True), "ukraine": ("ua", "uk", True),
    "united-kingdom": ("uk", "en", True), "uruguay": ("uy", "es", True),
    "usa": ("us", "en", False), "venezuela": ("ve", "es", True),
    "vietnam": ("vn", "vi", True),
}

# Slugs whose title-case needs a manual override.
NAME_OVERRIDES: dict[str, str] = {
    "usa": "USA", "uae": "UAE", "uk": "UK",
    "united-kingdom": "United Kingdom", "el-salvador": "El Salvador",
    "costa-rica": "Costa Rica", "czech-republic": "Czech Republic",
    "dominican-republic": "Dominican Republic", "new-zealand": "New Zealand",
    "south-africa": "South Africa", "south-korea": "South Korea",
    "sri-lanka": "Sri Lanka", "puerto-rico": "Puerto Rico",
    "ivory-coast": "Ivory Coast", "saudi-arabia": "Saudi Arabia",
}


def display_name(slug: str) -> str:
    if slug in NAME_OVERRIDES:
        return NAME_OVERRIDES[slug]
    return " ".join(w.capitalize() for w in slug.split("-"))
