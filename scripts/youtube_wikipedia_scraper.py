#!/usr/bin/env python3
"""
Scrape YouTube channels from Wikipedia's "List of most-subscribed YouTube channels"
across all language versions.

Scans the FULL page (not just tables) because different language Wikipedias
structure the data differently:
  - en: YouTube links inside wikitable (cell 1 "Link")
  - pt, ar, etc: YouTube links in reference citations (m.youtube.com)
  - ja, ko: mixed table structures

Usage:
    python3 scripts/youtube_wikipedia_scraper.py           # scrape all, no resolve
    python3 scripts/youtube_wikipedia_scraper.py --resolve # also resolve handles to channel IDs

Output: scripts/feed_discovery/data/youtube_channels_wikipedia.json
"""

from __future__ import annotations

import json
import re
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import requests
from bs4 import BeautifulSoup

# ── Wikipedia language editions ─────────────────────────────────────────────
WIKI_PAGES: dict[str, str] = {
    "en": "https://en.wikipedia.org/wiki/List_of_most-subscribed_YouTube_channels",
    "ar": "https://ar.wikipedia.org/wiki/%D9%82%D8%A7%D8%A6%D9%85%D8%A9_%D9%82%D9%86%D9%88%D8%A7%D8%AA_%D9%8A%D9%88%D8%AA%D9%8A%D9%88%D8%A8_%D8%A7%D9%84%D8%A3%D9%83%D8%AB%D8%B1_%D8%A7%D8%B4%D8%AA%D8%B1%D8%A7%D9%83%D8%A7",
    "bn": "https://bn.wikipedia.org/wiki/%E0%A6%B8%E0%A6%B0%E0%A7%8D%E0%A6%AC%E0%A6%BE%E0%A6%A7%E0%A6%BF%E0%A6%95_%E0%A6%97%E0%A7%8D%E0%A6%B0%E0%A6%BE%E0%A6%B9%E0%A6%95%E0%A6%AC%E0%A6%BF%E0%A6%B6%E0%A6%BF%E0%A6%B7%E0%A7%8D%E0%A6%9F_%E0%A6%87%E0%A6%89%E0%A6%9F%E0%A6%BF%E0%A6%89%E0%A6%AC_%E0%A6%B8%E0%A6%AE%E0%A7%8D%E0%A6%AA%E0%A7%8D%E0%A6%B0%E0%A6%9A%E0%A6%BE%E0%A6%B0%E0%A6%95%E0%A7%87%E0%A6%A8%E0%A7%8D%E0%A6%A6%E0%A7%8D%E0%A6%B0%E0%A7%87%E0%A6%B0_%E0%A6%A4%E0%A6%BE%E0%A6%B2%E0%A6%BF%E0%A6%95%E0%A6%BE",
    "cs": "https://cs.wikipedia.org/wiki/Seznam_nejodeb%C3%ADran%C4%9Bj%C5%A1%C3%ADch_YouTube_kan%C3%A1l%C5%AF",
    "de": "https://de.wikipedia.org/wiki/Liste_der_meistabonnierten_YouTube-Kan%C3%A4le",
    "fa": "https://fa.wikipedia.org/wiki/%D9%81%D9%87%D8%B1%D8%B3%D8%AA_%DA%A9%D8%A7%D9%86%D8%A7%D9%84%E2%80%8C%D9%87%D8%A7%DB%8C_%DB%8C%D9%88%D8%AA%DB%8C%D9%88%D8%A8_%D8%A8%D8%A7_%D8%A8%DB%8C%D8%B4%D8%AA%D8%B1%DB%8C%D9%86_%D9%85%D8%B4%D8%AA%D8%B1%DA%A9",
    "gl": "https://gl.wikipedia.org/wiki/Lista_das_canles_de_YouTube_m%C3%A1is_subscritas",
    "he": "https://he.wikipedia.org/wiki/%D7%A2%D7%A8%D7%95%D7%A6%D7%99_%D7%94%D7%99%D7%95%D7%98%D7%99%D7%95%D7%91_%D7%91%D7%A2%D7%9C%D7%99_%D7%9E%D7%A1%D7%A4%D7%A8_%D7%94%D7%9E%D7%A0%D7%95%D7%99%D7%99%D7%9D_%D7%94%D7%92%D7%93%D7%95%D7%9C_%D7%91%D7%99%D7%95%D7%AA%D7%A8",
    "hi": "https://hi.wikipedia.org/wiki/%E0%A4%B8%E0%A4%B0%E0%A5%8D%E0%A4%B5%E0%A4%BE%E0%A4%A7%E0%A4%BF%E0%A4%95_%E0%A4%B8%E0%A4%A6%E0%A4%B8%E0%A5%8D%E0%A4%AF%E0%A4%A4%E0%A4%BE_%E0%A4%B5%E0%A4%BE%E0%A4%B2%E0%A5%87_%E0%A4%AF%E0%A5%82%E0%A4%9F%E0%A5%8D%E0%A4%AF%E0%A5%82%E0%A4%AC_%E0%A4%9A%E0%A5%88%E0%A4%A8%E0%A4%B2%E0%A5%8B%E0%A4%82_%E0%A4%95%E0%A5%80_%E0%A4%B8%E0%A5%82%E0%A4%9A%E0%A5%80",
    "hr": "https://hr.wikipedia.org/wiki/Dodatak:Popis_najpopularnijih_YouTube_kanala",
    "hu": "https://hu.wikipedia.org/wiki/A_legt%C3%B6bb_feliratkoz%C3%B3val_rendelkez%C5%91_YouTube-csatorn%C3%A1k",
    "id": "https://id.wikipedia.org/wiki/Daftar_kanal_YouTube_paling_banyak_dilanggani",
    "ja": "https://ja.wikipedia.org/wiki/%E7%99%BB%E9%8C%B2%E8%80%85%E6%95%B0%E3%81%AE%E5%A4%9A%E3%81%84YouTube%E3%83%81%E3%83%A3%E3%83%B3%E3%83%8D%E3%83%AB%E3%81%AE%E4%B8%80%E8%A6%A7",
    "ko": "https://ko.wikipedia.org/wiki/%EA%B5%AC%EB%8F%85%EC%9E%90%EA%B0%80_%EA%B0%80%EC%9E%A5_%EB%A7%8E%EC%9D%80_%EC%9C%A0%ED%8A%9C%EB%B8%8C_%EC%B1%84%EB%84%90_%EB%AA%A9%EB%A1%9D",
    "ms": "https://ms.wikipedia.org/wiki/Senarai_saluran_YouTube_paling_banyak_dilanggan",
    "ne": "https://ne.wikipedia.org/wiki/%E0%A4%B8%E0%A4%B0%E0%A5%8D%E0%A4%B5%E0%A4%BE%E0%A4%A7%E0%A4%BF%E0%A4%95_%E0%A4%B8%E0%A4%A6%E0%A4%B8%E0%A5%8D%E0%A4%AF%E0%A4%A4%E0%A4%BE_%E0%A4%AD%E0%A4%8F%E0%A4%95%E0%A4%BE_%E0%A4%AF%E0%A5%81%E0%A4%9F%E0%A5%8D%E0%A4%AF%E0%A5%81%E0%A4%AC_%E0%A4%9A%E0%A5%8D%E0%A4%AF%E0%A4%BE%E0%A4%A8%E0%A4%B2%E0%A4%B9%E0%A4%B0%E0%A5%82%E0%A4%95%E0%A5%8B_%E0%A4%B8%E0%A5%82%E0%A4%9A%E0%A5%80",
    "pnb": "https://pnb.wikipedia.org/wiki/%DB%8C%D9%88%D9%B9%DB%8C%D9%88%D8%A8_%D8%AF%DB%92_%D8%B3%D8%A8_%D8%AA%D9%88%DA%BA_%D9%85%D9%82%D8%A8%D9%88%D9%84_%D8%B5%D8%A7%D8%B1%D9%81%DB%8C%D9%86_%D8%AF%DB%8C_%D9%84%D8%B3%D9%B9",
    "pt": "https://pt.wikipedia.org/wiki/Lista_dos_canais_com_mais_inscritos_do_YouTube",
    "th": "https://th.wikipedia.org/wiki/%E0%B8%A3%E0%B8%B2%E0%B8%A2%E0%B8%8A%E0%B8%B7%E0%B9%88%E0%B8%AD%E0%B8%8A%E0%B9%88%E0%B8%AD%E0%B8%87%E0%B8%97%E0%B8%B5%E0%B9%88%E0%B8%A1%E0%B8%B5%E0%B8%A2%E0%B8%AD%E0%B8%94%E0%B8%95%E0%B8%B4%E0%B8%94%E0%B8%95%E0%B8%B2%E0%B8%A1%E0%B8%AA%E0%B8%B9%E0%B8%87%E0%B8%AA%E0%B8%B8%E0%B8%94%E0%B9%83%E0%B8%99%E0%B8%A2%E0%B8%B9%E0%B8%97%E0%B8%B9%E0%B8%9A",
    "tr": "https://tr.wikipedia.org/wiki/En_%C3%A7ok_abonesi_olan_YouTube_kanallar%C4%B1_listesi",
    "uk": "https://uk.wikipedia.org/wiki/%D0%A1%D0%BF%D0%B8%D1%81%D0%BE%D0%BA_%D0%BD%D0%B0%D0%B9%D0%BF%D0%BE%D0%BF%D1%83%D0%BB%D1%8F%D1%80%D0%BD%D1%96%D1%88%D0%B8%D1%85_%D0%BA%D0%B0%D0%BD%D0%B0%D0%BB%D1%96%D0%B2_%D0%BD%D0%B0_YouTube",
    "ur": "https://ur.wikipedia.org/wiki/%DB%8C%D9%88%D9%B9%DB%8C%D9%88%D8%A8_%DA%A9%DB%92_%D8%B3%D8%A8_%D8%B3%DB%92_%D9%85%D9%82%D8%A8%D9%88%D9%84_%D8%B5%D8%A7%D8%B1%D9%81%DB%8C%D9%86_%DA%A9%DB%8C_%D9%81%DB%81%D8%B1%D8%B3%D8%AA",
    "vi": "https://vi.wikipedia.org/wiki/Danh_s%C3%A1ch_nh%E1%BB%AFng_k%C3%AAnh_%C4%91%C6%B0%E1%BB%A3c_%C4%91%C4%83ng_k%C3%BD_nhi%E1%BB%81u_nh%E1%BA%A5t_YouTube",
    "zh": "https://zh.wikipedia.org/wiki/%E8%AE%A2%E9%98%85%E4%BA%BA%E6%95%B0%E6%9C%80%E5%A4%9A%E7%9A%84YouTube%E9%A2%91%E9%81%93",
}

