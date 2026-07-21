#!/usr/bin/env python3
"""Enrich feed sources with AI-generated descriptions and tags via DeepSeek V4 Flash.

Reads a source parquet plus optional fetched article parts, generates short
English descriptions and tags for each feed (one API call per feed), and writes
the enriched data back to parquet with new columns:
  - ai_description  (short 1-2 sentence description in English)
  - ai_tags          (comma-separated tags in English)

Usage:
    export DEEPSEEK_API_KEY=sk-...
    python3 scripts/enrich_feed_descriptions.py                     # run (resumes)
    python3 scripts/enrich_feed_descriptions.py --limit 10          # test subset
    python3 scripts/enrich_feed_descriptions.py --reset             # fresh start
    python3 scripts/enrich_feed_descriptions.py --dry-run           # count, no API calls
"""

from __future__ import annotations

import json
import math
import os
import shutil
import signal
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import URLError
from urllib.parse import urlparse

import pyarrow as pa
import pyarrow.parquet as pq

# Signal handler state — set by enrich_parquet()
_signal_state = {"progress": {}, "df": None}

# ---------------------------------------------------------------------------
# Paths & constants
# ---------------------------------------------------------------------------

ROOT = Path(__file__).resolve().parent.parent
PARQUET_PATH = ROOT / "feeds_corpus_sources.parquet"
BACKUP_PATH = ROOT / "feeds_corpus_sources.backup.parquet"
PROGRESS_PATH = ROOT / "feeds_enrich_progress.json"
CONTENT_PARTS_DIR: Path | None = None

DEEPSEEK_MODEL = "deepseek-v4-flash"
DEEPSEEK_URL = "https://api.deepseek.com/v1/chat/completions"

MAX_TOKENS = 512
TEMPERATURE = 0.3
DELAY_BETWEEN_CALLS = 0.3
MAX_RETRIES = 4
RETRY_BASE_DELAY = 2.0

NEW_COLUMNS = ["ai_description", "ai_tags"]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def load_progress() -> dict[str, dict]:
    """Return {source_id: {ai_description, ai_tags}} for already-processed feeds."""
    if PROGRESS_PATH.exists():
        with open(PROGRESS_PATH) as f:
            return json.load(f)
    return {}


def save_progress(progress: dict[str, dict]) -> None:
    """Atomically write progress to disk."""
    tmp = PROGRESS_PATH.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(progress, f, ensure_ascii=False)
    tmp.replace(PROGRESS_PATH)


def _handle_interrupt(signum, frame):
    """Save progress on SIGTERM/SIGINT before exiting."""
    msg = f"\n⚠ Interrupted (signal {signum}) — saving progress..."
    print(msg, file=sys.stderr, flush=True)
    progress = _signal_state.get("progress", {})
    if progress:
        save_progress(progress)
        print(f"  Saved {len(progress)} entries to progress JSON", file=sys.stderr)
    sys.exit(0)


signal.signal(signal.SIGTERM, _handle_interrupt)
signal.signal(signal.SIGINT, _handle_interrupt)


def write_parquet(df) -> None:
    """Atomically write parquet while keeping the previous complete file."""
    if PARQUET_PATH.exists():
        shutil.copy2(PARQUET_PATH, BACKUP_PATH)
    new_table = pa.Table.from_pandas(df)
    temporary = PARQUET_PATH.with_name(f".{PARQUET_PATH.name}.tmp")
    pq.write_table(new_table, temporary, compression="zstd")
    os.replace(temporary, PARQUET_PATH)


def safe_text(value: object) -> str:
    """Return clean text for nullable pandas/Arrow scalar values."""
    if value is None:
        return ""
    if isinstance(value, float) and math.isnan(value):
        return ""
    text = str(value).strip()
    return "" if text.casefold() in {"nan", "none", "<na>"} else text


