# National Podcast & YouTube Discovery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Discover genuinely national podcasts (iTunes Search API) and YouTube channels (DDG search + channel scrape) for a country and emit their real feed URLs into the existing per-country OPML, keyless and strictly nationality-filtered.

**Architecture:** A new `scripts/feed_discovery/sources/` submodule holds two discovery functions with a shared async interface. `process_country` routes the `Podcasts` and `YouTube` categories to them; the other 24 categories keep the existing DDG-crawl path. All candidates join the same list and reuse the existing liveness-verify → OPML → report stages. Testable logic lives in pure functions; async wrappers only do HTTP + cache.

**Tech Stack:** Python ≥3.10, aiohttp (runtime), ddgs (runtime), pytest (dev), pycountry (build-only, for ISO codes).

**Spec:** `docs/superpowers/specs/2026-07-08-national-podcast-youtube-discovery-design.md`

## Global Constraints

- Python `>=3.10`; runtime dependencies stay limited to `aiohttp>=3.9`, `ddgs>=6.0` — **no new runtime deps** (pycountry is build/dev only).
- **Keyless:** no API keys or quota anywhere.
- **No network in tests** — pure functions tested with inline fixtures; async wrappers tested via cache-hit or monkeypatch.
- **Strict nationality:** podcast kept only when iTunes `result["country"] == country.iso3`; YouTube channel kept only when About-page `country` equals `country.name` (case-insensitive).
- **Format buckets:** podcasts → category `"Podcasts"`, channels → category `"YouTube"`; genre stored as `Candidate.genre` (podcasts only; YouTube `genre=""`).
- Existing test suite (42 tests) must stay green. TDD; commit after every task.
- Run all commands from the worktree root: `/Users/wagnermontes/Documents/GitHub/feedmine/.claude/worktrees/feed-discovery`, using `.venv/bin/python` and `.venv/bin/pytest`.

## File Structure

**Create:**
- `scripts/feed_discovery/sources/__init__.py` — marks submodule.
- `scripts/feed_discovery/sources/podcasts.py` — iTunes podcast discovery (pure parse/filter/seed + async `discover`).
- `scripts/feed_discovery/sources/youtube.py` — YouTube channel discovery (pure extract/parse/seed + async `discover`).
- `scripts/feed_discovery/tests/test_podcasts.py` — podcast tests.
- `scripts/feed_discovery/tests/test_youtube.py` — YouTube tests.

**Modify:**
- `scripts/feed_discovery/models.py` — `Country` gains `iso2`, `iso3`; `Candidate` gains `genre`.
- `scripts/feed_discovery/registry.py` — `load_countries` reads `iso2`/`iso3`.
- `scripts/feed_discovery/data/build_countries.py` — emit `iso2`/`iso3` via pycountry + `CCTLD_TO_ISO2` overrides.
- `scripts/feed_discovery/data/countries.json` — regenerated (adds iso2/iso3 to every country).
- `scripts/feed_discovery/opml.py` — `emit_opml` writes optional `category="<genre>"`.
- `scripts/feed_discovery/pipeline.py` — `candidates_to_opml_map` 3-tuple; `process_country` routing.
- `scripts/feed_discovery/tests/test_pipeline.py`, `tests/test_opml.py`, `tests/test_data_coverage.py` — updated expectations.
- `pyproject.toml` — add `pycountry` to the `dev` extra.

---

### Task 1: ISO codes on `Country` + regenerated `countries.json`

**Files:**
- Modify: `scripts/feed_discovery/models.py:6-16`
- Modify: `scripts/feed_discovery/data/build_countries.py`
- Modify: `scripts/feed_discovery/registry.py:16-31`
- Modify: `pyproject.toml` (dev extra)
- Regenerate: `scripts/feed_discovery/data/countries.json`
- Test: `scripts/feed_discovery/tests/test_data_coverage.py`

**Interfaces:**
- Produces: `Country.iso2: str` (lowercase alpha-2, iTunes storefront), `Country.iso3: str` (uppercase alpha-3, iTunes result filter). Every registry country resolves both.

- [ ] **Step 1: Write the failing test** — append to `scripts/feed_discovery/tests/test_data_coverage.py`

```python
def test_every_country_has_iso2_and_iso3():
    from scripts.feed_discovery import registry
    from pathlib import Path
    data = Path(__file__).resolve().parents[1] / "data" / "countries.json"
    countries = registry.load_countries(data)
    assert countries, "no countries loaded"
    for slug, c in countries.items():
        assert len(c.iso2) == 2 and c.iso2.islower(), f"{slug}: bad iso2 {c.iso2!r}"
        assert len(c.iso3) == 3 and c.iso3.isupper(), f"{slug}: bad iso3 {c.iso3!r}"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_data_coverage.py::test_every_country_has_iso2_and_iso3 -v`