OUTPUT_PATH = Path(__file__).resolve().parent / "feed_discovery" / "data" / "youtube_channels_wikipedia.json"

# ── URL patterns ─────────────────────────────────────────────────────────────
RE_CHANNEL_ID = re.compile(r"/channel/(UC[\w-]{22})")
RE_HANDLE = re.compile(r"/@([\w.-]+)")
RE_USER = re.compile(r"/user/([\w.-]+)")
RE_CHANNEL_ID_META = re.compile(r'"channelId"\s*:\s*"(UC[\w-]{22})"')
RE_CANONICAL_CHANNEL = re.compile(r'youtube\.com/channel/(UC[\w-]{22})')

# Text patterns that indicate a link is NOT a channel entry (multi-language)
NOISE_NAMES: set[str] = {
    # English
    "youtube", "channel", "www.youtube.com", "link", "here", "source",
    "watch", "video", "playlist", "subscription", "subscribe",
    # Japanese
    "公式", "リンク", "チャンネル", "アーカイブ", "オリジナル",
    # Korean
    "공식", "링크", "채널", "유튜브 채널", "유튜브", "원본 문서",
    # Other
    "official", "canal", "canale", "kênh", "kanál", "saluran",
    "kanalas", "канал",
    # Czech/Slovak
    "dostupné online", "dostupné",
    # Malay/Indonesian
    "yang asal",
}
# Names that look like table headers
HEADER_NAMES: set[str] = {
    "name", "channel", "link", "rank", "#", "no.", "posição", "posici",
    "rang", "順位", "순위", "排名", "canal", "kênh", "saluran", "chaîne",
    "kanal", "канал", "nome", "nombre",
}


