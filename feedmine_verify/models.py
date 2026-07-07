from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


@dataclass
class Feed:
    """A single feed discovered inside an OPML file."""

    url: str
    title: str
    source_file: str          # e.g. "tech.opml" or "countries/brazil.opml"
    category: str = ""        # parent <outline text="…"> value


@dataclass
class CheckResult:
    """The outcome of checking one feed."""

    url: str
    title: str
    source_files: list[str]   # deduplicated — one check, many source files
    categories: list[str]

    status: str = "ok"        # ok | redirected | stale | invalid | timeout | dead | error
    status_code: int = 0
    response_time_ms: float = 0.0
    redirect_chain: list[str] = field(default_factory=list)
    final_url: str = ""

    # Depth 2
    content_type: str = ""
    body_size: int = 0
    is_valid_feed: bool = False

    # Depth 3
    newest_post_date: Optional[datetime] = None
    days_since_last_post: Optional[int] = None
    freshness_status: str = ""  # fresh | stale | no_dates

    # Error details
    error_message: str = ""


@dataclass
class Report:
    """Top-level report written to JSON and summarised in the terminal."""

    timestamp: str
    depth: int
    concurrency: int
    timeout: int
    total_feeds: int
    duration_seconds: float

    summary: dict[str, int]   # status → count
    results: list[dict]       # serialised CheckResult objects
    errors: list[dict]        # file-level parse failures: {file, error}
