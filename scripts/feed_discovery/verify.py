from __future__ import annotations

import html
import re

import aiohttp

from feedmine_verify.constants import MAX_BODY_BYTES

USER_AGENT = "FeedmineDiscovery/1.0"

# Feed liveness only fetches the first MAX_BODY_BYTES of the body, so the
# document is usually truncated. A full ET.fromstring() parse fails on any
# feed larger than that cap, so detect the feed root and title from the head
# of the document instead — both appear before any items/entries.
_ROOT_RE = re.compile(r"<(rss|feed|rdf:rdf)\b", re.I)
_TITLE_RE = re.compile(r"<(?:\w+:)?title[^>]*>(.*?)</(?:\w+:)?title>", re.I | re.S)
_CDATA_RE = re.compile(r"<!\[CDATA\[(.*?)\]\]>", re.S)


def parse_feed(body: bytes) -> tuple[bool, str]:
    text = body.decode("utf-8", errors="ignore")
    if not _ROOT_RE.search(text[:4096]):
        return False, ""
    title = ""
    m = _TITLE_RE.search(text)
    if m:
        raw = m.group(1)
        cdata = _CDATA_RE.search(raw)
        if cdata:
            raw = cdata.group(1)
        title = html.unescape(raw).strip()
    return True, title


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
