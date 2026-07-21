#!/usr/bin/env python3
"""Audit image availability for recent items from each Feedmine feed.

The app currently records image URLs in its SQLite database, while the mining
Parquets do not. This tool reads a copied app database, probes a configurable
sample per source, and writes JSON, CSV, and Markdown reports explaining why an
image would not render.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import binascii
import csv
import io
import json
import sqlite3
import sys
import time
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any
from urllib.parse import unquote_to_bytes, urlparse

import httpx
from PIL import Image, UnidentifiedImageError


MIN_IMAGE_DIMENSION = 4
DEFAULT_MAX_BYTES = 20 * 1024 * 1024
SUCCESS_STATUSES = {"ok", "ok_content_type_mismatch"}


@dataclass(frozen=True)
class ItemSample:
    item_id: str
    source_url: str
    source_title: str
    title: str
    article_url: str
    image_url: str | None
    published_at: int


@dataclass
class ProbeResult:
    item_id: str
    source_url: str
    source_title: str
    title: str
    article_url: str
    image_url: str | None
    status: str
    error: str | None = None
    http_status: int | None = None
    content_type: str | None = None
    final_url: str | None = None
    response_bytes: int | None = None
    width: int | None = None
    height: int | None = None
    elapsed_ms: int = 0

    @property
    def succeeded(self) -> bool:
        return self.status in SUCCESS_STATUSES


def load_samples(
    database: Path,
    samples_per_feed: int,
    limit_feeds: int | None = None,
) -> list[ItemSample]:
    if not database.is_file():
        raise FileNotFoundError(f"Database not found: {database}")

    source_limit = "LIMIT ?" if limit_feeds is not None else ""
    parameters: list[int] = []
    if limit_feeds is not None:
        parameters.append(limit_feeds)
    parameters.append(samples_per_feed)

    query = f"""
        WITH recent_sources AS (
            SELECT source_url, MAX(published_at) AS latest_at
            FROM feed_item
            GROUP BY source_url
            ORDER BY latest_at DESC
            {source_limit}
        ), ranked AS (
            SELECT
                item.id,
                item.source_url,
                item.source_title,
                item.title,
                item.url,
                item.image_url,
                item.published_at,
                ROW_NUMBER() OVER (
                    PARTITION BY item.source_url
                    ORDER BY item.published_at DESC, item.fetched_at DESC
                ) AS sample_rank
            FROM feed_item AS item
            JOIN recent_sources USING (source_url)
        )
        SELECT id, source_url, source_title, title, url, image_url, published_at
        FROM ranked
        WHERE sample_rank <= ?
        ORDER BY source_url, sample_rank
    """

    uri = f"file:{database.resolve()}?mode=ro"
    with sqlite3.connect(uri, uri=True) as connection:
        rows = connection.execute(query, parameters).fetchall()

    return [ItemSample(*row) for row in rows]


def decode_data_url(url: str, max_bytes: int) -> bytes:
    header, separator, payload = url.partition(",")
    if not separator:
        raise ValueError("data URL has no payload separator")
    if ";base64" in header.lower():
        data = base64.b64decode(payload, validate=True)
    else:
        data = unquote_to_bytes(payload)
    if len(data) > max_bytes:
        raise ValueError(f"image exceeds {max_bytes} byte limit")
    return data


def inspect_image(data: bytes, content_type: str | None) -> tuple[str, int | None, int | None, str | None]:
    try:
        with Image.open(io.BytesIO(data)) as image:
            width, height = image.size
            image.verify()
    except (UnidentifiedImageError, OSError, ValueError) as error:
        normalized_type = (content_type or "").split(";", 1)[0].strip().lower()
        status = "undecodable_image" if normalized_type.startswith("image/") else "non_image_response"
        return status, None, None, str(error)

    if width < MIN_IMAGE_DIMENSION or height < MIN_IMAGE_DIMENSION:
        return "too_small", width, height, f"minimum dimension is {MIN_IMAGE_DIMENSION}px"

    normalized_type = (content_type or "").split(";", 1)[0].strip().lower()
    status = "ok" if not normalized_type or normalized_type.startswith("image/") else "ok_content_type_mismatch"
    return status, width, height, None


def result_for(sample: ItemSample, status: str, started: float, **values: Any) -> ProbeResult:
    return ProbeResult(
        item_id=sample.item_id,
        source_url=sample.source_url,
        source_title=sample.source_title,
        title=sample.title,
        article_url=sample.article_url,
        image_url=sample.image_url,
        status=status,
        elapsed_ms=round((time.monotonic() - started) * 1000),
        **values,
    )


async def probe_sample(
    sample: ItemSample,
    client: httpx.AsyncClient,
    max_bytes: int = DEFAULT_MAX_BYTES,
) -> ProbeResult:
    started = time.monotonic()
    if not sample.image_url:
        return result_for(sample, "missing_url", started)

    parsed = urlparse(sample.image_url)
    if parsed.scheme == "data":
        try:
            data = decode_data_url(sample.image_url, max_bytes)
        except (ValueError, binascii.Error) as error:
            return result_for(sample, "invalid_data_url", started, error=str(error))
        status, width, height, error = inspect_image(data, parsed.path.split(";", 1)[0])
        return result_for(
            sample,
            status,
            started,
            error=error,
            content_type=parsed.path.split(";", 1)[0],
            response_bytes=len(data),
            width=width,
            height=height,
        )

    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return result_for(sample, "invalid_url", started, error="expected an absolute HTTP(S) URL")

    try:
        async with client.stream("GET", sample.image_url) as response:
            content_type = response.headers.get("content-type")
            common = {
                "http_status": response.status_code,
                "content_type": content_type,
                "final_url": str(response.url),
            }
            if not 200 <= response.status_code < 300:
                return result_for(sample, f"http_{response.status_code}", started, **common)

            body = bytearray()
            async for chunk in response.aiter_bytes():
                body.extend(chunk)
                if len(body) > max_bytes:
                    return result_for(
                        sample,
                        "response_too_large",
                        started,
                        error=f"exceeded {max_bytes} bytes",
                        response_bytes=len(body),
                        **common,
                    )

        status, width, height, error = inspect_image(bytes(body), content_type)
        return result_for(
            sample,
            status,
            started,
            error=error,
            response_bytes=len(body),
            width=width,
            height=height,
            **common,
        )
    except httpx.TimeoutException as error:
        return result_for(sample, "timeout", started, error=str(error))
    except httpx.TooManyRedirects as error:
        return result_for(sample, "redirect_loop", started, error=str(error))
    except httpx.ConnectError as error:
        return result_for(sample, "connection_error", started, error=str(error))
    except httpx.HTTPError as error:
        return result_for(sample, "transport_error", started, error=str(error))


async def audit_samples(
    samples: list[ItemSample],
    concurrency: int,
    timeout: float,
    max_bytes: int,
) -> list[ProbeResult]:
    limits = httpx.Limits(
        max_connections=concurrency,
        max_keepalive_connections=max(4, concurrency // 2),
    )
    client_timeout = httpx.Timeout(timeout, connect=min(timeout, 10.0))
    semaphore = asyncio.Semaphore(concurrency)

    async with httpx.AsyncClient(
        follow_redirects=True,
        timeout=client_timeout,
        limits=limits,
        headers={"User-Agent": "feedmine/1.0 image-audit"},
    ) as client:
        async def limited_probe(sample: ItemSample) -> ProbeResult:
            async with semaphore:
                return await probe_sample(sample, client, max_bytes)

        tasks = [asyncio.create_task(limited_probe(sample)) for sample in samples]
        results: list[ProbeResult] = []
        for completed, task in enumerate(asyncio.as_completed(tasks), start=1):
            results.append(await task)
            if completed % 250 == 0 or completed == len(tasks):
                print(f"Probed {completed}/{len(tasks)} images", file=sys.stderr)
        return results


def summarize(results: list[ProbeResult]) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    status_counts = Counter(result.status for result in results)
    by_source: dict[str, list[ProbeResult]] = defaultdict(list)
    for result in results:
        by_source[result.source_url].append(result)

    feed_rows: list[dict[str, Any]] = []
    for source_url, source_results in by_source.items():
        failures = [result for result in source_results if not result.succeeded]
        statuses = Counter(result.status for result in source_results)
        feed_rows.append({
            "source_url": source_url,
            "source_title": source_results[0].source_title,
            "sample_count": len(source_results),
            "success_count": len(source_results) - len(failures),
            "failure_count": len(failures),
            "failure_rate": round(len(failures) / len(source_results), 4),
            "statuses": dict(statuses.most_common()),
        })

    feed_rows.sort(key=lambda row: (-row["failure_rate"], -row["failure_count"], row["source_title"].lower()))
    successes = sum(result.succeeded for result in results)
    summary = {
        "sample_count": len(results),
        "feed_count": len(by_source),
        "success_count": successes,
        "failure_count": len(results) - successes,
        "failure_rate": round((len(results) - successes) / len(results), 4) if results else 0,
        "status_counts": dict(status_counts.most_common()),
        "feeds_with_failures": sum(row["failure_count"] > 0 for row in feed_rows),
    }
    return summary, feed_rows


def write_reports(output_dir: Path, summary: dict[str, Any], feeds: list[dict[str, Any]], results: list[ProbeResult]) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    payload = {
        "summary": summary,
        "feeds": feeds,
        "items": [asdict(result) for result in results],
    }
    (output_dir / "image-audit.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )

    with (output_dir / "image-audit-feeds.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=[
            "source_title", "source_url", "sample_count", "success_count",
            "failure_count", "failure_rate", "statuses",
        ])
        writer.writeheader()
        for row in feeds:
            csv_row = dict(row)
            csv_row["statuses"] = json.dumps(row["statuses"], ensure_ascii=False, sort_keys=True)
            writer.writerow(csv_row)

    failures = [result for result in results if not result.succeeded]
    lines = [
        "# Feedmine Image Audit",
        "",
        f"- Items sampled: {summary['sample_count']}",
        f"- Feeds sampled: {summary['feed_count']}",
        f"- Failed items: {summary['failure_count']} ({summary['failure_rate']:.1%})",
        f"- Feeds with failures: {summary['feeds_with_failures']}",
        "",
        "## Failure reasons",
        "",
        "| Status | Items |",
        "| --- | ---: |",
    ]
    lines.extend(
        f"| {status} | {count} |"
        for status, count in summary["status_counts"].items()
        if status not in SUCCESS_STATUSES
    )
    lines.extend([
        "",
        "## Feeds with the highest failure rate",
        "",
        "| Feed | Failed | Sampled | Reasons |",
        "| --- | ---: | ---: | --- |",
    ])
    for row in [row for row in feeds if row["failure_count"] > 0][:100]:
        title = row["source_title"].replace("|", "\\|")
        reasons = ", ".join(f"{key}: {value}" for key, value in row["statuses"].items() if key not in SUCCESS_STATUSES)
        lines.append(f"| [{title}]({row['source_url']}) | {row['failure_count']} | {row['sample_count']} | {reasons} |")

    lines.extend([
        "",
        "## Failure examples",
        "",
        "| Feed | Item | Reason | Image URL |",
        "| --- | --- | --- | --- |",
    ])
    for result in failures[:100]:
        feed = result.source_title.replace("|", "\\|")
        title = result.title.replace("|", "\\|").replace("\n", " ")[:80]
        image_url = result.image_url or "(missing)"
        lines.append(f"| {feed} | {title} | {result.status} | {image_url} |")

    (output_dir / "image-audit.md").write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("database", type=Path, help="Copied Feedmine SQLite database")
    parser.add_argument("--output-dir", type=Path, default=Path("build/image-audit"))
    parser.add_argument("--samples-per-feed", type=int, default=3)
    parser.add_argument("--limit-feeds", type=int)
    parser.add_argument("--concurrency", type=int, default=24)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--max-bytes", type=int, default=DEFAULT_MAX_BYTES)
    parser.add_argument(
        "--fail-above",
        type=float,
        help="Exit with status 2 when the item failure rate exceeds this fraction",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.samples_per_feed < 1 or args.concurrency < 1:
        raise SystemExit("samples-per-feed and concurrency must be positive")

    samples = load_samples(args.database, args.samples_per_feed, args.limit_feeds)
    print(f"Loaded {len(samples)} samples from {len({sample.source_url for sample in samples})} feeds", file=sys.stderr)
    results = asyncio.run(audit_samples(samples, args.concurrency, args.timeout, args.max_bytes))
    summary, feeds = summarize(results)
    write_reports(args.output_dir, summary, feeds, results)

    print(json.dumps(summary, indent=2))
    print(f"Reports: {args.output_dir.resolve()}")
    if args.fail_above is not None and summary["failure_rate"] > args.fail_above:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
