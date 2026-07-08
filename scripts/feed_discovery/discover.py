from __future__ import annotations

import re
from urllib.parse import urljoin, urlparse

import aiohttp

USER_AGENT = "FeedmineDiscovery/1.0"
COMMON_PATHS = ["/feed/", "/rss/", "/rss.xml", "/feed.xml", "/atom.xml", "/index.xml"]
_LINK_RE = re.compile(r"<link\b[^>]*>", re.I)
_HREF_RE = re.compile(r"href\s*=\s*[\"']([^\"']+)[\"']", re.I)


def find_feeds_in_html(html: str, base_url: str) -> list[str]:
    out: list[str] = []
    for tag in _LINK_RE.findall(html):
        low = tag.lower()
        if "alternate" in low and ("rss+xml" in low or "atom+xml" in low):
            m = _HREF_RE.search(tag)
            if m:
                out.append(urljoin(base_url, m.group(1)))
    seen: set[str] = set()
    result: list[str] = []
    for u in out:
        if u not in seen:
            seen.add(u)
            result.append(u)
    return result


def _looks_like_feed_url(url: str) -> bool:
    path = urlparse(url).path.lower()
    return path.endswith((".xml", "/feed", "/feed/", "/rss", "/rss/")) or "rss" in path or "feed" in path


async def _fetch_text(session: aiohttp.ClientSession, url: str, timeout: int) -> str:
    try:
        async with session.get(
            url,
            headers={"User-Agent": USER_AGENT},
            timeout=aiohttp.ClientTimeout(total=timeout),
            allow_redirects=True,
        ) as resp:
            if resp.status != 200:
                return ""
            data = await resp.content.read(128 * 1024)
            return data.decode("utf-8", errors="ignore")
    except (aiohttp.ClientError, UnicodeError, TimeoutError):
        return ""


async def discover_feeds(session: aiohttp.ClientSession, page_url: str, timeout: int) -> list[str]:
    if _looks_like_feed_url(page_url):
        return [page_url]

    html = await _fetch_text(session, page_url, timeout)
    if html:
        feeds = find_feeds_in_html(html, page_url)
        if feeds:
            return feeds

    # Fallback: probe common feed paths on the site root.
    parsed = urlparse(page_url)
    root = f"{parsed.scheme}://{parsed.netloc}"
    return [urljoin(root, p) for p in COMMON_PATHS]
