#!/usr/bin/env python3
"""
Extract ALL localizable strings from FeedMine Swift source files.

Handles BOTH literal strings and interpolated strings (converting
Swift \\(variable) interpolation to %@ / %N$@ format specifiers).

Output: JSON template ready for translation.
"""
import re, json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent / "feedmine"
OUTPUT = ROOT / "Resources" / "string_template.json"

# ── Patterns (regex, string_group, optional_comment_group) ──
PATTERNS = [
    # String(localized: "string", comment: "comment")
    (r'String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"\s*,\s*comment:\s*"((?:[^"\\]|\\.)*)"', 1, 2),
    # String(localized: "string")
    (r'String\(\s*localized:\s*"((?:[^"\\]|\\.)*)"\s*\)', 1, None),
    # Text("string") — NOT verbatim:
    (r'(?<!verbatim:\s)Text\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # LocalizedStringKey("string")
    (r'LocalizedStringKey\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Button("string")
    (r'Button\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Label("string", ...)
    (r'Label\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Toggle("string", ...)
    (r'Toggle\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # TextField("string", ...)
    (r'TextField\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Section("string")
    (r'Section\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Menu("string", ...)
    (r'Menu\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Picker("string", ...)
    (r'Picker\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # .navigationTitle("string")
    (r'\.navigationTitle\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # .navigationBarTitle("string")
    (r'\.navigationBarTitle\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # .alert("string", ...)
    (r'\.alert\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # .confirmationDialog("string", ...)
    (r'\.confirmationDialog\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # .searchable("string")
    (r'\.searchable\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Link("string", ...)
    (r'Link\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
    # Label with systemImage (bare string)
    (r'\.accessibilityLabel\(\s*"((?:[^"\\]|\\.)*)"', 1, None),
]

EXCLUDE = {"", " ", "  ", " · ", "·"}


def to_format_key(raw: str) -> str:
    """Convert Swift string (possibly with \\(var) interpolation) to
    a String Catalog format key using %@ / %N$@ placeholders."""
    counter = 0
    interp_count = raw.count("\\(")

    def replace(_m):
        nonlocal counter
        counter += 1
        if interp_count == 1:
            return "%@"
        return f"%{counter}$@"

    return re.sub(r'\\\([^)]+\)', replace, raw)


def is_translatable(string: str) -> bool:
    """Return True if this string should go into the catalog."""
    if string in EXCLUDE:
        return False
    # Skip code artifacts from partial regex matches
    if any(bad in string for bad in [
        ".deletingPathExtension", ".capitalized", ".count", ".isEmpty",
        " == 1 ?", " : \"", "\" : \"",
    ]):
        return False
    # Skip SF Symbol names: lowercase.words.separated.by.dots
    if re.match(r'^[a-z]+(\.[a-z0-9]+){2,}$', string):
        return False
    # Skip single-word-lowercase SF Symbols that look like variable names
    if re.match(r'^[a-z]+$', string) and len(string) < 10:
        return False
    # Skip API field names / weather codes (snake_case identifiers)
    if re.match(r'^[a-z]+(_[a-z0-9]+)+$', string):
        return False
    # Skip obviously broken extractions (trailing parens, etc.)
    if re.search(r'\)\s*$', string) and '\\(' not in string:
        return False
    if re.match(r'^[%@#\s\.·🎧⏳✓⟳↓\[\]\(\)\{\}<>/\\|_\-+=*&^%$!~`;:,?]+$', string):
        return False
    if re.match(r'^\d+(\.\d+)?$', string):
        return False
    if string.startswith("http") or string.startswith("/"):
        return False
    return True


def extract_from_file(filepath: Path) -> dict:
    """Extract localizable strings from a Swift file.
    Returns {format_key: {"files": [...], "comment": str|None, "raw": str}}"""
    try:
        content = filepath.read_text()
    except Exception:
        return {}

    found = {}
    relpath = str(filepath.relative_to(ROOT.parent))

    for pattern, str_group, comment_group in PATTERNS:
        for m in re.finditer(pattern, content):
            raw = m.group(str_group)
            string = raw.replace('\\"', '"').replace('\\n', '\n').replace('\\t', '\t').strip()
            if not is_translatable(string):
                continue

            # Convert Swift interpolation → format key for String Catalog
            format_key = to_format_key(string)

            comment = m.group(comment_group) if comment_group else None
            line_no = content[:m.start()].count('\n') + 1

            if format_key not in found:
                found[format_key] = {
                    "files": [],
                    "comment": comment,
                    "raw": string,
                }
            found[format_key]["files"].append(f"{relpath}:{line_no}")
            if comment and not found[format_key]["comment"]:
                found[format_key]["comment"] = comment

    return found


def main():
    all_strings = {}

    for swift_file in sorted(ROOT.rglob("*.swift")):
        found = extract_from_file(swift_file)
        for key, info in found.items():
            if key not in all_strings:
                all_strings[key] = info
            else:
                all_strings[key]["files"].extend(info["files"])
                if info["comment"] and not all_strings[key]["comment"]:
                    all_strings[key]["comment"] = info["comment"]

    # ── Additional: scan for strings in return statements and variables ──
    # These are strings that feed SwiftUI views indirectly
    extra_strings = scan_extra_strings()
    for key, info in extra_strings.items():
        if key not in all_strings:
            all_strings[key] = info

    sorted_strings = dict(sorted(all_strings.items(), key=lambda x: x[0].lower()))

    output = {
        "_meta": {
            "total_strings": len(sorted_strings),
            "source_language": "en",
            "instructions": "Add translations under each string key. "
                           "Format specifiers (%@, %1$@, %2$@) must be preserved "
                           "in translations. Run translate.py to convert this into "
                           "Localizable.xcstrings."
        },
        "strings": {}
    }

    for key, info in sorted_strings.items():
        entry = {"files": info["files"]}
        if info.get("comment"):
            entry["comment"] = info["comment"]
        output["strings"][key] = entry

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with open(OUTPUT, 'w') as f:
        json.dump(output, f, indent=2, ensure_ascii=False)

    print(f"Extracted {len(sorted_strings)} unique strings")
    print(f"Template: {OUTPUT}")

    # Sample
    shown = 0
    for k, v in sorted_strings.items():
        if shown >= 20:
            break
        loc = ", ".join(v["files"][:2])
        raw = v.get("raw", "")
        comment = f"  # {v['comment']}" if v.get("comment") else ""
        print(f"  [{k}]{comment}")
        if raw != k:
            print(f"    raw: \"{raw}\"")
        print(f"    → {loc}")
        shown += 1


def scan_extra_strings() -> dict:
    """Scan for strings returned by functions/methods that feed into SwiftUI,
    and for strings in enum rawValues used in UI contexts."""
    extra = {}
    for swift_file in sorted(ROOT.rglob("*.swift")):
        try:
            content = swift_file.read_text()
        except Exception:
            continue
        relpath = str(swift_file.relative_to(ROOT.parent))

        # Find strings in return statements: return "string" or return "..."
        for m in re.finditer(r'return\s+"((?:[^"\\]|\\.)*)"', content):
            raw = m.group(1)
            s = raw.replace('\\"', '"').replace('\\n', '\n').replace('\\t', '\t').strip()
            if not is_translatable(s):
                continue
            key = to_format_key(s)
            line_no = content[:m.start()].count('\n') + 1
            if key not in extra:
                extra[key] = {"files": [], "comment": None, "raw": s}
            extra[key]["files"].append(f"{relpath}:{line_no}")

        # Find strings in enum cases with String rawValue used for display
        # pattern: case foo = "Display String"
        for m in re.finditer(r'case\s+\w+\s*=\s*"((?:[^"\\]|\\.)*)"', content):
            raw = m.group(1)
            s = raw.replace('\\"', '"').replace('\\n', '\n').replace('\\t', '\t').strip()
            if not is_translatable(s) or "\\(" in s:
                continue
            line_no = content[:m.start()].count('\n') + 1
            if s not in extra:
                extra[s] = {"files": [], "comment": None, "raw": s}
            extra[s]["files"].append(f"{relpath}:{line_no} (enum case)")

    return extra


if __name__ == "__main__":
    main()