def is_channel_url(url: str) -> bool:
    """True if URL is a YouTube channel page (not video, playlist, etc.)."""
    parsed = urlparse(url)
    if "youtube.com" not in parsed.netloc:
        return False
    path = parsed.path.rstrip("/")

    # Excluded: sub-pages of channels
    if path.endswith("/about") or path.endswith("/videos") or \
       path.endswith("/shorts") or path.endswith("/playlists") or \
       path.endswith("/community") or path.endswith("/channels") or \
       path.endswith("/featured"):
        return False

    # Always accept /channel/UC... URLs
    if RE_CHANNEL_ID.search(path):
        return True
    # Always accept /@handle URLs
    if RE_HANDLE.search(path):
        return True
    # Always accept /user/name URLs
    if RE_USER.search(path):
        return True

    # Excluded path prefixes (non-channel pages)
    excluded_prefixes = ("/watch", "/playlist", "/shorts/", "/results",
                         "/feed", "/redirect", "/c/", "/gaming/", "/live/",
                         "/post", "/hashtag/")
    for ex in excluded_prefixes:
        if path.startswith(ex):
            return False

    # Excluded exact paths
    if path in ("", "/", "/watch", "/playlist", "/shorts", "/results",
                "/feed", "/redirect", "/c", "/channel"):
        return False

    # Accept custom URLs like youtube.com/PewDiePie
    return "/" not in path.lstrip("/")


