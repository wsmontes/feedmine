from __future__ import annotations

import xml.etree.ElementTree as ET

import aiohttp

from feedmine_verify.constants import MAX_BODY_BYTES

USER_AGENT = "FeedmineDiscovery/1.0"
_FEED_TAGS = {"rss", "feed", "rdf"}


def _localname(tag: str) -> str:
    return tag.lower().rsplit("}", 1)[-1]


def parse_feed(body: bytes) -> tuple[bool, str]:
    try:
        root = ET.fromstring(body)
    except ET.ParseError:
        return False, ""
    if _localname(root.tag) not in _FEED_TAGS:
        return False, ""
    for el in root.iter():
        if _localname(el.tag) == "title" and (el.text or "").strip():
            return True, el.text.strip()
    return True, ""


async def verify_feed(session: aiohttp.ClientSession, url: str, timeout: int) -> tuple[bool, int, str]:
    try:
        async with session.get(
            url,
            headers={"User-Agent": USER_AGENT},
            timeout=aiohttp.ClientTimeout(total=timeout),
            allow_redirects=True,
        ) as resp:
            status = resp.status
            if status != 200:
                return False, status, ""
            body = await resp.content.read(MAX_BODY_BYTES)
    except (aiohttp.ClientError, TimeoutError):
        return False, 0, ""
    is_valid, title = parse_feed(body)
    return is_valid, status, title
