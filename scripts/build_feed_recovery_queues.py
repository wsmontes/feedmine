#!/usr/bin/env python3
"""Split FeedMine's disposition ledger into explicit recovery OPML queues."""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import shutil
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path
from typing import Iterable


TRANSIENT_HTTP = {408, 425, 429, 500, 502, 503, 504, 508, 520, 522, 526}
GONE_HTTP = {404, 410}
ACCESS_HTTP = {401, 403}


def clean(value: object) -> str:
    return " ".join(str(value or "").split())


def failed_queue(row: dict[str, str]) -> str:
    error = clean(row.get("last_error")).lower()
    try:
        http_status = int(row.get("http_status") or 0)
    except ValueError:
        http_status = 0
    if "parse error" in error or http_status in {200, 202, 204}:
        return "failed_parse_or_html"
    if http_status in GONE_HTTP:
        return "failed_gone_or_moved"
    if http_status in ACCESS_HTTP:
        return "failed_access_blocked"
    if http_status in TRANSIENT_HTTP:
        return "failed_transient"
    if any(token in error for token in (
        "name or service not known", "nodename nor servname", "dns",
        "certificate", "ssl", "tls", "connect", "network", "timeout",
        "temporary failure", "connection reset",
    )):
        return "failed_network"
    if not http_status and not error:
        return "failed_unknown"
    return "failed_other"


def queue_for(row: dict[str, str]) -> str | None:
    disposition = row.get("disposition")
    if disposition == "unattempted_editorial":
        return "editorial_unattempted"
    if disposition == "processed_empty":
        return "processed_empty"
    if disposition == "processed_failed":
        return failed_queue(row)
    return None


def read_ledger(path: Path) -> list[dict[str, str]]:
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def write_queue(path: Path, queue: str, rows: Iterable[dict[str, str]]) -> int:
    root = ET.Element("opml", {"version": "2.0"})
    head = ET.SubElement(root, "head")
    ET.SubElement(head, "title").text = f"FeedMine recovery — {queue.replace('_', ' ')}"
    body = ET.SubElement(root, "body")
    grouped: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        original = clean(row.get("current_file")) or "unknown"
        grouped[original.split("/", 1)[0]].append(row)
    count = 0
    for collection in sorted(grouped):
        group = ET.SubElement(body, "outline", {"text": collection, "title": collection})
        for row in sorted(grouped[collection], key=lambda item: clean(item.get("title")).casefold()):
            attrs = {
                "text": clean(row.get("title")) or clean(row.get("xml_url")),
                "title": clean(row.get("title")) or clean(row.get("xml_url")),
                "type": "rss",
                "xmlUrl": clean(row.get("xml_url")),
                "feedmineRecoveryQueue": queue,
                "feedmineDisposition": clean(row.get("disposition")),
                "feedmineOriginalFile": clean(row.get("current_file")),
            }
            optional = {
                "htmlUrl": row.get("html_url"),
                "feedmineSourceId": row.get("source_id"),
                "feedminePreviousHTTPStatus": row.get("http_status"),
                "feedminePreviousError": clean(row.get("last_error"))[:500],
                "discoverySource": row.get("discovery_source"),
                "queryLanguage": row.get("query_language"),
                "queryScope": row.get("query_scope"),
            }
            attrs.update({key: clean(value) for key, value in optional.items() if clean(value)})
            ET.SubElement(group, "outline", attrs)
            count += 1
    ET.indent(root, space="  ")
    path.parent.mkdir(parents=True, exist_ok=True)
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True, short_empty_elements=True)
    return count


def build(ledger: Path, output: Path) -> dict[str, object]:
    rows = read_ledger(ledger)
    queues: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        queue = queue_for(row)
        if queue:
            queues[queue].append(row)
    if output.exists():
        if not output.is_dir() or output.is_symlink():
            raise RuntimeError(f"refusing to replace non-directory output: {output}")
        shutil.rmtree(output)
    output.mkdir(parents=True)
    written = {
        queue: write_queue(output / queue / "queue.opml", queue, queue_rows)
        for queue, queue_rows in sorted(queues.items())
    }
    summary: dict[str, object] = {
        "ledger": str(ledger),
        "ledger_rows": len(rows),
        "queued_rows": sum(written.values()),
        "queue_counts": written,
        "excluded_counts": dict(sorted(Counter(
            row.get("disposition", "unknown") for row in rows if queue_for(row) is None
        ).items())),
    }
    (output / "queue-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--ledger", type=Path,
        default=Path("editorial/feed-curation/source-disposition-ledger.csv.gz"),
    )
    parser.add_argument(
        "--output", type=Path,
        default=Path("build/feed-recovery/queues"),
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if not args.ledger.exists():
        raise SystemExit(f"ledger not found: {args.ledger}")
    summary = build(args.ledger, args.output)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(f"Queued {summary['queued_rows']} identities across {len(summary['queue_counts'])} recovery queues")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