def load_api_key() -> str | None:
    """Get API key from env or .env file."""
    api_key = os.environ.get("DEEPSEEK_API_KEY")
    if api_key:
        return api_key
    env_path = ROOT / ".env"
    if env_path.exists():
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("DEEPSEEK_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    return None


def load_article_samples(
    parts_dir: Path | None,
    max_per_source: int = 5,
    max_chars: int = 700,
) -> dict[str, list[str]]:
    """Load bounded, content-derived samples without materializing full parts."""
    if parts_dir is None or not parts_dir.exists():
        return {}
    result: dict[str, list[str]] = {}
    columns = ["source_id", "title", "summary", "content_text", "position"]
    for path in sorted(parts_dir.glob("*.parquet")):
        parquet = pq.ParquetFile(path)
        for batch in parquet.iter_batches(columns=columns, batch_size=512):
            data = batch.to_pydict()
            for index, source_id in enumerate(data["source_id"]):
                source_id = str(source_id)
                samples = result.setdefault(source_id, [])
                if len(samples) >= max_per_source:
                    continue
                title = " ".join(str(data["title"][index] or "").split())
                body = " ".join(str(
                    data["summary"][index] or data["content_text"][index] or ""
                ).split())
                sample = " — ".join(part for part in (title, body) if part)[:max_chars]
                if sample and sample not in samples:
                    samples.append(sample)
    return result


def call_deepseek(feed: dict, api_key: str) -> dict | None:
    """Send a single feed to DeepSeek, return {ai_description, ai_tags} or None."""

    title = (feed.get("feed_title") or feed.get("source_title") or "").strip()
    desc = (feed.get("feed_description") or "").strip()
    site = (feed.get("site_url") or "").strip()

    parts = []
    if title:
        parts.append(f"Title: {title}")
    if desc:
        parts.append(f"Original description: {desc[:300]}")
    if site:
        try:
            domain = urlparse(site).netloc
            parts.append(f"Website: {domain}")
        except Exception:
            parts.append(f"Website: {site}")
    article_samples = feed.get("article_samples") or []
    if article_samples:
        parts.append("Recent article samples derived from fetched feed entries:")
        parts.extend(f"- {sample}" for sample in article_samples)

    feed_text = "\n".join(parts)

    system_prompt = (
        "You are a multilingual RSS/Atom feed curator. "
        "Given feed metadata and, when available, samples from its fetched entries, "
        "write a SHORT description "
        "(1-2 sentences) in English explaining what the feed covers, and assign "
        "3-5 relevant tags in English. "
        "Infer the real recurring subject primarily from the entry samples, not from "
        "an ambiguous feed name. If the feed is in another language, convey its topic "
        "accurately in English. "
        "Respond ONLY with a JSON object:\n"
        '{"description": "...", "tags": "tag1, tag2, tag3"}\n'
        "No markdown, no explanation — just the JSON."
    )

    user_prompt = (
        "Analyze this RSS/Atom feed and produce a short description and tags in English:\n\n"
        f"{feed_text}"
    )

    for attempt in range(MAX_RETRIES):
        try:
            body = json.dumps({
                "model": DEEPSEEK_MODEL,
                "messages": [
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_prompt},
                ],
                "temperature": TEMPERATURE,
                "max_tokens": MAX_TOKENS,
                "response_format": {"type": "json_object"},
            }).encode()

            req = Request(
                DEEPSEEK_URL,
                data=body,
                headers={
                    "Content-Type": "application/json",
                    "Authorization": f"Bearer {api_key}",
                },
            )
            resp = urlopen(req, timeout=60)
            resp_body = json.loads(resp.read().decode())
            content = resp_body["choices"][0]["message"]["content"]
            data = json.loads(content)

            return {
                "ai_description": str(data.get("description", "")).strip(),
                "ai_tags": str(data.get("tags", "")).strip(),
            }

        except (json.JSONDecodeError, KeyError) as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_BASE_DELAY * (attempt + 1))
            else:
                print(f"\n  Parse error (final): {e}", file=sys.stderr)
        except URLError as e:
            if attempt < MAX_RETRIES - 1:
                delay = RETRY_BASE_DELAY * (attempt + 1)
                print(f"\n  HTTP error, retrying in {delay:.0f}s: {e}", file=sys.stderr)
                time.sleep(delay)
            else:
                print(f"\n  HTTP error (final): {e}", file=sys.stderr)
        except Exception as e:
            if attempt < MAX_RETRIES - 1:
                time.sleep(RETRY_BASE_DELAY * (attempt + 1))
            else:
                print(f"\n  API error (final): {e}", file=sys.stderr)

    return None