def clean_url(url: str) -> str:
    """Normalize YouTube URL: strip tracking params, unify domain."""
    parsed = urlparse(url)
    # Normalize mobile domain
    netloc = parsed.netloc.replace("m.youtube.com", "www.youtube.com")
    # Strip query params for channel URLs
    path = parsed.path.rstrip("/")
    return f"https://{netloc}{path}"


def parse_url_info(url: str) -> dict:
    """Extract channel_id, handle, user from a YouTube URL."""
    m = RE_CHANNEL_ID.search(url)
    if m:
        return {"channel_id": m.group(1), "handle": None, "user": None}
    m = RE_HANDLE.search(url)
    if m:
        return {"channel_id": None, "handle": m.group(1), "user": None}
    m = RE_USER.search(url)
    if m:
        return {"channel_id": None, "handle": None, "user": m.group(1)}
    # Custom URL like youtube.com/PewDiePie
    parsed = urlparse(url)
    path = parsed.path.strip("/")
    if path and "/" not in path:
        return {"channel_id": None, "handle": path, "user": None}
    return {"channel_id": None, "handle": None, "user": None}


def _clean_name(name: str) -> str:
    """Clean up a channel name: remove suffixes like ' - About', ' - YouTube channel'."""
    name = re.sub(r'\s*[–\-—]\s*(About|YouTube channel|YouTube|channel)\s*$', '', name, flags=re.IGNORECASE)
    return name.strip()


def _is_noise_name(name: str) -> bool:
    """Check if a name looks like a non-channel text."""
    clean = name.strip().lower()
    if clean in NOISE_NAMES:
        return True
    # Pure numbers or single chars are noise
    if re.match(r'^\d+$', clean):
        return True
    if len(clean) <= 1:
        return True
    # Strings that are just "X.Y" like version numbers
    if re.match(r'^\d+\.\d+$', clean):
        return True
    return False


def _clean_cell_text(text: str) -> str:
    """Clean up a table cell's text: remove citations, extra whitespace."""
    text = re.sub(r'\[\d+\]', '', text)
    text = re.sub(r'\s+', ' ', text)
    return text.strip()