Expected: FAIL — `AttributeError: 'Country' object has no attribute 'iso2'`.

- [ ] **Step 3a: Add fields to `Country`** — `scripts/feed_discovery/models.py`, inside the `Country` dataclass after line 16 (`cities`):

```python
    iso2: str = ""
    iso3: str = ""
```

- [ ] **Step 3b: Add pycountry to dev extra** — `pyproject.toml`, in `[project.optional-dependencies]`:

```toml
dev = ["pytest>=8", "pycountry>=22"]
```

Then install it: `.venv/bin/pip install "pycountry>=22"`

- [ ] **Step 3c: Emit iso2/iso3 in the builder** — `scripts/feed_discovery/data/build_countries.py`. Add the override map and derivation, and add the two keys to the emitted dict.

At the top, after the imports (line 6), add:

```python
# ccTLD differs from ISO 3166-1 alpha-2 for a handful of countries.
CCTLD_TO_ISO2 = {"uk": "gb"}


def _iso_codes(cctld: str, slug: str) -> tuple[str, str]:
    import pycountry
    iso2 = CCTLD_TO_ISO2.get(cctld, cctld)
    rec = pycountry.countries.get(alpha_2=iso2.upper())
    if rec is None:
        raise SystemExit(f"no ISO record for {slug} (cctld={cctld}, iso2={iso2})")
    return iso2.lower(), rec.alpha_3
```

In `build()`, inside the loop, replace the `result[slug] = {...}` block so it includes the codes:

```python
        iso2, iso3 = _iso_codes(cctld, slug)
        result[slug] = {
            "name": display_name(slug),
            "native_name": native_name(slug),
            "cctld": cctld,
            "use_cctld": use_cctld,
            "lang": lang,
            "ddg_region": f"{cctld}-{lang}",
            "iso2": iso2,
            "iso3": iso3,
            "cities": CITIES.get(slug, []),
            "allowlist": [],
        }
```

- [ ] **Step 3d: Read the codes in the loader** — `scripts/feed_discovery/registry.py`, in `load_countries`, add to the `Country(...)` kwargs (after `cities=...`, line 29):

```python
            iso2=meta.get("iso2", meta["cctld"]).lower(),
            iso3=(meta.get("iso3") or "").upper(),
```

- [ ] **Step 3e: Regenerate `countries.json`**