def enrich_parquet(
    limit: int = 0,
    reset: bool = False,
    dry_run: bool = False,
    parts_dir: Path | None = None,
) -> None:
    """Main enrichment routine — one API call per feed."""
    # ------------------------------------------------------------------
    # 1. Read the parquet
    # ------------------------------------------------------------------
    if not PARQUET_PATH.exists():
        print(f"ERROR: {PARQUET_PATH} not found")
        sys.exit(1)

    print(f"Reading {PARQUET_PATH}...")
    table = pq.read_table(PARQUET_PATH)
    df = table.to_pandas()
    total = len(df)
    print(f"  {total} total feeds")

    # ------------------------------------------------------------------
    # 2. Determine which feeds to process
    # ------------------------------------------------------------------
    existing_cols = list(df.columns)
    for col in NEW_COLUMNS:
        if col not in existing_cols:
            df[col] = ""

    progress = {} if reset else load_progress()
    if reset:
        print("  --reset: starting fresh")
        for col in NEW_COLUMNS:
            if col in df.columns:
                df[col] = ""

    done_mask = df["status"] == "done"
    done_count = done_mask.sum()
    print(f"  {done_count} feeds with status=done")
    article_samples = load_article_samples(parts_dir)
    if parts_dir is not None:
        print(f"  Content samples available for {len(article_samples)} feeds from {parts_dir}")

    # Find feeds that still need enrichment
    needs_enrichment = []
    skipped_progress = 0
    skipped_parquet = 0
    for idx in df.index:
        if not done_mask[idx]:
            continue
        sid = df.at[idx, "source_id"]
        if isinstance(sid, float):
            sid = str(sid)
        if sid in progress and progress[sid].get("ai_description", "").strip():
            skipped_progress += 1
            # Sync progress data into dataframe in case parquet is stale
            df.at[idx, "ai_description"] = progress[sid]["ai_description"]
            df.at[idx, "ai_tags"] = progress[sid].get("ai_tags", "")
            continue
        existing_desc = df.at[idx, "ai_description"] if "ai_description" in df.columns else ""
        if isinstance(existing_desc, str) and existing_desc.strip():
            skipped_parquet += 1
            existing_tags = df.at[idx, "ai_tags"] if "ai_tags" in df.columns else ""
            progress[sid] = {
                "ai_description": existing_desc,
                "ai_tags": str(existing_tags) if existing_tags and not isinstance(existing_tags, float) else "",
            }
            continue
        needs_enrichment.append(idx)

    if skipped_progress or skipped_parquet:
        parts = []
        if skipped_progress:
            parts.append(f"{skipped_progress} from progress cache")
        if skipped_parquet:
            parts.append(f"{skipped_parquet} from existing parquet data")
        print(f"  Skipped: {', '.join(parts)}")
    print(f"  {len(needs_enrichment)} feeds need enrichment")

    if limit and limit > 0:
        needs_enrichment = needs_enrichment[:limit]
        print(f"  --limit {limit}: processing {len(needs_enrichment)} feeds")

    if not needs_enrichment:
        print("  Nothing to do!")
        return

    if dry_run:
        est_min = len(needs_enrichment) * (DELAY_BETWEEN_CALLS + 1.5) / 60
        print(f"\n  DRY-RUN: would process {len(needs_enrichment)} feeds "
              f"(~{est_min:.0f} min, one per API call)")
        return

    # Wire up signal handler globals so interrupt saves progress
    _signal_state["progress"] = progress
    _signal_state["df"] = df

    # ------------------------------------------------------------------
    # 3. Check API key
    # ------------------------------------------------------------------
    api_key = load_api_key()
    if not api_key:
        print("ERROR: DEEPSEEK_API_KEY not set (env var or .env file)")
        sys.exit(1)

    FLUSH_EVERY = 50  # write to parquet and clear progress JSON every N feeds

    # ------------------------------------------------------------------
    # 4. Process one feed per API call
    # ------------------------------------------------------------------
    total_feeds = len(needs_enrichment)
    est_min = total_feeds * (DELAY_BETWEEN_CALLS + 1.5) / 60
    print(f"\n  Processing {total_feeds} feeds (one per API call, ~{est_min:.0f} min)")
    print(f"  Flush to parquet every {FLUSH_EVERY} feeds")
    print(f"  Model: {DEEPSEEK_MODEL}\n")

    processed = 0
    failed = 0
    total_ever = skipped_progress + skipped_parquet  # already done from before
    start_time = time.time()
    batch_start_time = time.time()

    for i, idx in enumerate(needs_enrichment):
        row = df.iloc[idx]
        feed = {
            "source_id": safe_text(row["source_id"]),
            "source_title": safe_text(row["source_title"]),
            "feed_title": safe_text(row["feed_title"]),
            "feed_description": safe_text(row["feed_description"]),
            "site_url": safe_text(row["site_url"]),
            "article_samples": article_samples.get(safe_text(row["source_id"]), []),
        }

        sid = feed["source_id"]
        title_preview = (feed["feed_title"] or feed["source_title"])[:50]

        label = f"[{i + 1}/{total_feeds}]"
        print(f"  {label} {title_preview}...", end=" ", flush=True)

        result = call_deepseek(feed, api_key)

        if result is None:
            print("FAILED — will retry on next run")
            failed += 1
            save_progress(progress)
            time.sleep(2)
            continue

        desc = result.get("ai_description", "")
        tags = result.get("ai_tags", "")
        progress[sid] = {"ai_description": desc, "ai_tags": tags}

        df.at[idx, "ai_description"] = desc
        df.at[idx, "ai_tags"] = tags

        if desc.strip():
            processed += 1

        # Progress info
        elapsed = time.time() - start_time
        rate = processed / elapsed if elapsed > 0 else 0
        remaining = total_feeds - (i + 1)
        eta_min = remaining / rate / 60 if rate > 0 else 0

        desc_short = desc[:70] + "…" if len(desc) > 70 else desc
        tag_short = tags[:50] + "…" if len(tags) > 50 else tags
        print(f"✓ | batch {processed}/{failed}fail | "
              f"{rate:.1f}/s | ETA {eta_min:.0f}min | "
              f"{desc_short} | {tag_short}")

        # Flush to parquet every FLUSH_EVERY feeds and clear progress JSON
        if (i + 1) % FLUSH_EVERY == 0:
            print(f"  --- flushing {FLUSH_EVERY} feeds to parquet ---", flush=True)
            write_parquet(df)
            total_ever += processed
            print(f"  ✓ parquet updated ({total_ever} total enriched), progress JSON cleared\n")
            # Reset for next batch
            progress = {}
            save_progress(progress)
            processed = 0
            failed = 0
            start_time = time.time()

        if i < total_feeds - 1:
            time.sleep(DELAY_BETWEEN_CALLS)

    # ------------------------------------------------------------------
    # 5. Final flush — write remaining feeds to parquet
    # ------------------------------------------------------------------
    print(f"\n{'=' * 60}")
    total_ever += processed
    print(f"Batch enriched: {processed} feeds | Failed: {failed}")
    print(f"Total ever enriched: {total_ever}")

    if processed > 0:
        write_parquet(df)
        print(f"  ✓ final parquet write ({total_ever} total enriched)")
        # Clear progress since everything is in parquet
        progress = {}
        save_progress(progress)
    else:
        save_progress(progress)
        print(f"  Nothing new to flush")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main():
    import argparse
    global PARQUET_PATH, BACKUP_PATH, PROGRESS_PATH, CONTENT_PARTS_DIR
    parser = argparse.ArgumentParser(
        description="Enrich feed sources with AI-generated descriptions and tags"
    )
    parser.add_argument("--limit", type=int, default=0,
                        help="Process only N feeds (0 = all)")
    parser.add_argument("--reset", action="store_true",
                        help="Clear all progress and start fresh")
    parser.add_argument("--dry-run", action="store_true",
                        help="Count feeds to process, no API calls")
    parser.add_argument("--parquet", type=Path, default=PARQUET_PATH,
                        help="Source parquet to enrich in place")
    parser.add_argument("--backup", type=Path,
                        help="Backup path (default: <parquet>.backup.parquet)")
    parser.add_argument("--progress", type=Path,
                        help="Resume cache (default: alongside parquet)")
    parser.add_argument("--parts-dir", type=Path,
                        help="Fetched article parquet directory used as content evidence")
    args = parser.parse_args()

    PARQUET_PATH = args.parquet.resolve()
    BACKUP_PATH = (
        args.backup.resolve()
        if args.backup
        else PARQUET_PATH.with_name(f"{PARQUET_PATH.stem}.backup.parquet")
    )
    PROGRESS_PATH = (
        args.progress.resolve()
        if args.progress
        else PARQUET_PATH.with_name(f"{PARQUET_PATH.stem}.enrich-progress.json")
    )
    CONTENT_PARTS_DIR = args.parts_dir.resolve() if args.parts_dir else None

    print("=" * 60)
    print("FeedMine — Feed Description Enricher (DeepSeek V4 Flash)")
    print(f"  Started: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    print(f"  Model: {DEEPSEEK_MODEL}")
    print(f"  Mode: one feed per API call")
    print("=" * 60)
    print()

    enrich_parquet(
        limit=args.limit,
        reset=args.reset,
        dry_run=args.dry_run,
        parts_dir=CONTENT_PARTS_DIR,
    )


if __name__ == "__main__":
    main()
