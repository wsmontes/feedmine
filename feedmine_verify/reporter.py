from __future__ import annotations

import json
from pathlib import Path
from typing import Optional

from .models import CheckResult, Report


def write_json_report(report: Report, path: Path) -> None:
    """Serialise *report* to *path* as JSON."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(_report_to_dict(report), indent=2, default=str), encoding="utf-8")


def print_terminal_report(
    results: list[CheckResult],
    scan_errors: list[dict],
    report_meta: dict,
    format_mode: str,
) -> None:
    """Print results to the terminal.

    *format_mode* is one of ``full``, ``minimal``, ``summary``.
    Uses only stdlib so it works without ``rich`` installed.
    """
    # ---- Counts ----
    counts: dict[str, int] = {}
    for r in results:
        counts[r.status] = counts.get(r.status, 0) + 1

    total = len(results)

    # ---- Per-status colours (ANSI) ----
    colors = {
        "ok":         "\033[32m",  # green
        "redirected": "\033[36m",  # cyan
        "stale":      "\033[33m",  # yellow
        "invalid":    "\033[35m",  # magenta
        "timeout":    "\033[33m",  # yellow
        "dead":       "\033[31m",  # red
        "error":      "\033[31m",  # red
    }
    reset = "\033[0m"
    bold = "\033[1m"

    c = lambda s: f"{colors.get(s, '')}{s}{reset}"

    # ---- Header ----
    print()
    print(f"{bold}Feedmine Link Verifier — Report{reset}")
    print(f"  Depth: {report_meta['depth']}  |  "
          f"Concurrency: {report_meta['concurrency']}  |  "
          f"Timeout: {report_meta['timeout']}s  |  "
          f"Duration: {report_meta['duration_seconds']:.1f}s")
    print()

    # ---- Summary ----
    print(f"{bold}Summary{reset}")
    print(f"  Total:    {total}")
    for status in ("ok", "redirected", "stale", "invalid", "timeout", "dead", "error"):
        if count := counts.get(status, 0):
            print(f"  {c(status):30s} {count:>6}")
    print()

    # ---- Scan errors ----
    if scan_errors:
        print(f"{bold}File Errors{reset}")
        for e in scan_errors:
            print(f"  {colors['dead']}{e['file']}{reset}: {e['error']}")
        print()

    # ---- Detail (full / minimal) ----
    if format_mode == "summary":
        return

    if format_mode == "minimal":
        failed = [r for r in results if r.status not in ("ok", "redirected", "stale")]
        _print_results_table(failed, colors, reset, bold)
        return

    # full
    _print_results_table(results, colors, reset, bold)


def _print_results_table(
    results: list[CheckResult],
    colors: dict[str, str],
    reset: str,
    bold: str,
) -> None:
    if not results:
        return

    c = lambda s: f"{colors.get(s, '')}{s}{reset}"
    print(f"{bold}Results{reset}")
    print(f"  {'Status':12s} {'Time':>7s}  {'Code':>4s}  {'Title':40s}  URL")

    for r in sorted(results, key=lambda x: (x.status, x.url)):
        status = c(r.status)
        time_str = f"{r.response_time_ms:,.0f}ms" if r.response_time_ms else "-"
        code = str(r.status_code) if r.status_code else "-"
        title = r.title[:38] + "…" if len(r.title) > 39 else r.title
        url = r.url[:80] + "…" if len(r.url) > 81 else r.url

        print(f"  {status:32s} {time_str:>7s}  {code:>4s}  {title:40s}  {url}")
    print()


def _report_to_dict(report: Report) -> dict:
    return {
        "metadata": {
            "timestamp": report.timestamp,
            "depth": report.depth,
            "concurrency": report.concurrency,
            "timeout": report.timeout,
            "total_feeds": report.total_feeds,
            "duration_seconds": report.duration_seconds,
        },
        "summary": report.summary,
        "results": report.results,
        "errors": report.errors,
    }