Run: `.venv/bin/python -m scripts.feed_discovery.data.build_countries`
Expected: prints `Wrote .../countries.json with N countries` and no `SystemExit`. (If it raises "no ISO record …", add that country's ccTLD→ISO2 mapping to `CCTLD_TO_ISO2` and re-run.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_data_coverage.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/models.py scripts/feed_discovery/registry.py \
  scripts/feed_discovery/data/build_countries.py scripts/feed_discovery/data/countries.json \
  scripts/feed_discovery/tests/test_data_coverage.py pyproject.toml
git commit -m "feat(feed-discovery): iso2/iso3 country codes for platform APIs

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: `Candidate.genre` + OPML genre metadata

**Files:**
- Modify: `scripts/feed_discovery/models.py` (`Candidate`)
- Modify: `scripts/feed_discovery/pipeline.py:26-38` (`candidates_to_opml_map`)
- Modify: `scripts/feed_discovery/opml.py:21-47` (`emit_opml`)
- Test: `scripts/feed_discovery/tests/test_opml.py`, `scripts/feed_discovery/tests/test_pipeline.py`

**Interfaces:**
- Consumes: `Candidate` from Task 1's model.
- Produces: `Candidate.genre: str = ""`. `candidates_to_opml_map(...) -> dict[str, list[tuple[str, str, str]]]` (title, url, genre). `emit_opml` accepts 3-tuples and writes `category="<genre>"` on the feed outline when genre is non-empty.

- [ ] **Step 1: Write the failing tests**

Replace the two assertions in `scripts/feed_discovery/tests/test_pipeline.py` that expect 2-tuples with 3-tuples, and add a genre case. The file becomes:

```python
from __future__ import annotations

from scripts.feed_discovery.models import Candidate
from scripts.feed_discovery.pipeline import candidates_to_opml_map


def test_only_new_national_live_feeds_are_emitted():
    cands = [
        Candidate(url="https://a.br/f", category="News", title="A",
                  national=True, is_live=True, is_new=True),
        Candidate(url="https://b.br/f", category="News", title="B",
                  national=True, is_live=True, is_new=False),
        Candidate(url="https://c.com/f", category="News", title="C",
                  national=False, is_live=True, is_new=True),
        Candidate(url="https://d.br/f", category="News", title="D",
                  national=True, is_live=False, is_new=True),
    ]
    m = candidates_to_opml_map(cands)
    assert m == {"News": [("A", "https://a.br/f", "")]}


def test_untitled_feed_falls_back_to_host():
    cands = [Candidate(url="https://noticias.br/rss", category="News", title="",
                       national=True, is_live=True, is_new=True)]
    m = candidates_to_opml_map(cands)
    assert m["News"] == [("noticias.br", "https://noticias.br/rss", "")]


def test_genre_is_carried_into_the_map():
    cands = [Candidate(url="https://p.bo/feed", category="Podcasts", title="Pod",
                       genre="Historia", national=True, is_live=True, is_new=True)]
    m = candidates_to_opml_map(cands)
    assert m["Podcasts"] == [("Pod", "https://p.bo/feed", "Historia")]
```

Add to `scripts/feed_discovery/tests/test_opml.py`:

```python
def test_emit_opml_writes_genre_as_category_attr():
    from scripts.feed_discovery.opml import emit_opml
    xml = emit_opml("X", {"Podcasts": [("Pod", "https://p.bo/feed", "Historia")]}, ["Podcasts"])
    assert 'category="Historia"' in xml
    assert 'xmlUrl="https://p.bo/feed"' in xml


def test_emit_opml_omits_category_when_genre_blank():
    from scripts.feed_discovery.opml import emit_opml
    xml = emit_opml("X", {"YouTube": [("Chan", "https://www.youtube.com/feeds/videos.xml?channel_id=UCabc", "")]}, ["YouTube"])
    assert "category=" not in xml
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_pipeline.py scripts/feed_discovery/tests/test_opml.py -v`
Expected: FAIL — map returns 2-tuples; `TypeError` on unpacking / missing `category=`.

- [ ] **Step 3a: Add `genre` to `Candidate`** — `scripts/feed_discovery/models.py`, in the `Candidate` dataclass after `title: str = ""` (line 23):

```python
    genre: str = ""
```

- [ ] **Step 3b: Carry genre in `candidates_to_opml_map`** — `scripts/feed_discovery/pipeline.py`. Change the return annotation (line 26) and the append (line 37):

```python
def candidates_to_opml_map(candidates: list[Candidate]) -> dict[str, list[tuple[str, str, str]]]:
```

```python
        out.setdefault(c.category, []).append((title, c.url, c.genre))
```

- [ ] **Step 3c: Emit the attribute** — `scripts/feed_discovery/opml.py`, replace the feed-outline loop (lines 39-42):

```python
        for title, url, genre in feeds:
            attrs = f"title={quoteattr(title)} xmlUrl={quoteattr(url)} type=\"rss\""
            if genre:
                attrs += f" category={quoteattr(genre)}"
            lines.append(f"      <outline {attrs} />")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_pipeline.py scripts/feed_discovery/tests/test_opml.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/models.py scripts/feed_discovery/pipeline.py \
  scripts/feed_discovery/opml.py scripts/feed_discovery/tests/test_pipeline.py \
  scripts/feed_discovery/tests/test_opml.py
git commit -m "feat(feed-discovery): carry feed genre into OPML as category attr

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: Podcast pure logic (`sources/podcasts.py`)

**Files:**
- Create: `scripts/feed_discovery/sources/__init__.py`
- Create: `scripts/feed_discovery/sources/podcasts.py`
- Test: `scripts/feed_discovery/tests/test_podcasts.py`

**Interfaces:**
- Consumes: `Candidate`, `Country` (Tasks 1-2).
- Produces:
  - `podcast_seed_terms(country: Country) -> list[str]`
  - `itunes_search_url(term: str, iso2: str, limit: int = 50) -> str`
  - `podcasts_from_itunes_json(payload: dict, iso3: str) -> list[Candidate]`

- [ ] **Step 1: Write the failing test** — create `scripts/feed_discovery/tests/test_podcasts.py`

```python
from __future__ import annotations

from scripts.feed_discovery.models import Country
from scripts.feed_discovery.sources import podcasts

BO = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
             ["La Paz", "Santa Cruz"], iso2="bo", iso3="BOL")

PAYLOAD = {"results": [
    {"collectionName": "Historia Bolivia", "feedUrl": "https://feeds.x/h",
     "country": "BOL", "primaryGenreName": "Historia"},
    {"collectionName": "Dup", "feedUrl": "https://feeds.x/h",
     "country": "BOL", "primaryGenreName": "Historia"},          # dup feedUrl
    {"collectionName": "US Pod", "feedUrl": "https://feeds.x/us",
     "country": "USA", "primaryGenreName": "News"},              # wrong country
    {"collectionName": "No Feed", "country": "BOL"},             # no feedUrl
]}


def test_seed_terms_are_name_native_and_cities_deduped():
    assert podcasts.podcast_seed_terms(BO) == ["Bolivia", "La Paz", "Santa Cruz"]


