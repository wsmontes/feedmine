from scripts.feed_discovery.heuristic import is_local, GLOBAL_BLOCKLIST, host_of
from scripts.feed_discovery.models import Country

NG = Country("nigeria", "Nigeria", "ng", True, "en", "ng-en", [])


def test_domain_contains_city_name():
    assert is_local("https://lagosnews.com/feed/", "Lagos", NG) == (True, "domain_contains_city")


def test_feed_title_contains_city():
    assert is_local("https://example.com/feed/", "Lagos", NG, feed_title="Lagos Today News") == (True, "title_contains_city")


def test_discovered_by_city_query_fallback():
    assert is_local("https://random-ng-site.com/feed/", "Lagos", NG) == (True, "discovered_by_city_query")


def test_global_blocklist_never_local():
    assert is_local("https://cnn.com/feed/", "Lagos", NG) == (False, "global_blocklist")


def test_bbc_blocklisted():
    assert is_local("https://bbc.com/rss/", "Delhi", NG) == (False, "global_blocklist")


def test_city_name_in_domain_fuzzy():
    # "rio" should match in "riotimesonline.com"
    BR = Country("brazil", "Brazil", "br", True, "pt", "br-pt", [])
    assert is_local("https://riotimesonline.com/feed/", "Rio de Janeiro", BR) == (True, "domain_contains_city")


def test_empty_host_returns_false():
    assert is_local("not-a-url", "Lagos", NG) == (False, "foreign")


def test_host_of_strips_www():
    assert host_of("https://www.kalangonews.com/feed/") == "kalangonews.com"


def test_GLOBAL_BLOCKLIST_contains_major_global():
    assert "cnn.com" in GLOBAL_BLOCKLIST
    assert "bbc.com" in GLOBAL_BLOCKLIST
    assert "nytimes.com" in GLOBAL_BLOCKLIST
    assert "techcrunch.com" in GLOBAL_BLOCKLIST
