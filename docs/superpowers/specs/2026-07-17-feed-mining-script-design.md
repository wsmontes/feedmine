# Feed Mining Script — Design Spec

## Purpose

Standalone Python script that downloads 20–30 articles from every RSS/Atom feed listed in the project's 4,534 OPML files, collects full text + metadata, and saves to Parquet via DuckDB.

The output feeds a local LLM (LM Studio) that will profile each source: descriptive summary, search tags, category, language, country of origin.

## Scope

- **Input:** 4,534 OPML files → ~51,946 feed URLs
- **Output:** `feeds_corpus.duckdb` (or direct Parquet export)
- **Per feed:** up to 30 articles with full text (HTML stripped)
- **Est. total articles:** ~1–1.5 million

## Architecture

```
OPMLs → [Parse] → [Async Fetch] → [DuckDB] → (optional Parquet export)
```

### Phase 1 — Parse OPMLs

Walk `feedmine/Resources/Feeds/`, parse every `.opml`:
- Extract `<outline>` elements with `xmlUrl` attribute (recursively)
- Collect: `title`, `xmlUrl`, parent outline text as subcategory, OPML `<head><title>` + `<language>`
- Merge with `opml_manifest.json` for `region` and `sources` count
- Yield ~52K `Source` records

### Phase 2 — Async Fetch

- `httpx.AsyncClient` with semaphore (50 concurrent)
- `feedparser` to parse RSS/Atom XML
- Timeout: 30s per request, 3 retries with exponential backoff (1s, 2s, 4s)
- Per article extract: `title`, `link`, `published`, `summary`, clean text from `content[0].value` (strip HTML tags via `html2text` or regex)
- Max 30 articles per feed

### Phase 3 — DuckDB Storage

#### Schema

**`sources`** table:

| Column | Type | Notes |
|---|---|---|
| source_id | INTEGER PK | auto-increment |
| source_title | VARCHAR | from OPML |
| xml_url | VARCHAR | feed URL |
| site_url | VARCHAR | from feed metadata |
| feed_title | VARCHAR | from feed `<title>` |
| feed_description | VARCHAR | from feed `<description>` |
| category | VARCHAR | top-level folder (e.g. Tech_Science) |
| subcategory | VARCHAR | parent outline text (e.g. "Tech") |
| language | VARCHAR | from OPML `<language>` |
| region | VARCHAR | global / country code |
| country | VARCHAR | country name if under countries/ |
| opml_file | VARCHAR | relative path |
| status | VARCHAR | pending / done / failed |
| error_message | VARCHAR | if failed |
| articles_fetched | INTEGER | count fetched |
| fetched_at | TIMESTAMP | when processed |

**`articles`** table:

| Column | Type | Notes |
|---|---|---|
| article_id | INTEGER PK | auto-increment |
| source_id | INTEGER FK | → sources.source_id |
| title | VARCHAR | |
| url | VARCHAR | |
| published | VARCHAR | raw date string |
| summary | VARCHAR | feed summary |
| content_text | VARCHAR | HTML stripped, full text |

### Phase 4 — Export

```sql
COPY (SELECT s.*, a.* FROM sources s JOIN articles a ON a.source_id = s.source_id)
TO 'feeds_corpus.parquet' (FORMAT PARQUET);
```

### Resumability

- Each batch commits to DuckDB immediately
- On restart, query `SELECT xml_url FROM sources WHERE status = 'done'` → skip set
- `--reset` flag drops and recreates tables

## File Structure

```
scripts/
├── fetch_all_feeds.py    # main script
└── requirements.txt      # httpx, feedparser, duckdb, tqdm, html2text
```

## Edge Cases & Error Handling

| Scenario | Handling |
|---|---|
| Feed unreachable (DNS, timeout) | Retry 3x, mark `failed` with error |
| Feed returns non-XML | Catch `feedparser` error, mark `failed` |
| Feed has < 30 articles | Take whatever is available |
| Duplicate feed URL | Skip (unique constraint on `xml_url`) |
| Empty article content | Store anyway with empty string |
| Ctrl+C mid-run | DuckDB auto-committed, resume on restart |
| OPML without language | `NULL` |
| Country OPML | Extract country name from folder path |

## Dependencies

```
httpx>=0.27
feedparser>=6.0
duckdb>=1.0
tqdm>=4.0
html2text>=2024
```

## Commands

```bash
python scripts/fetch_all_feeds.py                    # run (resumes if interrupted)
python scripts/fetch_all_feeds.py --reset             # start fresh
python scripts/fetch_all_feeds.py --limit 100         # test: 100 sources only
python scripts/fetch_all_feeds.py --export-parquet    # export DuckDB → Parquet
python scripts/fetch_all_feeds.py --concurrency 30    # lower concurrency
```
