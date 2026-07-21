#!/usr/bin/env python3
"""Merge an isolated recovery run into FeedMine's normalized corpus.

The merge is deliberately conservative: recovery identities must be absent
from the base source table, and every membership/attempt must reference one of
the recovery rows. Redundant Google News ``topic=`` endpoints are retained for
auditability with ``excluded_policy`` status, but never become production
sources during OPML curation.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import urllib.parse
from collections import Counter
from pathlib import Path
from typing import Sequence

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq


POLICY_EXCLUSION_REASON = (
    "editorial policy: redundant Google News topic endpoint returns generic headlines"
)
STATUS_RANK = {
    # A deliberate policy decision supersedes an earlier transport failure,
    # while curation itself still ranks a real done variant above exclusion.
    "excluded_policy": 5,
    "done": 4,
    "empty": 3,
    "failed": 2,
    "unknown": 0,
}


def clean(value: object) -> str:
    if value is None or pd.isna(value):
        return ""
    return str(value).strip()


def canonical_url(value: str) -> str:
    """Mirror the app/curation runtime identity normalization."""
    value = clean(value)
    parsed = urllib.parse.urlsplit(value)
    if not parsed.scheme or not parsed.netloc:
        return value
    hostname = (parsed.hostname or "").lower()
    if hostname.startswith("www."):
        hostname = hostname[4:]
    port = f":{parsed.port}" if parsed.port else ""
    path = parsed.path[:-1] if parsed.path.endswith("/") else parsed.path
    tracking = {
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "ref", "source", "fbclid", "gclid",
    }
    query = urllib.parse.urlencode([
        (name, item)
        for name, item in urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)
        if name.lower() not in tracking
    ], doseq=True)
    return urllib.parse.urlunsplit(("https", hostname + port, path, query, ""))


def is_redundant_google_topic(url: object) -> bool:
    parsed = urllib.parse.urlsplit(clean(url))
    hostname = (parsed.hostname or "").lower().removeprefix("www.")
    query = urllib.parse.parse_qs(parsed.query)
    return hostname == "news.google.com" and "topic" in query


def read_policy_exclusions(path: Path | None) -> dict[str, str]:
    if path is None or not path.exists():
        return {}
    with path.open(newline="", encoding="utf-8") as handle:
        rows = csv.DictReader(handle)
        return {
            clean(row.get("source_id")): clean(row.get("reason"))
            for row in rows
            if clean(row.get("source_id")) and clean(row.get("reason"))
        }


def apply_editorial_policy(
    sources: pd.DataFrame,
    exclusions: dict[str, str] | None = None,
) -> pd.DataFrame:
    result = sources.copy()
    mask = (
        result["status"].fillna("").eq("done")
        & result["xml_url"].map(is_redundant_google_topic)
    )
    result.loc[mask, "status"] = "excluded_policy"
    result.loc[mask, "error_message"] = POLICY_EXCLUSION_REASON
    for source_id, reason in (exclusions or {}).items():
        manual_mask = result["source_id"].map(clean).eq(source_id)
        result.loc[manual_mask, "status"] = "excluded_policy"
        result.loc[manual_mask, "error_message"] = f"editorial policy: {reason}"
    return result


def parquet_path(prefix: Path, suffix: str) -> Path:
    return prefix.parent / f"{prefix.name}_{suffix}.parquet"


def read_frame(path: Path) -> tuple[pd.DataFrame, pa.Schema]:
    table = pq.read_table(path)
    return table.to_pandas(), table.schema


def write_atomic(frame: pd.DataFrame, schema: pa.Schema, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.tmp")
    table = pa.Table.from_pandas(frame, schema=schema, preserve_index=False)
    pq.write_table(table, temporary, compression="zstd")
    os.replace(temporary, path)


def merge_source_frames(
    base: pd.DataFrame,
    recovery: pd.DataFrame,
    allow_existing: bool,
) -> tuple[pd.DataFrame, set[str], set[str], dict[str, str], int]:
    """Append new identities and optionally replace previously attempted rows."""
    base = base.copy()
    recovery = recovery.copy()
    base_identity_to_index = {
        canonical_url(row.xml_url): index
        for index, row in base.iterrows()
    }
    recovery_identities = recovery["xml_url"].map(canonical_url)
    if recovery_identities.duplicated().any():
        raise RuntimeError("recovery source table contains duplicate runtime identities")

    duplicate_identities = sorted(set(recovery_identities).intersection(base_identity_to_index))
    if duplicate_identities and not allow_existing:
        raise RuntimeError(
            f"recovery contains {len(duplicate_identities)} runtime identities already present in base"
        )

    new_rows: list[pd.Series] = []
    new_source_ids: set[str] = set()
    existing_source_ids: set[str] = set()
    source_id_remap: dict[str, str] = {}
    replaced = 0
    for (_, recovery_row), identity in zip(recovery.iterrows(), recovery_identities):
        source_id = clean(recovery_row["source_id"])
        base_index = base_identity_to_index.get(identity)
        if base_index is None:
            new_rows.append(recovery_row)
            new_source_ids.add(source_id)
            continue

        base_source_id = clean(base.at[base_index, "source_id"])
        if source_id != base_source_id:
            source_id_remap[source_id] = base_source_id
            recovery_row = recovery_row.copy()
            recovery_row["source_id"] = base_source_id
        existing_source_ids.add(base_source_id)
        old_status = clean(base.at[base_index, "status"]) or "unknown"
        new_status = clean(recovery_row["status"]) or "unknown"
        if STATUS_RANK.get(new_status, 0) > STATUS_RANK.get(old_status, 0):
            base.loc[base_index] = recovery_row
            replaced += 1

    if new_rows:
        base = pd.concat([base, pd.DataFrame(new_rows)], ignore_index=True)
    return base, new_source_ids, existing_source_ids, source_id_remap, replaced


def merge(
    base_prefix: Path,
    recovery_prefix: Path,
    output_prefix: Path,
    allow_existing: bool = False,
    policy_exclusions: Path | None = None,
) -> dict[str, object]:
    source_suffix = "sources"
    base_sources, source_schema = read_frame(parquet_path(base_prefix, source_suffix))
    recovery_sources, recovery_source_schema = read_frame(parquet_path(recovery_prefix, source_suffix))
    if source_schema.names != recovery_source_schema.names:
        raise RuntimeError("base and recovery source schemas differ")

    exclusions = read_policy_exclusions(policy_exclusions)
    recovery_sources = apply_editorial_policy(recovery_sources, exclusions)
    recovery_source_ids = set(recovery_sources["source_id"].map(clean))
    (
        merged_sources,
        new_source_ids,
        existing_source_ids,
        source_id_remap,
        replaced_count,
    ) = merge_source_frames(
        base_sources, recovery_sources, allow_existing=allow_existing
    )

    output_counts: dict[str, int] = {}
    for suffix, key in (
        ("source_memberships", "membership_id"),
        ("fetch_attempts", "attempt_id"),
    ):
        base_frame, schema = read_frame(parquet_path(base_prefix, suffix))
        recovery_frame, recovery_schema = read_frame(parquet_path(recovery_prefix, suffix))
        if schema.names != recovery_schema.names:
            raise RuntimeError(f"base and recovery {suffix} schemas differ")
        unknown_source_ids = set(recovery_frame["source_id"].map(clean)) - recovery_source_ids
        if unknown_source_ids:
            raise RuntimeError(f"{suffix} contains references outside the recovery source table")
        if source_id_remap:
            recovery_frame = recovery_frame.copy()
            recovery_frame["source_id"] = recovery_frame["source_id"].map(
                lambda value: source_id_remap.get(clean(value), clean(value))
            )
        if suffix == "source_memberships":
            # Existing sources keep their original editorial membership trail;
            # recovery-queue file paths are operational metadata, not new homes.
            recovery_frame = recovery_frame[
                recovery_frame["source_id"].map(clean).isin(new_source_ids)
            ]
        merged = pd.concat([base_frame, recovery_frame], ignore_index=True)
        merged = merged.drop_duplicates(subset=[key], keep="last")
        write_atomic(merged, schema, parquet_path(output_prefix, suffix))
        output_counts[suffix] = len(merged)

    write_atomic(merged_sources, source_schema, parquet_path(output_prefix, source_suffix))
    output_counts[source_suffix] = len(merged_sources)
    status_counts = Counter(recovery_sources["status"].fillna("unknown").map(clean))
    summary: dict[str, object] = {
        "base_prefix": str(base_prefix),
        "recovery_prefix": str(recovery_prefix),
        "output_prefix": str(output_prefix),
        "base_source_count": len(base_sources),
        "recovery_source_count": len(recovery_sources),
        "new_source_count": len(new_source_ids),
        "existing_source_count": len(existing_source_ids),
        "remapped_source_id_count": len(source_id_remap),
        "replaced_source_count": replaced_count,
        "recovery_status_counts_after_policy": dict(sorted(status_counts.items())),
        "policy_excluded_count": status_counts["excluded_policy"],
        "policy_exclusions_file": str(policy_exclusions) if policy_exclusions else None,
        "listed_policy_exclusion_count": len(exclusions),
        "output_counts": output_counts,
    }
    summary_path = output_prefix.parent / f"{output_prefix.name}_merge_summary.json"
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return summary


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-prefix", type=Path, default=Path("feeds_corpus"))
    parser.add_argument("--recovery-prefix", type=Path, required=True)
    parser.add_argument("--output-prefix", type=Path, required=True)
    parser.add_argument(
        "--allow-existing",
        action="store_true",
        help="Replace an existing row only when the recovery status improves",
    )
    parser.add_argument(
        "--policy-exclusions",
        type=Path,
        default=Path("editorial/feed-curation/policy-exclusions.csv"),
        help="Audited source_id,reason CSV (silently ignored when absent)",
    )
    parser.add_argument("--json", action="store_true")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    summary = merge(
        args.base_prefix,
        args.recovery_prefix,
        args.output_prefix,
        allow_existing=args.allow_existing,
        policy_exclusions=args.policy_exclusions,
    )
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2, sort_keys=True))
    else:
        print(
            f"Merged {summary['recovery_source_count']} recovery rows; "
            f"policy-excluded {summary['policy_excluded_count']}; "
            f"final sources {summary['output_counts']['sources']}."
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
