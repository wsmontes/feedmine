from __future__ import annotations

import json
from pathlib import Path

from .models import Candidate
from .registry import CATEGORIES


def summarize(slug: str, candidates: list[Candidate]) -> dict:
    per_cat_new: dict[str, int] = {}
    for c in candidates:
        if c.is_new and c.national and c.is_live:
            per_cat_new[c.category] = per_cat_new.get(c.category, 0) + 1
    return {
        "slug": slug,
        "total": len(candidates),
        "national": sum(1 for c in candidates if c.national),
        "blocked": sum(1 for c in candidates if c.national_reason == "blocked"),
        "foreign": sum(1 for c in candidates if c.national_reason == "foreign"),
        "live": sum(1 for c in candidates if c.is_live),
        "new": sum(1 for c in candidates if c.is_new and c.national and c.is_live),
        "per_category_new": per_cat_new,
    }


def render_markdown(summaries: list[dict]) -> str:
    lines = ["# Feed Discovery Report", ""]
    for s in summaries:
        lines.append(f"## {s['slug']}")
        lines.append(
            f"- total candidates: {s['total']} | national: {s['national']} | "
            f"blocked: {s['blocked']} | foreign: {s['foreign']} | "
            f"live: {s['live']} | **new: {s['new']}**"
        )
        lines.append("")
        lines.append("| Category | New feeds |")
        lines.append("| --- | --- |")
        for cat in CATEGORIES:
            n = s["per_category_new"].get(cat, 0)
            if n:
                lines.append(f"| {cat} | {n} |")
        lines.append("")
    return "\n".join(lines)


def write_reports(out_dir: Path, summaries: list[dict]) -> None:
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "report.md").write_text(render_markdown(summaries), encoding="utf-8")
    (out_dir / "report.json").write_text(
        json.dumps(summaries, ensure_ascii=False, indent=2), encoding="utf-8"
    )
