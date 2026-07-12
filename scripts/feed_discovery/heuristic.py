from __future__ import annotations

from urllib.parse import urlparse

from .models import Country

# Domains that are never "local" to any city/region — global outlets.
GLOBAL_BLOCKLIST: set[str] = {
    "cnn.com", "bbc.com", "bbc.co.uk", "nytimes.com", "washingtonpost.com",
    "theguardian.com", "reuters.com", "apnews.com", "bloomberg.com",
    "wsj.com", "economist.com", "techcrunch.com", "theverge.com", "wired.com",
    "arstechnica.com", "engadget.com", "cnet.com", "mashable.com",
    "buzzfeed.com", "vice.com", "vox.com", "politico.com", "huffpost.com",
    "forbes.com", "businessinsider.com", "theatlantic.com", "newyorker.com",
    "npr.org", "aljazeera.com", "france24.com", "dw.com", "rt.com",
    "reddit.com", "medium.com", "substack.com", "spotify.com",
    "apple.com", "google.com", "youtube.com", "facebook.com", "twitter.com",
    "instagram.com", "tiktok.com", "yahoo.com", "msn.com",
}


def is_local(
    url: str,
    subregion_name: str,
    country: Country | None = None,
    feed_title: str = "",
    blocklist: set[str] | None = None,
) -> tuple[bool, str]:
    """Check if a feed URL belongs to a specific sub-region (city/state).

    Uses multiple signals, ordered from strongest to weakest:

    1. **Global blocklist** — domains that are never local.
    2. **Domain contains city** — hostname mentions the city name.
    3. **Feed title contains city** — the feed's <title> mentions the city.
    4. **Fallback** — accept as "discovered by city query" (weakest).

    Args:
        url: Feed URL to classify.
        subregion_name: Human-readable city/region name (e.g. "Lagos").
        country: Parent Country object (for cctld check, not used alone).
        feed_title: Feed title from verification (optional, strengthens signal).
        blocklist: Additional domains to reject (defaults to GLOBAL_BLOCKLIST).

    Returns:
        (is_local_bool, reason_str)
    """
    host = host_of(url)
    if not host:
        return False, "foreign"

    bl = blocklist if blocklist is not None else GLOBAL_BLOCKLIST

    # 1. Global blocklist — fast reject.
    if host in bl or any(host.endswith("." + d) for d in bl):
        return False, "global_blocklist"

    # 2. Domain contains city name (normalised).
    city_lower = subregion_name.lower()
    # Also try individual words for multi-word cities: "Rio de Janeiro" -> "rio"
    city_words = [w for w in city_lower.split() if len(w) > 2]
    host_lower = host.lower()

    if city_lower.replace(" ", "") in host_lower.replace("-", "").replace(".", ""):
        return True, "domain_contains_city"
    for word in city_words:
        if word in host_lower:
            return True, "domain_contains_city"

    # 3. Feed title mentions the city.
    if feed_title and city_lower in feed_title.lower():
        return True, "title_contains_city"

    # 4. Fallback — the feed was discovered by a city-targeted query.
    return True, "discovered_by_city_query"


def host_of(url: str) -> str:
    host = (urlparse(url).hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    return host


def _matches(host: str, domains) -> bool:
    for d in domains:
        d = d.lower()
        if host == d or host.endswith("." + d):
            return True
    return False


def _cctld_match(host: str, cctld: str) -> bool:
    cctld = cctld.lower()
    return host == cctld or host.endswith("." + cctld)


def is_national(url: str, country: Country, blocklist: set[str]) -> tuple[bool, str]:
    host = host_of(url)
    if not host:
        return False, "foreign"
    if _matches(host, country.allowlist):
        return True, "allowlist"
    if country.use_cctld and _cctld_match(host, country.cctld):
        return True, "cctld"
    if _matches(host, blocklist):
        return False, "blocked"
    return False, "foreign"