def test_itunes_url_has_storefront_entity_and_limit():
    url = podcasts.itunes_search_url("Bolivia", "bo", 50)
    assert url.startswith("https://itunes.apple.com/search?")
    assert "term=Bolivia" in url and "country=bo" in url
    assert "entity=podcast" in url and "limit=50" in url


def test_strict_country_filter_and_dedup():
    cands = podcasts.podcasts_from_itunes_json(PAYLOAD, "BOL")
    assert [c.url for c in cands] == ["https://feeds.x/h"]
    c = cands[0]
    assert c.category == "Podcasts"
    assert c.title == "Historia Bolivia"
    assert c.genre == "Historia"
    assert c.national is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_podcasts.py -v`
Expected: FAIL — `ModuleNotFoundError: scripts.feed_discovery.sources`.

- [ ] **Step 3a: Create the submodule marker** — `scripts/feed_discovery/sources/__init__.py`:

```python
```

(empty file)

- [ ] **Step 3b: Create `scripts/feed_discovery/sources/podcasts.py`**

```python
from __future__ import annotations

from urllib.parse import urlencode

from ..models import Candidate, Country

ITUNES_SEARCH = "https://itunes.apple.com/search"


def podcast_seed_terms(country: Country) -> list[str]:
    terms = [country.name]
    if country.native_name and country.native_name != country.name:
        terms.append(country.native_name)
    terms.extend(country.cities)
    seen: set[str] = set()
    out: list[str] = []
    for t in terms:
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def itunes_search_url(term: str, iso2: str, limit: int = 50) -> str:
    q = urlencode({"term": term, "country": iso2, "entity": "podcast", "limit": limit})
    return f"{ITUNES_SEARCH}?{q}"


def podcasts_from_itunes_json(payload: dict, iso3: str) -> list[Candidate]:
    out: list[Candidate] = []
    seen: set[str] = set()
    for r in payload.get("results", []):
        if (r.get("country") or "").upper() != iso3.upper():
            continue
        feed = r.get("feedUrl")
        if not feed or feed in seen:
            continue
        seen.add(feed)
        out.append(Candidate(
            url=feed, category="Podcasts",
            title=r.get("collectionName", ""),
            genre=r.get("primaryGenreName", ""),
            national=True, national_reason="itunes country==iso3",
        ))
    return out
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_podcasts.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/sources/__init__.py scripts/feed_discovery/sources/podcasts.py \
  scripts/feed_discovery/tests/test_podcasts.py
git commit -m "feat(feed-discovery): iTunes podcast parse/filter (pure)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Podcast async `discover()` + cache

**Files:**
- Modify: `scripts/feed_discovery/sources/podcasts.py`
- Test: `scripts/feed_discovery/tests/test_podcasts.py`

**Interfaces:**
- Consumes: `podcasts_from_itunes_json`, `podcast_seed_terms`, `itunes_search_url` (Task 3); `Config` from `pipeline`.
- Produces: `async discover(country: Country, session, cfg) -> list[Candidate]`. On a non-`fresh` cache hit it never touches `session` (safe to pass `None` in tests).

- [ ] **Step 1: Write the failing test** — append to `scripts/feed_discovery/tests/test_podcasts.py`

```python
import asyncio
import json

from scripts.feed_discovery.pipeline import Config


def _safe(term: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in term)


def test_discover_reads_cache_without_network(tmp_path):
    # Single-seed-term country so exactly one cache file is needed.
    one = Country("testland", "Testland", "tl", True, "en", "tl-en", [],
                  "Testland", [], iso2="tl", iso3="TLD")
    cfg = Config(cache_dir=tmp_path, delay=0, fresh=False)
    cache = tmp_path / "itunes" / "testland" / (_safe("Testland") + ".json")
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({"results": [
        {"collectionName": "TL Pod", "feedUrl": "https://feeds.tl/p",
         "country": "TLD", "primaryGenreName": "News"},
    ]}), encoding="utf-8")

    cands = asyncio.run(podcasts.discover(one, None, cfg))
    assert [c.url for c in cands] == ["https://feeds.tl/p"]
    assert cands[0].genre == "News"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_podcasts.py::test_discover_reads_cache_without_network -v`
Expected: FAIL — `AttributeError: module ... has no attribute 'discover'`.

- [ ] **Step 3: Add `discover` + cache** — append to `scripts/feed_discovery/sources/podcasts.py`. Update the import line at the top to add the new modules:

```python
from __future__ import annotations

import json
import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate, Country
```

Then append the function:

