from __future__ import annotations

from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

from feedmine_verify.scanner import scan_directory


def normalize_url(url: str) -> str:
    u = url.strip().lower().split("#")[0]
    if u.startswith("http://"):
        u = "https://" + u[len("http://"):]
    return u.rstrip("/")


def existing_feed_urls(country_dir: Path) -> set[str]:
    feeds, _errors = scan_directory(Path(country_dir), recursive=True)
    return {normalize_url(f.url) for f in feeds}


def emit_opml(
    country_name: str,
    feeds_by_category: dict[str, list[tuple[str, str]]],
    categories_order: list[str],
) -> str:
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<opml version="1.0">',
        "  <head>",
        f"    <title>{escape(country_name)} Feeds (candidates)</title>",
        "  </head>",
        "  <body>",
    ]
    for cat in categories_order:
        feeds = feeds_by_category.get(cat) or []
        if not feeds:
            continue
        lines.append(f"    <outline text={quoteattr(cat)}>")
        for title, url, genre in feeds:
            attrs = f"title={quoteattr(title)} xmlUrl={quoteattr(url)} type=\"rss\""
            if genre:
                attrs += f" category={quoteattr(genre)}"
            lines.append(f"      <outline {attrs} />")
        lines.append("    </outline>")
    lines.append("  </body>")
    lines.append("</opml>")
    lines.append("")
    return "\n".join(lines)