def _find_name_column(cells: list, yt_col: int) -> int:
    """Given table cells and the column with YT links, find the best name column."""
    # Try common patterns
    for idx in range(len(cells)):
        if idx == yt_col:
            continue
        text = cells[idx].get_text(strip=True).lower()
        # Skip rank/position columns
        if text in HEADER_NAMES:
            continue
        # Skip subscriber count, date columns
        if any(kw in text for kw in ("subscri", "million", "data", "date", "joined",
                                        "category", "language", "country", "primary",
                                        "content", "idioma", "inscritos", "inscriti",
                                        "登録者", "구독자", "订阅", "ngôn ngữ", "quốc gia",
                                        "rede", "network", "categoria", "thể loại")):
            continue
    # Return the first non-noise, non-rank column before yt_col, or after
    for idx in range(len(cells)):
        if idx == yt_col:
            continue
        text = cells[idx].get_text(strip=True)
        if text and not _is_noise_name(text) and text.lower() not in HEADER_NAMES:
            # Prefer columns before the YT link column
            return idx
    return 0  # fallback


def extract_channel_name(a_tag, row_cells: list | None = None) -> str:
    """Extract the best channel name from context.

    Strategies (in order):
    1. If we have row cells, find the non-noise cell in the same row
    2. Link text if it's not a noise word
    3. Link title attribute
    4. Parent text context (references style)
    """
    # Strategy 1: Row-based - find a good cell in the same row
    if row_cells:
        for cell in row_cells:
            text = cell.get_text(strip=True)
            text = _clean_cell_text(text)
            if text and not _is_noise_name(text) and len(text) > 1:
                return text

    # Strategy 2: Link text
    link_text = a_tag.get_text(strip=True)
    link_text = link_text.strip('«»"\'')
    link_text = _clean_cell_text(link_text)
    if link_text and not _is_noise_name(link_text):
        return link_text

    # Strategy 3: Title attribute
    title = a_tag.get("title", "").strip()
    if title and not _is_noise_name(title):
        return title

    # Strategy 4: Parent context (references style: "«Channel».YouTube.")
    parent = a_tag.parent
    if parent:
        parent_text = parent.get_text(strip=True)
        m = re.search(r'«([^»]+)»', parent_text)
        if m:
            return m.group(1)

    return link_text or "Unknown"