```python
def _safe(term: str) -> str:
    return "".join(ch if ch.isalnum() else "_" for ch in term)


async def discover(country: Country, session, cfg) -> list[Candidate]:
    cands: list[Candidate] = []
    seen: set[str] = set()
    for term in podcast_seed_terms(country):
        cache_path = cfg.cache_dir / "itunes" / country.slug / (_safe(term) + ".json")
        if not cfg.fresh and cache_path.exists():
            payload = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            payload = {"results": []}
            url = itunes_search_url(term, country.iso2, 50)
            try:
                async with session.get(
                    url, timeout=aiohttp.ClientTimeout(total=cfg.timeout)
                ) as resp:
                    if resp.status == 200:
                        payload = await resp.json(content_type=None)
            except (aiohttp.ClientError, TimeoutError):
                payload = {"results": []}
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            if cfg.delay:
                time.sleep(cfg.delay)
        for c in podcasts_from_itunes_json(payload, country.iso3):
            if c.url not in seen:
                seen.add(c.url)
                cands.append(c)
    return cands
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_podcasts.py -v`
Expected: PASS (all podcast tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/sources/podcasts.py scripts/feed_discovery/tests/test_podcasts.py
git commit -m "feat(feed-discovery): async iTunes podcast discovery with cache

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: YouTube pure logic (`sources/youtube.py`)

**Files:**
- Create: `scripts/feed_discovery/sources/youtube.py`
- Test: `scripts/feed_discovery/tests/test_youtube.py`

**Interfaces:**
- Consumes: `Candidate`, `Country`.
- Produces:
  - `youtube_seed_queries(country: Country) -> list[str]`
  - `extract_channel_refs(urls: list[str]) -> list[str]` — canonical `https://www.youtube.com/<channel|@handle|c/..|user/..>` refs, deduped.
  - `parse_channel_about(html: str) -> tuple[str, str, str]` — `(channel_id, country, title)`; empty strings when absent.
  - `channel_rss_url(channel_id: str) -> str`
  - `channel_candidate_from_html(html: str, country_name: str) -> Candidate | None` — strict-filtered Candidate or None.

- [ ] **Step 1: Write the failing test** — create `scripts/feed_discovery/tests/test_youtube.py`

```python
from __future__ import annotations

from scripts.feed_discovery.models import Country
from scripts.feed_discovery.sources import youtube

BO = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
             ["La Paz", "Santa Cruz"], iso2="bo", iso3="BOL")

ABOUT_BO = (
    '<meta property="og:title" content="Canal Boliviano">'
    '{"aboutChannelViewModel":{"channelId":"UCabcdefghijklmnopqrstuv",'
    '"country":"Bolivia"}}'
)
ABOUT_US = (
    '<meta property="og:title" content="US Channel">'
    '{"aboutChannelViewModel":{"channelId":"UC00000000000000000000ab",'
    '"country":"United States"}}'
)
ABOUT_NO_COUNTRY = (
    '<meta property="og:title" content="Mystery">'
    '{"aboutChannelViewModel":{"channelId":"UC99999999999999999999zz"}}'
)


def test_seed_queries_target_youtube_with_anchors():
    qs = youtube.youtube_seed_queries(BO)
    assert "site:youtube.com Bolivia" in qs
    assert "site:youtube.com La Paz" in qs


def test_extract_channel_refs_keeps_channels_dedups_and_drops_videos():
    urls = [
        "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv",
        "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv?x=1",  # dup
        "https://m.youtube.com/@CanalBo",
        "https://www.youtube.com/watch?v=xyz",     # video: dropped
        "https://example.com/foo",                  # non-youtube: dropped
    ]
    refs = youtube.extract_channel_refs(urls)
    assert refs == [
        "https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv",
        "https://www.youtube.com/@CanalBo",
    ]


def test_parse_channel_about_extracts_id_country_title():
    cid, country, title = youtube.parse_channel_about(ABOUT_BO)
    assert cid == "UCabcdefghijklmnopqrstuv"
    assert country == "Bolivia"
    assert title == "Canal Boliviano"


def test_channel_rss_url():
    assert youtube.channel_rss_url("UCabcdefghijklmnopqrstuv") == \
        "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"


def test_candidate_kept_only_when_country_matches():
    ok = youtube.channel_candidate_from_html(ABOUT_BO, "Bolivia")
    assert ok is not None
    assert ok.url == "https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"
    assert ok.category == "YouTube" and ok.genre == "" and ok.national is True
    assert youtube.channel_candidate_from_html(ABOUT_US, "Bolivia") is None
    assert youtube.channel_candidate_from_html(ABOUT_NO_COUNTRY, "Bolivia") is None
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_youtube.py -v`
Expected: FAIL — `ModuleNotFoundError` / attribute errors.

- [ ] **Step 3: Create `scripts/feed_discovery/sources/youtube.py`**

```python
from __future__ import annotations

import re

from ..models import Candidate, Country

_CHANNEL_PATH = re.compile(
    r"youtube\.com/(channel/UC[0-9A-Za-z_-]{22}|@[A-Za-z0-9._-]+|c/[^/?#\s\"']+|user/[^/?#\s\"']+)"
)
_CHANNEL_ID = re.compile(r'"channelId":"(UC[0-9A-Za-z_-]{22})"')
_COUNTRY = re.compile(r'"country":"([^"]{1,60})"')
_OG_TITLE = re.compile(r'<meta property="og:title" content="([^"]*)"')


def youtube_seed_queries(country: Country) -> list[str]:
    qs = [f"site:youtube.com {country.name}"]
    if country.native_name and country.native_name != country.name:
        qs.append(f"site:youtube.com {country.native_name}")
    for city in country.cities[:2]:
        qs.append(f"site:youtube.com {city}")
    seen: set[str] = set()
    out: list[str] = []
    for q in qs:
        if q not in seen:
            seen.add(q)
            out.append(q)
    return out


def extract_channel_refs(urls: list[str]) -> list[str]:
    refs: list[str] = []
    seen: set[str] = set()
    for u in urls:
        m = _CHANNEL_PATH.search(u)
        if not m:
            continue
        ref = "https://www.youtube.com/" + m.group(1)
        if ref not in seen:
            seen.add(ref)
            refs.append(ref)
    return refs


def about_url(ref: str) -> str:
    return ref.rstrip("/") + "/about"


def parse_channel_about(html: str) -> tuple[str, str, str]:
    cid = _CHANNEL_ID.search(html)
    country = _COUNTRY.search(html)
    title = _OG_TITLE.search(html)
    return (
        cid.group(1) if cid else "",
        country.group(1) if country else "",
        title.group(1) if title else "",
    )


def channel_rss_url(channel_id: str) -> str:
    return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"


def channel_candidate_from_html(html: str, country_name: str) -> Candidate | None:
    cid, country, title = parse_channel_about(html)
    if not cid or not country:
        return None
    if country.strip().lower() != country_name.strip().lower():
        return None
    return Candidate(
        url=channel_rss_url(cid), category="YouTube", title=title, genre="",
        national=True, national_reason="youtube about country==name",
    )
```

- [ ] **Step 4: Run test to verify it passes**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_youtube.py -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/sources/youtube.py scripts/feed_discovery/tests/test_youtube.py
git commit -m "feat(feed-discovery): YouTube channel extract/parse/filter (pure)

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: YouTube async `discover()` + cache

**Files:**
- Modify: `scripts/feed_discovery/sources/youtube.py`
- Test: `scripts/feed_discovery/tests/test_youtube.py`

**Interfaces:**
- Consumes: pure functions from Task 5; `search.search` (DDG, cached); `Config`.
- Produces: `async discover(country: Country, session, cfg) -> list[Candidate]`. Deduped by channel_id. DDG goes through `search.search` (its own cache); each channel `/about` is cached at `cache/youtube/<slug>/<channel>.json` as the parsed triple.

- [ ] **Step 1: Write the failing test** — append to `scripts/feed_discovery/tests/test_youtube.py`

```python
import asyncio

from scripts.feed_discovery.pipeline import Config


def test_discover_uses_cached_ddg_and_about(tmp_path, monkeypatch):
    # Stub DDG: one channel URL surfaced, no network.
    monkeypatch.setattr(
        youtube.search, "search",
        lambda *a, **k: ["https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv"],
    )
    cfg = Config(cache_dir=tmp_path, delay=0, fresh=False)
    # Pre-write the parsed /about cache for that channel.
    ch_cache = tmp_path / "youtube" / "bolivia" / "channel_UCabcdefghijklmnopqrstuv.json"
    ch_cache.parent.mkdir(parents=True, exist_ok=True)
    ch_cache.write_text(
        '{"channel_id": "UCabcdefghijklmnopqrstuv", "country": "Bolivia", "title": "Canal Bo"}',
        encoding="utf-8",
    )
    cands = asyncio.run(youtube.discover(BO, None, cfg))
    assert [c.url for c in cands] == \
        ["https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"]
    assert cands[0].category == "YouTube"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_youtube.py::test_discover_uses_cached_ddg_and_about -v`
Expected: FAIL — `AttributeError: ... has no attribute 'discover'`.

- [ ] **Step 3: Add `discover` + cache** — update the imports at the top of `scripts/feed_discovery/sources/youtube.py`:

```python
from __future__ import annotations

import json
import re

import aiohttp

from .. import search
from ..models import Candidate, Country
```

Append the helpers + `discover`:

```python
_BROWSER_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"


def _channel_slug(ref: str) -> str:
    tail = ref.rstrip("/").split("youtube.com/", 1)[-1]
    return "".join(ch if ch.isalnum() else "_" for ch in tail)


async def discover(country: Country, session, cfg) -> list[Candidate]:
    # --- DDG seed: collect youtube channel refs (search.search is cached) ---
    urls: list[str] = []
    for qi, query in enumerate(youtube_seed_queries(country)):
        cache_path = cfg.cache_dir / "search" / country.slug / "YouTube" / f"{qi}.json"
        urls.extend(search.search(
            query, country.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
        ))
    refs = extract_channel_refs(urls)

    # --- Resolve + read About per channel (cached as parsed triple) ---
    cands: list[Candidate] = []
    seen_ids: set[str] = set()
    for ref in refs:
        cache_path = cfg.cache_dir / "youtube" / country.slug / (_channel_slug(ref) + ".json")
        if not cfg.fresh and cache_path.exists():
            triple = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            cid = country_field = title = ""
            try:
                async with session.get(
                    about_url(ref), headers={"User-Agent": _BROWSER_UA},
                    timeout=aiohttp.ClientTimeout(total=cfg.timeout),
                ) as resp:
                    if resp.status == 200:
                        cid, country_field, title = parse_channel_about(await resp.text())
            except (aiohttp.ClientError, TimeoutError):
                pass
            triple = {"channel_id": cid, "country": country_field, "title": title}
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(triple, ensure_ascii=False), encoding="utf-8")

        cid = triple.get("channel_id", "")
        country_field = triple.get("country", "")
        if not cid or cid in seen_ids:
            continue
        if country_field.strip().lower() != country.name.strip().lower():
            continue
        seen_ids.add(cid)
        cands.append(Candidate(
            url=channel_rss_url(cid), category="YouTube",
            title=triple.get("title", ""), genre="",
            national=True, national_reason="youtube about country==name",
        ))
    return cands
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_youtube.py -v`
Expected: PASS (all YouTube tests).

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/sources/youtube.py scripts/feed_discovery/tests/test_youtube.py
git commit -m "feat(feed-discovery): async YouTube channel discovery with cache

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 7: Route `Podcasts` / `YouTube` in `process_country`

**Files:**
- Modify: `scripts/feed_discovery/pipeline.py:57-132`
- Test: `scripts/feed_discovery/tests/test_pipeline.py`

**Interfaces:**
- Consumes: `sources.podcasts.discover`, `sources.youtube.discover` (Tasks 4, 6).
- Produces: `process_country` dispatches `Podcasts`→`podcasts.discover` and `YouTube`→`youtube.discover`, appends their (already national/live-intended) candidates after running them through the same liveness verify as other categories; every other category is unchanged.

- [ ] **Step 1: Write the failing test** — append to `scripts/feed_discovery/tests/test_pipeline.py`

```python
import asyncio

from scripts.feed_discovery import pipeline
from scripts.feed_discovery.models import Country


def test_process_country_routes_podcasts_and_youtube(monkeypatch):
    bo = Country("bolivia", "Bolivia", "bo", True, "es", "bo-es", [], "Bolivia",
                 [], iso2="bo", iso3="BOL")

    async def fake_pod(country, session, cfg):
        return [Candidate(url="https://feeds.x/p", category="Podcasts", title="P",
                          genre="Historia", national=True, is_new=True)]

    async def fake_yt(country, session, cfg):
        return [Candidate(url="https://www.youtube.com/feeds/videos.xml?channel_id=UCx",
                          category="YouTube", title="C", national=True, is_new=True)]

    async def fake_verify(session, url, timeout):
        return (True, 200, "verified-title")

    monkeypatch.setattr(pipeline.podcasts, "discover", fake_pod)
    monkeypatch.setattr(pipeline.youtube, "discover", fake_yt)
    monkeypatch.setattr(pipeline.verify, "verify_feed", fake_verify)

    cfg = pipeline.Config(delay=0)
    cands = asyncio.run(pipeline.process_country(
        bo, ["Podcasts", "YouTube"], {}, set(), set(), None, cfg))
    by_cat = {c.category: c for c in cands if c.is_live}
    assert by_cat["Podcasts"].url == "https://feeds.x/p"
    assert by_cat["Podcasts"].genre == "Historia"
    assert by_cat["YouTube"].url.endswith("channel_id=UCx")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/test_pipeline.py::test_process_country_routes_podcasts_and_youtube -v`
Expected: FAIL — `AttributeError: module 'pipeline' has no attribute 'podcasts'`.

- [ ] **Step 3a: Import the sources** — `scripts/feed_discovery/pipeline.py`, add to the imports (after line 10 `from . import discover, search, verify`):

```python
from .sources import podcasts, youtube
```

- [ ] **Step 3b: Route the two categories** — in `process_country`, at the very top of the `for category in categories:` loop (before the `# --- Search` comment, line 71), insert:

```python
        if category in ("Podcasts", "YouTube"):
            fn = podcasts.discover if category == "Podcasts" else youtube.discover
            sourced = await fn(country, session, cfg)
            to_verify: list[Candidate] = []
            for cand in sourced:
                norm = normalize_url(cand.url)
                if norm in seen_feed_urls:
                    continue
                seen_feed_urls.add(norm)
                cand.is_new = norm not in existing_urls
                if not cand.is_new:
                    candidates.append(cand)
                    continue
                to_verify.append(cand)
            verdicts = await _bounded_gather(
                cfg.concurrency,
                [verify.verify_feed(session, c.url, cfg.timeout) for c in to_verify],
            )
            for cand, (is_live, status, title) in zip(to_verify, verdicts):
                cand.is_live, cand.status_code = is_live, status
                if title:
                    cand.title = title
                candidates.append(cand)
            continue
```

Note: this reuses the existing `seen_feed_urls`, `existing_urls`, `_bounded_gather`, and `verify.verify_feed` already in scope. `cand.title` is only overwritten when the feed yields a non-empty title, preserving the iTunes `collectionName` otherwise.

- [ ] **Step 4: Run the full suite to verify pass + no regressions**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/ -v`
Expected: PASS — all prior tests plus the new routing test.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/pipeline.py scripts/feed_discovery/tests/test_pipeline.py
git commit -m "feat(feed-discovery): route Podcasts/YouTube to platform sources

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 8: End-to-end bolivia validation (checkpoint, not a unit test)

**Files:** none (runs the CLI, inspects output).

**Interfaces:** Consumes the whole pipeline wired in Tasks 1-7.

- [ ] **Step 1: Full test suite green**

Run: `.venv/bin/pytest scripts/feed_discovery/tests/ -q`
Expected: all tests pass (≥ the original 42 + the new ones).

- [ ] **Step 2: Run discovery for only the two new categories on bolivia**

Run:
```bash
.venv/bin/python -u -m scripts.feed_discovery --country bolivia \
  --category Podcasts --category YouTube --fresh --delay 1
```
Expected: exits 0; prints `[bolivia] new national feeds: N → .../candidates/bolivia.opml`.

- [ ] **Step 3: Inspect the two buckets against the quality bar**

Run:
```bash
.venv/bin/python - <<'PY'
import xml.etree.ElementTree as ET
root = ET.fromstring(open("scripts/feed_discovery/candidates/bolivia.opml", encoding="utf-8").read())
for cat in root.iter("outline"):
    if cat.get("text") in ("Podcasts", "YouTube"):
        feeds = cat.findall("outline")
        print(f"\n{cat.get('text')} ({len(feeds)})")
        for f in feeds:
            print(" ", (f.get("title") or "")[:45], "|", f.get("category") or "", "|", f.get("xmlUrl"))
PY
```
Expected quality bar (manual judgment):
- **Podcasts:** every `xmlUrl` is a real podcast RSS (feeds host / Apple / Anchor / Spotify-for-podcasters), NOT a `.bo` blog `/feed/`. `category=` (genre) present.
- **YouTube:** every `xmlUrl` is `youtube.com/feeds/videos.xml?channel_id=UC…`; each channel's About page lists Bolivia (spot-check 2-3 by opening `…/about`).

- [ ] **Step 4: Report the result to the user** (feeds found per bucket, any surprises) and stop for review before running more countries. Do NOT commit `candidates/` output (it's git-ignored / not source).

## Self-Review

**1. Spec coverage:**
- Keyless sources → Tasks 3-6 (iTunes; DDG+scrape). ✓
- Bucketing format + genre metadata → Task 2 (genre in OPML), Tasks 3/5 (category="Podcasts"/"YouTube", genre set for podcasts, "" for YouTube). ✓
- Strict nationality → Task 3 (`country==iso3`), Task 5/6 (`country==name`). ✓
- Integration into `process_country`, single OPML/report → Task 7. ✓
- Data model (`iso2`/`iso3`, `genre`, OPML attr) → Tasks 1-2. ✓
- Caching + `--fresh`, fail-safe error handling → Tasks 4, 6 (try/except → empty results; per-item skip). ✓
- Testing with fixtures, no network → every task; Task 8 e2e. ✓
- Coverage limitation (term-bounded podcasts) → inherent in Task 3 seed terms; no code owed.

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code; every command has expected output. ✓

**3. Type consistency:** `candidates_to_opml_map` returns `list[tuple[str,str,str]]` (Task 2) and `emit_opml` unpacks `title, url, genre` (Task 2) — consistent. `discover(country, session, cfg) -> list[Candidate]` identical in Tasks 4, 6, and called that way in Task 7. `parse_channel_about -> (channel_id, country, title)` used consistently in Task 5 tests and Task 6 `discover`. `Country(... iso2=, iso3=)` kwargs (Task 1) used in all test constructors. ✓
