from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

from .constants import FEED_ROOT_TAGS
from .models import Feed


def scan_directory(root: Path, recursive: bool = True) -> tuple[list[Feed], list[dict]]:
    """Walk *root*, parse every ``.opml`` file, and return (feeds, errors).

    *root* may be a single ``.opml`` file or a directory.
    """
    feeds: list[Feed] = []
    errors: list[dict] = []

    # Single file
    if root.is_file():
        base = root.parent
        try:
            feeds.extend(_parse_opml(root, base))
        except ET.ParseError as exc:
            errors.append({"file": str(root.relative_to(base)), "error": f"XML parse error: {exc}"})
        except OSError as exc:
            errors.append({"file": str(root.relative_to(base)), "error": f"IO error: {exc}"})
        return feeds, errors

    # Directory
    pattern = "**/*.opml" if recursive else "*.opml"
    for path in sorted(root.glob(pattern)):
        if not path.is_file():
            continue
        try:
            file_feeds = _parse_opml(path, root)
            feeds.extend(file_feeds)
        except ET.ParseError as exc:
            errors.append({"file": str(path.relative_to(root)), "error": f"XML parse error: {exc}"})
        except OSError as exc:
            errors.append({"file": str(path.relative_to(root)), "error": f"IO error: {exc}"})

    return feeds, errors


def _parse_opml(path: Path, root: Path) -> list[Feed]:
    """Extract every RSS/Atom feed from a single OPML file."""
    tree = ET.parse(str(path))
    opml_root = tree.getroot()

    if opml_root.tag.lower() != "opml":
        return []

    body = opml_root.find("body")
    if body is None:
        return []

    source = str(path.relative_to(root))
    feeds: list[Feed] = []

    # Walk recursively — OPML allows nested <outline> groups.
    _walk_outlines(body, source, "", feeds)

    return feeds


def _walk_outlines(
    element: ET.Element,
    source: str,
    parent_category: str,
    feeds: list[Feed],
) -> None:
    """Recurse through <outline> elements, collecting feeds."""
    for outline in element.findall("outline"):
        xml_url = outline.get("xmlUrl") or outline.get("xmlurl")
        title = outline.get("title") or outline.get("text") or "Untitled"
        category = outline.get("text") or parent_category

        if xml_url:
            # Only HTTP(S)
            if xml_url.startswith(("http://", "https://")):
                feeds.append(Feed(url=xml_url.strip(), title=title.strip(), source_file=source, category=category.strip()))
            # else skip (non-HTTP scheme)

        # Recurse for groups
        _walk_outlines(outline, source, category, feeds)