def scrape_page(lang: str, url: str) -> list[dict]:
    """Scrape all YouTube channel links from a Wikipedia page (full page scan)."""
    channels = []
    print(f"  [{lang}] {url}", file=sys.stderr)

    try:
        resp = requests.get(url, timeout=30, headers={"User-Agent": "feedmine/1.0"})
        resp.raise_for_status()
    except Exception as e:
        print(f"  [{lang}] ❌ HTTP error: {e}", file=sys.stderr)
        return channels

    soup = BeautifulSoup(resp.text, "html.parser")

    # Remove navboxes, infoboxes, references list to reduce noise
    for noise in soup.find_all(class_=["navbox", "navbox-inner", "nowraplinks",
                                         "mw-collapsible", "infobox",
                                         "metadata", "ambox", "sidebar"]):
        noise.decompose()

    # ── Pass 1: Build URL → name map from ALL wikitables ─────────────────
    # Scan every cell in every row for YouTube links, use best adjacent cell as name
    row_name_map: dict[str, str] = {}

    for table in soup.find_all("table", class_="wikitable"):
        for row in table.find_all("tr"):
            cells = row.find_all(["td", "th"])
            if len(cells) < 2:
                continue

            # Find which cells have YouTube links
            yt_cells: list[int] = []
            for i, cell in enumerate(cells):
                for a_tag in cell.find_all("a", href=True):
                    href = a_tag["href"].strip()
                    if "youtube.com" in href and is_channel_url(href):
                        yt_cells.append(i)
                        break

            if not yt_cells:
                continue

            # For each YT cell, find the best name cell in this row
            for yt_idx in yt_cells:
                # Find a good name cell
                best_name = None
                for other_idx in range(len(cells)):
                    if other_idx == yt_idx:
                        continue
                    text = cells[other_idx].get_text(strip=True)
                    text = _clean_cell_text(text)
                    if text and not _is_noise_name(text) and text.lower() not in HEADER_NAMES:
                        # Skip cells that look like subscriber counts or dates
                        if re.match(r'^\d[\d,.]*$', text):
                            continue
                        best_name = text
                        break

                if best_name:
                    for a_tag in cells[yt_idx].find_all("a", href=True):
                        href = a_tag["href"].strip()
                        if "youtube.com" in href and is_channel_url(href):
                            clean = clean_url(href)
                            # Only set if not already set, or if new name is better
                            if clean not in row_name_map or len(best_name) > len(row_name_map[clean]):
                                row_name_map[clean] = best_name

    # ── Pass 2: Full page scan ──────────────────────────────────────────
    seen_urls: set[str] = set()

    for a_tag in soup.find_all("a", href=True):
        href = a_tag["href"].strip()

        if href.startswith("//"):
            href = "https:" + href

        if "youtube.com" not in href:
            continue

        if not is_channel_url(href):
            continue

        clean = clean_url(href)
        if clean in seen_urls:
            continue
        seen_urls.add(clean)

        # Get name: prefer table-derived name, then fall back
        if clean in row_name_map:
            channel_name = _clean_name(row_name_map[clean])
        else:
            # Try context from table row
            row = a_tag.find_parent("tr")
            row_cells = row.find_all(["td", "th"]) if row else None
            channel_name = _clean_name(extract_channel_name(a_tag, row_cells))

        if _is_noise_name(channel_name):
            continue

        info = parse_url_info(clean)
        channels.append({
            "channel_name": channel_name,
            "channel_url": clean,
            "channel_id": info["channel_id"],
            "handle": info["handle"],
            "user": info["user"],
            "source": f"wikipedia:{lang}",
            "wiki_lang": lang,
        })

    print(f"  [{lang}] ✓ {len(channels)} channels", file=sys.stderr)
    return channels


def resolve_channel_id(identifier: str) -> str | None:
    """Resolve a @handle or /user/name to channel ID via page scraping."""
    if identifier.startswith("UC") and len(identifier) == 24:
        return identifier  # Already a channel ID

    # Try @handle first, then /user/
    for url_tpl in [f"https://www.youtube.com/@{identifier}",
                     f"https://www.youtube.com/user/{identifier}"]:
        try:
            resp = requests.get(url_tpl, timeout=15,
                              headers={"User-Agent": "feedmine/1.0"})
            if resp.status_code != 200:
                continue
            m = RE_CHANNEL_ID_META.search(resp.text)
            if m:
                return m.group(1)
            m = RE_CANONICAL_CHANNEL.search(resp.text)
            if m:
                return m.group(1)
        except Exception:
            continue

    return None


def build_feed_url(ch: dict) -> str | None:
    cid = ch.get("channel_id")
    return f"https://www.youtube.com/feeds/videos.xml?channel_id={cid}" if cid else None


