from __future__ import annotations

from urllib.parse import urlparse

from .models import Country


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
