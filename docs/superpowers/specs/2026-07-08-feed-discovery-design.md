# National Feed Discovery — Design Spec

**Date:** 2026-07-08
**Context:** feedmine iOS app — each of the 101 countries under `feedmine/Resources/Feeds/countries/<country>/<country>.opml` needs a curated set of **national** RSS feeds organized into ~26 fixed categories. Many country files still contain international feeds (e.g. `iceland.opml` has BBC, TechCrunch, Marca and only one real Icelandic feed). We want a repeatable tool that discovers candidate national feeds per country/category for human review before inclusion.

## Overview

A Python pipeline (`scripts/feed_discovery/`) that, per country, runs five stages — **search → autodiscover → national-filter → liveness-verify → emit** — and writes a ready-to-review `<country>.opml` into a separate staging folder plus a summary report. It never touches the app's real OPML files. It reuses the existing `feedmine_verify` package (`scanner`, `checker`, `verifiers`) for OPML parsing and async feed validation, and uses DuckDuckGo (via the `ddgs` library, no API key) for discovery.

## Locked design decisions

| Decision | Choice |
|---|---|
| Discovery method | Web search → script verifies |
| Search provider | DuckDuckGo via `ddgs` (free, no key) |
| National heuristic | Moderate: country ccTLD **+** per-country `.com` allowlist **+** global international blocklist; countries without a used ccTLD (e.g. USA/`.us`) fall back to language + allowlist |
| Output | Ready-to-review `<country>.opml` in a separate staging folder (`candidates/`) + summary report. Real app files untouched |
| Existing feeds | Propose **only new** feeds (dedup against all `xmlUrl` already present in the country's OPML files) |
| Scope | National files only for now (101 `<country>.opml`); architecture supports regional files later via `--include-regions` |
| Categories | Attempt all ~26 categories nationally (including Apple/Programming/YouTube); low national yield is acceptable and shown in the report |
| Keyword packs | Localized category keywords for the main languages our countries use + English fallback |
| Rollout | Pilot on `iceland` first, then `--all` |

## Goals / Non-goals

**Goals**
- Produce, per country, a reviewable OPML of **new, live, national** feeds grouped by category.
- Be resumable (stop/restart safe) and polite to DuckDuckGo (rate-limited, cached).
- Keep the national-filter logic a pure, unit-tested function.
- Reuse `feedmine_verify` rather than reimplement HTTP/feed validation.

**Non-goals (for now)**
- Regional/state files (`<country>-<region>.opml`) — architected for, not enabled.
- Writing directly into the app's real OPML files (review is manual).
- Perfect language detection or exhaustive per-language keyword coverage.

## Architecture

```
scripts/feed_discovery/
├── __init__.py
├── __main__.py          # python -m feed_discovery
├── cli.py               # argparse, dispatch, orchestration loop
├── search.py            # DuckDuckGo query builder + ddgs wrapper + on-disk cache + rate limit
├── discover.py          # fetch HTML, autodiscover feed URLs (<link rel=alternate> + path probes)
├── heuristic.py         # PURE national filter: ccTLD + allowlist + blocklist (+ lang fallback)
├── verify.py            # liveness + feed-validity via feedmine_verify.checker/verifiers; dedup
├── opml.py              # read existing xmlUrls (dedup source) + emit candidate OPML
├── report.py            # per-run summary report (markdown + json)
├── registry.py          # load countries + categories + keyword packs from data/
├── data/
│   ├── countries.json           # per-country: name, cctld, use_cctld, lang, ddg_region, allowlist[]
│   ├── category_keywords.json   # category -> { lang -> [query terms] }, EN fallback
│   └── blocklist.txt            # global international domains to always reject
├── cache/               # gitignored: search + discovery caches (resumability)
├── candidates/          # OUTPUT: <country>.opml review files
└── tests/               # heuristic, opml emit/dedup, query builder (pure units)
```

### Data flow (per country)

```
countries.json ─┐
                ▼
   for each category:
   [search] ddgs(region, keywords)  ──▶ result page URLs   (cached)
         │
         ▼
   [discover] fetch HTML ──▶ feed URLs   (<link rel=alternate>, path probes; cached)
         │
         ▼
   [heuristic] national? ──▶ keep ccTLD/allowlist, drop blocklist/foreign   (pure)
         │
         ▼
   [verify] live + valid feed? + not already present?  (feedmine_verify)
         │
         ▼
   [emit] group by category ──▶ candidates/<country>.opml  +  report.md/json
```

### Key architectural point — the heuristic limits, not the query

DuckDuckGo's `site:.br` (whole-ccTLD) filtering is unreliable. So search is **broad** (biased by DDG `region` + localized keywords) and the **national restriction is enforced in Stage 3** (`heuristic.py`). This matches the requirement to "use a heuristic to limit to national URLs" and avoids missing national outlets that a `site:` filter would hide.

## Stage details

**1. `search.py`** — For each `(country, category)`: build query `"{localized keywords} RSS feed"`, call `ddgs.text(query, region=ddg_region, max_results=~12)`. Returns result URLs. Wraps every call with a delay (~2s) + exponential backoff on rate-limit errors, and caches results to `cache/search/<country>/<category>.json` keyed by query so re-runs skip completed work.

**2. `discover.py`** — Each result URL is a webpage. Fetch HTML (async, via `feedmine_verify.checker`'s session or a local aiohttp session) and parse `<link rel="alternate" type="application/rss+xml"|"application/atom+xml" href=...>`. Fallback: probe common paths (`/feed/`, `/rss/`, `/rss.xml`, `/feed.xml`, `/atom.xml`, `/index.xml`). If a result URL already resolves to a feed, use it directly. Cache discovered feed URLs per page.

**3. `heuristic.py`** — Pure function `is_national(feed_url, country_meta) -> (bool, reason)`:
- Extract host; derive registrable domain (simple public-suffix-aware suffix match; `.com.br` etc. handled by `endswith('.'+cctld)`).
- ✅ if host ends with the country ccTLD.
- ✅ if registrable domain ∈ `country_meta.allowlist`.
- ❌ if registrable domain matches `blocklist.txt`.
- If `use_cctld` is false (e.g. USA): ✅ only if in allowlist or language matches and domain not in blocklist.
- Returns a reason string for the report (e.g. `cctld`, `allowlist`, `blocked`, `foreign`).

**4. `verify.py`** — For survivors: reuse `feedmine_verify.checker` + `feedmine_verify.verifiers` (depth-2: reachable + body is valid RSS/Atom XML). Extract the feed `<title>` for the OPML `title=` attribute. **Dedup**: build the set of existing `xmlUrl`s from all of the country's OPML files (national + regional, via `feedmine_verify.scanner` / `opml.py`), normalize (scheme/trailing-slash), and drop any candidate already present. Also dedup within the discovered set.

**5. `opml.py` + `report.py`** — Group surviving feeds by category and write `candidates/<country>.opml` in the **exact project format**:
```xml
<opml version="1.0">
  <head><title>Iceland Feeds (candidates)</title></head>
  <body>
    <outline text="News">
      <outline title="RÚV" xmlUrl="https://www.ruv.is/rss/frettir" type="rss" />
    </outline>
    ...
  </body>
</opml>
```
`report.py` writes `candidates/report.md` (+ `report.json`): per country/category — candidates found, kept by heuristic, rejected (with reason breakdown), live-verified, deduped-out, and final new count.

## Configuration data files

- **`data/countries.json`** — one entry per country slug (derived from the 101 folder names + a curated metadata table):
  ```json
  {
    "iceland": { "name": "Iceland", "cctld": "is", "use_cctld": true,
                 "lang": "is", "ddg_region": "is-is", "allowlist": [] },
    "usa":     { "name": "USA", "cctld": "us", "use_cctld": false,
                 "lang": "en", "ddg_region": "us-en",
                 "allowlist": ["nytimes.com", "npr.org", "cnn.com"] }
  }
  ```
- **`data/category_keywords.json`** — 26 categories → `{ lang: [terms] }` with EN fallback. Language packs cover the main languages our countries use (PT, ES, EN, FR, DE, IT, AR, RU, and a handful more); a country's `lang` selects the pack, else EN. Example: `"News": { "pt": ["notícias"], "es": ["noticias"], "en": ["news"] }`.
- **`data/blocklist.txt`** — global international domains always rejected (`bbc.co.uk`, `bbc.com`, `techcrunch.com`, `dezeen.com`, `reddit.com`, `theguardian.com`, `wired.com`, …). Note: allowlist wins over blocklist for national editions on international brands (e.g. `cnnbrasil.com.br` passes via `.br`).

## CLI interface

Mirrors `feedmine-verify` conventions (argparse, `--concurrency`, `--timeout`, `--user-agent`, `--output`).

```
python -m feed_discovery [OPTIONS]

--country SLUG        Process one country (e.g. iceland). Repeatable.
--all                 Process all 101 national files
--category NAME       Restrict to one category (repeatable)
--max-results N       DDG results per (country,category) query (default: 12)
--concurrency N       Max simultaneous HTTP requests for discover/verify (default: 50)
--timeout SECONDS     Per-request timeout (default: 15)
--delay SECONDS       Delay between DDG queries (default: 2)
--fresh               Ignore caches, re-run search/discovery
--include-regions     (future) also process <country>-<region>.opml files
--out DIR             Output dir (default: scripts/feed_discovery/candidates)
--user-agent STRING   Custom UA (default: FeedmineDiscovery/1.0)
--help
```

Examples:
```bash
python -m feed_discovery --country iceland            # pilot
python -m feed_discovery --all                        # full run (resumable)
python -m feed_discovery --country brazil --category News --fresh
```

## Resumability & politeness

- Search and discovery results are cached to `cache/` (gitignored). A killed run resumes from the last completed `(country, category)` — same idea as the existing `.loop_progress.json`.
- DDG calls are serialized with `--delay` spacing + exponential backoff on rate-limit/HTTP-429; discovery/verify HTTP is concurrent (`--concurrency`) with the `FeedmineDiscovery/1.0` UA.
- Estimated scale: 101 × ~26 ≈ 2,600 searches; search stage ~1.5–2.5h at 2s spacing; discover/verify are fast and concurrent. Run in batches via `--country`.

## Reuse of `feedmine_verify`

- `feedmine_verify.scanner` — parse country OPML files → existing `xmlUrl` set for dedup.
- `feedmine_verify.checker` — async HTTP engine (semaphore, retries) for discovery fetches and liveness checks.
- `feedmine_verify.verifiers` — depth-2 validation that a URL is a real RSS/Atom feed.
- `feedmine_verify.constants` — timeouts / UA defaults as a baseline.

## Testing

The repo has no existing Python test convention, so introduce `pytest` as a dev dependency. Unit tests (`tests/`) cover the pure/deterministic units:
- `heuristic.py`: ccTLD pass (`globo.com.br` → national via `.br`), allowlist pass, blocklist reject, foreign reject, `use_cctld=false` language fallback.
- `opml.py`: emit matches project format exactly; dedup removes existing/normalized-duplicate URLs; empty categories omitted.
- `search.py`: query builder picks correct language pack + region; EN fallback when pack missing.
Network stages (`search` live DDG, `discover`, `verify`) are validated manually via the `iceland` pilot, not in unit tests.

## Rollout plan

1. Build config data (`countries.json`, `category_keywords.json`, `blocklist.txt`) + the five modules + tests.
2. **Pilot:** `python -m feed_discovery --country iceland`; review `candidates/iceland.opml` + report for national relevance and category coverage.
3. Tune keyword packs / allowlist / blocklist based on pilot output.
4. **Full run:** `python -m feed_discovery --all` in batches; review per-country outputs and copy approved feeds into the real `<country>.opml` files manually.

## Future / open

- `--include-regions`: enable regional files, likely with a reduced category set (News/Sports/Culture) given regional feeds rarely exist for Apple/Programming/etc.
- Optional `--apply` mode to merge approved candidates into real files (deliberately out of scope now to keep discovery and curation separate).