def main():
    resolve_mode = "--resolve" in sys.argv

    all_channels: list[dict] = []
    stats: dict[str, int] = {}

    print(f"Scraping {len(WIKI_PAGES)} Wikipedia language editions...", file=sys.stderr)
    print("=" * 60, file=sys.stderr)

    for lang, url in WIKI_PAGES.items():
        channels = scrape_page(lang, url)
        stats[lang] = len(channels)
        all_channels.extend(channels)
        if lang != list(WIKI_PAGES.keys())[-1]:
            time.sleep(0.3)

    print("=" * 60, file=sys.stderr)
    print(f"Raw scraped: {len(all_channels)} channels across all languages", file=sys.stderr)

    # ── Deduplicate & merge sources ──────────────────────────────────────────
    by_cid: dict[str, dict] = {}   # keyed by channel_id
    by_handle: dict[str, dict] = {}  # keyed by handle (lower)
    no_id: list[dict] = []

    for ch in all_channels:
        cid = ch.get("channel_id")
        handle = (ch.get("handle") or "").lower()
        user = (ch.get("user") or "").lower()

        if cid:
            if cid in by_cid:
                existing = by_cid[cid]
                if ch["wiki_lang"] not in existing["wiki_langs"]:
                    existing["wiki_langs"].append(ch["wiki_lang"])
                    existing["sources"].append(ch["source"])
                # Keep better name (longer, non-noise)
                if len(ch["channel_name"]) > len(existing["channel_name"]):
                    existing["channel_name"] = ch["channel_name"]
            else:
                ch["wiki_langs"] = [ch["wiki_lang"]]
                ch["sources"] = [ch["source"]]
                by_cid[cid] = ch
        elif handle and handle not in ("", "youtube", "channel"):
            if handle in by_handle:
                existing = by_handle[handle]
                if ch["wiki_lang"] not in existing["wiki_langs"]:
                    existing["wiki_langs"].append(ch["wiki_lang"])
                    existing["sources"].append(ch["source"])
                if len(ch["channel_name"]) > len(existing["channel_name"]):
                    existing["channel_name"] = ch["channel_name"]
            else:
                ch["wiki_langs"] = [ch["wiki_lang"]]
                ch["sources"] = [ch["source"]]
                by_handle[handle] = ch
        else:
            ch["wiki_langs"] = [ch["wiki_lang"]]
            ch["sources"] = [ch["source"]]
            no_id.append(ch)

    deduped = list(by_cid.values()) + list(by_handle.values()) + no_id

    # Add feed_url and has_channel_id
    for ch in deduped:
        ch["feed_url"] = build_feed_url(ch)
        ch["has_channel_id"] = bool(ch["channel_id"])

    print(f"After dedup: {len(deduped)} unique channels", file=sys.stderr)

    with_id = sum(1 for ch in deduped if ch["channel_id"])
    print(f"  {with_id} with channel_id, {len(deduped) - with_id} need resolution", file=sys.stderr)

    # ── Resolve handles (optional) ──────────────────────────────────────────
    if resolve_mode:
        need = [ch for ch in deduped if not ch["channel_id"]]
        if need:
            print(f"\nResolving {len(need)} channel IDs...", file=sys.stderr)
            resolved = 0
            for i, ch in enumerate(need):
                identifier = ch.get("handle") or ch.get("user") or ""
                if not identifier:
                    continue
                print(f"  [{i+1}/{len(need)}] {identifier} ...", file=sys.stderr)
                cid = resolve_channel_id(identifier)
                if cid:
                    ch["channel_id"] = cid
                    ch["feed_url"] = build_feed_url(ch)
                    ch["has_channel_id"] = True
                    resolved += 1
                    print(f"    ✓ {cid}", file=sys.stderr)
                time.sleep(0.5)
            print(f"Resolved {resolved}/{len(need)}", file=sys.stderr)

    # ── Stats ────────────────────────────────────────────────────────────────
    with_id_final = sum(1 for ch in deduped if ch["channel_id"])
    with_feed = sum(1 for ch in deduped if ch["feed_url"])

    result = {
        "metadata": {
            "source": "Wikipedia: List of most-subscribed YouTube channels",
            "total_unique_channels": len(deduped),
            "channels_with_channel_id": with_id_final,
            "channels_with_feed_url": with_feed,
            "languages_scraped": len(WIKI_PAGES),
            "languages_with_results": sum(1 for v in stats.values() if v > 0),
            "per_language_stats": stats,
            "resolve_mode": resolve_mode,
        },
        "channels": sorted(
            deduped,
            key=lambda ch: (ch.get("channel_id") or "", ch.get("handle") or ""),
        ),
    }

    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n✓ Saved to {OUTPUT_PATH}", file=sys.stderr)
    print(f"  {len(deduped)} channels, {with_id_final} with channel_id, {with_feed} with feed_url", file=sys.stderr)


if __name__ == "__main__":
    main()
