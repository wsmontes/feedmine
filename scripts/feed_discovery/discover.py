from __future__ import annotations

import re
from urllib.parse import urljoin, urlparse

import aiohttp

from .verify import parse_feed

USER_AGENT = "FeedmineDiscovery/1.0"
COMMON_PATHS = ["/feed/", "/rss/", "/rss.xml", "/feed.xml", "/atom.xml", "/index.xml"]
_MAX_HTML_BYTES = 128 * 1024
_MAX_FEED_BYTES = 64 * 1024
_LINK_RE = re.compile(r"<link\b[^>]*>", re.I)
_HREF_RE = re.compile(r"href\s*=\s*[\"']([^\"']+)[\"']", re.I)
# WordPress comment feeds and similar are noise, not content feeds.
_JUNK_RE = re.compile(r"/comments/feed|/comments/rss", re.I)


def _is_junk_feed(url: str) -> bool:
    return bool(_JUNK_RE.search(url))


def find_feeds_in_html(html: str, base_url: str) -> list[str]:
    out: list[str] = []
    for tag in _LINK_RE.findall(html):
        low = tag.lower()
        if "alternate" in low and ("rss+xml" in low or "atom+xml" in low):
            m = _HREF_RE.search(tag)
            if m:
                url = urljoin(base_url, m.group(1))
                if not _is_junk_feed(url):
                    out.append(url)
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


def _root_of(url: str) -> str:
    parsed = urlparse(url)
    return f"{parsed.scheme}://{parsed.netloc}"


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
            data = await resp.content.read(_MAX_HTML_BYTES)
            return data.decode("utf-8", errors="ignore")
    except (aiohttp.ClientError, UnicodeError, TimeoutError):
        return ""


async def _is_live_feed(session: aiohttp.ClientSession, url: str, timeout: int) -> bool:
    try:
        async with session.get(
            url,
            headers={"User-Agent": USER_AGENT},
            timeout=aiohttp.ClientTimeout(total=timeout),
            allow_redirects=True,
        ) as resp:
            if resp.status != 200:
                return False
            body = await resp.content.read(_MAX_FEED_BYTES)
    except (aiohttp.ClientError, TimeoutError):
        return False
    ok, _title = parse_feed(body)
    return ok


async def _probe_feeds(session: aiohttp.ClientSession, root: str, timeout: int) -> list[str]:
    """Last resort: try common feed paths, keep only ones that are real feeds."""
    out: list[str] = []
    for path in COMMON_PATHS:
        url = urljoin(root + "/", path.lstrip("/"))
        if await _is_live_feed(session, url, timeout):
            out.append(url)
    return out


async def discover_feeds(
    session: aiohttp.ClientSession,
    page_url: str,
    timeout: int,
    root_cache: dict[str, list[str]] | None = None,
) -> list[str]:
    if _looks_like_feed_url(page_url):
        return [page_url]

    feeds: list[str] = []

    # 1. Autodiscover on the result page itself.
    html = await _fetch_text(session, page_url, timeout)
    if html:
        feeds.extend(find_feeds_in_html(html, page_url))

    # 2. Autodiscover on the domain root — most sites advertise their feed on
    #    the homepage even when article/section pages do not. Cached per root.
    root = _root_of(page_url)
    if root_cache is not None and root in root_cache:
        feeds.extend(root_cache[root])
    else:
        if urlparse(page_url).path.strip("/") == "" and html:
            root_feeds = find_feeds_in_html(html, page_url)  # page already is the root
        else:
            root_html = await _fetch_text(session, root + "/", timeout)
            root_feeds = find_feeds_in_html(root_html, root + "/") if root_html else []
        if root_cache is not None:
            root_cache[root] = root_feeds
        feeds.extend(root_feeds)

    feeds = list(dict.fromkeys(feeds))
    if feeds:
        return feeds

    # 3. Nothing advertised — probe common paths, validated as real feeds.
    return await _probe_feeds(session, root, timeout)
