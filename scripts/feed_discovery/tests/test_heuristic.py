from __future__ import annotations

from scripts.feed_discovery.heuristic import host_of, is_national
from scripts.feed_discovery.models import Country

BR = Country("brazil", "Brazil", "br", True, "pt", "br-pt", ["globo.com"])
US = Country("usa", "USA", "us", False, "en", "us-en", ["nytimes.com"])
BLOCK = {"bbc.com", "techcrunch.com"}


def test_host_of_strips_www_and_lowercases():
    assert host_of("https://WWW.G1.Globo.com/rss/") == "g1.globo.com"


def test_cctld_domain_is_national():
    assert is_national("https://www.uol.com.br/feed/", BR, BLOCK) == (True, "cctld")


def test_allowlisted_dotcom_is_national():
    assert is_national("https://globo.com/rss/", BR, BLOCK) == (True, "allowlist")


def test_blocklisted_is_rejected():
    assert is_national("https://techcrunch.com/feed/", BR, BLOCK) == (False, "blocked")


def test_foreign_is_rejected():
    assert is_national("https://example.fr/feed/", BR, BLOCK) == (False, "foreign")


def test_no_cctld_country_only_allowlist_passes():
    # USA: use_cctld=False, so only allowlist passes.
    assert is_national("https://nytimes.com/feed/", US, BLOCK) == (True, "allowlist")
    assert is_national("https://randomsite.com/feed/", US, BLOCK) == (False, "foreign")


def test_national_edition_on_intl_brand_passes_via_cctld():
    assert is_national("https://cnnbrasil.com.br/feed/", BR, BLOCK) == (True, "cctld")
