# Sub-Region OPML Populator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preencher 1421 OPMLs de sub-região vazios com feeds locais descobertos automaticamente via DDG search, iTunes API e YouTube scraping.

**Architecture:** Novo subpacote `scripts/feed_discovery/subregion/` com 4 módulos + extensão de `models.py` e `heuristic.py`. O pipeline reusa `search.py`, `discover.py`, `verify.py`, `sources/podcasts.py`, `sources/youtube.py` existentes. A orquestração processa 1 país por vez com sub-regiões em paralelo.

**Tech Stack:** Python 3.12, aiohttp, ddgs, xml.etree.ElementTree, pytest

## Global Constraints

- Todos os novos módulos ficam em `scripts/feed_discovery/subregion/` (imports relativos `from .. import ...`)
- Reutilizar `search.py`, `discover.py`, `verify.py`, `sources/podcasts.py`, `sources/youtube.py` sem modificá-los
- Estender `models.py` (adicionar `SubRegion`) e `heuristic.py` (adicionar `is_local()`) com alterações mínimas
- OPMLs de saída preservam a estrutura existente (cabeçalho, categorias já populadas)
- Não modificar OPMLs de país (`{pais}.opml`), apenas sub-região (`{pais}-{subregiao}.opml`)
- Progresso salvo em `progress.json` para retomar de onde parou
- Ordem de processamento: países por população decrescente

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/feed_discovery/models.py` | Modify | Adicionar dataclass `SubRegion` |
| `scripts/feed_discovery/heuristic.py` | Modify | Adicionar `is_local()` e blocklist global |
| `scripts/feed_discovery/subregion/__init__.py` | Create | Pacote vazio |
| `scripts/feed_discovery/subregion/enrich_countries.py` | Create | Gerar `countries_enriched.json` com SubRegions e população |
| `scripts/feed_discovery/subregion/opml_writer.py` | Create | Escrever Candidates no OPML preservando estrutura |
| `scripts/feed_discovery/subregion/discover_subregion.py` | Create | Descoberta 3 vias para uma sub-região |
| `scripts/feed_discovery/subregion/populate.py` | Create | Orquestrador: país por país, paralelo, com progresso |
| `scripts/feed_discovery/subregion/test_enrich.py` | Create | Testes unitários para enrich_countries |
| `scripts/feed_discovery/subregion/test_is_local.py` | Create | Testes unitários para is_local() |
| `scripts/feed_discovery/subregion/test_opml_writer.py` | Create | Testes unitários para opml_writer |

---

### Task 1: SubRegion dataclass + enrich_countries.py

**Files:**
- Modify: `scripts/feed_discovery/models.py`
- Create: `scripts/feed_discovery/subregion/__init__.py`
- Create: `scripts/feed_discovery/subregion/enrich_countries.py`
- Create: `scripts/feed_discovery/subregion/test_enrich.py`

**Interfaces:**
- Produces: `SubRegion` dataclass (slug, name, parent_country, iso2, iso3, ddg_region, opml_path)
- Produces: `enrich_countries.enrich(opml_base: Path, countries_json: Path, output_path: Path) -> dict`
- Produces: `enrich_countries.humanize_slug(slug: str) -> str`
- Produces: `enrich_countries.POPULATION: dict[str, int]` — população dos 101 países

- [ ] **Step 1: Add SubRegion dataclass to models.py**

```python
# Add after the Country dataclass in models.py

@dataclass
class SubRegion:
    slug: str              # "nigeria-lagos"
    name: str              # "Lagos"
    parent_country: str    # "nigeria"
    iso2: str              # "ng"
    iso3: str              # "NGA"
    ddg_region: str        # "ng-en"
    opml_path: str = ""    # absolute path to the .opml file
```

- [ ] **Step 2: Create subregion/__init__.py**

```python
# scripts/feed_discovery/subregion/__init__.py
```

- [ ] **Step 3: Write test_enrich.py**

```python
# scripts/feed_discovery/subregion/test_enrich.py

from scripts.feed_discovery.subregion.enrich_countries import humanize_slug, POPULATION


def test_humanize_slug_simple():
    assert humanize_slug("nigeria-lagos") == "Lagos"


def test_humanize_slug_multi_word():
    assert humanize_slug("nigeria-akwa-ibom") == "Akwa Ibom"


def test_humanize_slug_romanian():
    assert humanize_slug("romania-cluj-napoca") == "Cluj-Napoca"


def test_humanize_slug_with_dots():
    assert humanize_slug("usa-district-of-columbia") == "District Of Columbia"


def test_population_has_top_countries():
    assert POPULATION["india"] > 1_000_000_000
    assert POPULATION["china"] > 1_000_000_000
    assert POPULATION["nigeria"] > 200_000_000
    assert POPULATION["brazil"] > 200_000_000


def test_population_has_all_101():
    # All countries in the OPML must have population entries
    assert len(POPULATION) >= 101
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_enrich.py -v
```
Expected: 3 failures — `ModuleNotFoundError` for enrich_countries

- [ ] **Step 5: Write enrich_countries.py**

```python
# scripts/feed_discovery/subregion/enrich_countries.py

from __future__ import annotations

import json
from pathlib import Path

# Population data for all 101 countries (2024 estimates, millions → raw).
# Used to sort processing order: most-populous first.
POPULATION: dict[str, int] = {
    "india": 1_441_000_000, "china": 1_410_000_000, "indonesia": 277_000_000,
    "pakistan": 231_000_000, "nigeria": 216_000_000, "brazil": 214_000_000,
    "bangladesh": 169_000_000, "russia": 144_000_000, "mexico": 128_000_000,
    "ethiopia": 126_000_000, "japan": 125_000_000, "philippines": 115_000_000,
    "egypt": 109_000_000, "vietnam": 103_000_000, "iran": 89_000_000,
    "turkey": 85_000_000, "germany": 84_000_000, "thailand": 71_000_000,
    "united-kingdom": 68_000_000, "france": 68_000_000, "italy": 59_000_000,
    "south-africa": 59_000_000, "tanzania": 65_000_000, "myanmar": 54_000_000,
    "south-korea": 51_000_000, "colombia": 51_000_000, "spain": 47_000_000,
    "argentina": 46_000_000, "algeria": 45_000_000, "sudan": 48_000_000,
    "iraq": 44_000_000, "uganda": 48_000_000, "ukraine": 37_000_000,
    "canada": 39_000_000, "poland": 38_000_000, "morocco": 37_000_000,
    "saudi-arabia": 36_000_000, "angola": 36_000_000, "uzbekistan": 35_000_000,
    "peru": 34_000_000, "malaysia": 34_000_000, "ghana": 33_000_000,
    "mozambique": 33_000_000, "nepal": 30_000_000, "venezuela": 28_000_000,
    "ivory-coast": 28_000_000, "australia": 26_000_000, "north-korea": 26_000_000,
    "taiwan": 23_000_000, "burkina-faso": 23_000_000, "mali": 23_000_000,
    "syria": 22_000_000, "sri-lanka": 22_000_000, "malawi": 21_000_000,
    "zambia": 20_000_000, "romania": 19_000_000, "chile": 19_000_000,
    "kazakhstan": 19_000_000, "ecuador": 18_000_000, "guatemala": 17_000_000,
    "senegal": 17_000_000, "netherlands": 17_000_000, "cambodia": 16_000_000,
    "zimbabwe": 16_000_000, "guinea": 14_000_000, "rwanda": 14_000_000,
    "benin": 13_000_000, "burundi": 13_000_000, "tunisia": 12_000_000,
    "belgium": 11_000_000, "haiti": 11_000_000, "jordan": 11_000_000,
    "cuba": 11_000_000, "south-sudan": 11_000_000, "dominican-republic": 11_000_000,
    "czech-republic": 10_000_000, "sweden": 10_000_000, "greece": 10_000_000,
    "portugal": 10_000_000, "azerbaijan": 10_000_000, "hungary": 9_700_000,
    "israel": 9_300_000, "austria": 9_100_000, "belarus": 9_200_000,
    "switzerland": 8_800_000, "serbia": 6_600_000, "bulgaria": 6_400_000,
    "denmark": 5_900_000, "finland": 5_500_000, "norway": 5_500_000,
    "slovakia": 5_400_000, "ireland": 5_200_000, "new-zealand": 5_200_000,
    "costa-rica": 5_200_000, "singapore": 5_100_000, "croatia": 3_800_000,
    "georgia": 3_700_000, "moldova": 2_500_000, "uruguay": 3_400_000,
    "bosnia": 3_200_000, "armenia": 2_700_000, "lithuania": 2_700_000,
    "qatar": 2_700_000, "jamaica": 2_800_000, "botswana": 2_600_000,
    "namibia": 2_600_000, "slovenia": 2_100_000, "latvia": 1_800_000,
    "estonia": 1_300_000, "cyprus": 1_200_000, "luxembourg": 660_000,
    "malta": 530_000, "iceland": 380_000, "panama": 4_400_000,
    "el-salvador": 6_300_000, "honduras": 10_000_000, "nicaragua": 6_800_000,
    "paraguay": 6_800_000, "bolivia": 12_000_000, "puerto-rico": 3_200_000,
    "kenya": 55_000_000, "uae": 9_500_000,
}


def humanize_slug(slug: str) -> str:
    """Convert 'nigeria-akwa-ibom' → 'Akwa Ibom'.

    Strips the country prefix (everything before and including the first hyphen),
    splits the remainder by hyphen, and capitalizes each word.
    """
    # Find first hyphen — everything before it is the country prefix.
    idx = slug.find("-")
    if idx == -1:
        return slug.replace("-", " ").title()
    remainder = slug[idx + 1:]
    return " ".join(word.capitalize() for word in remainder.split("-"))


def _country_slug_from_subregion_slug(sub_slug: str) -> str:
    """Extract country slug from a sub-region slug like 'usa-texas' → 'usa'."""
    idx = sub_slug.find("-")
    return sub_slug[:idx] if idx != -1 else sub_slug


def enrich(opml_base: Path, countries_json: Path, output_path: Path) -> dict:
    """Scan OPML directories and produce countries_enriched.json.

    Args:
        opml_base: Path to feedmine/Resources/Feeds/countries/
        countries_json: Path to countries.json
        output_path: Where to write countries_enriched.json

    Returns:
        The enriched dict (also written to output_path as JSON).
    """
    countries = json.loads(Path(countries_json).read_text(encoding="utf-8"))
    result: dict[str, dict] = {}

    for country_slug, meta in countries.items():
        country_dir = Path(opml_base) / country_slug
        if not country_dir.is_dir():
            continue

        subregions: list[dict] = []
        for opml_file in sorted(country_dir.iterdir()):
            name = opml_file.name
            # Skip the national file (e.g. nigeria.opml), keep sub-regions only
            if not name.startswith(f"{country_slug}-") or not name.endswith(".opml"):
                continue
            sub_slug = name[:-5]  # strip ".opml"
            sub_name = humanize_slug(sub_slug)
            subregions.append({
                "slug": sub_slug,
                "name": sub_name,
                "parent_country": country_slug,
                "iso2": meta["iso2"],
                "iso3": meta["iso3"],
                "ddg_region": meta.get("ddg_region", f'{meta["cctld"]}-{meta["lang"]}'),
                "opml_path": str(country_dir / name),
            })

        pop = POPULATION.get(country_slug, 0)
        result[country_slug] = {
            "name": meta["name"],
            "native_name": meta.get("native_name", meta["name"]),
            "cctld": meta["cctld"],
            "use_cctld": meta["use_cctld"],
            "lang": meta["lang"],
            "ddg_region": meta.get("ddg_region", f'{meta["cctld"]}-{meta["lang"]}'),
            "iso2": meta["iso2"],
            "iso3": meta["iso3"],
            "population": pop,
            "subregions": subregions,
        }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_enrich.py -v
```
Expected: All 6 tests PASS

- [ ] **Step 7: Commit**

```bash
git add scripts/feed_discovery/models.py \
        scripts/feed_discovery/subregion/__init__.py \
        scripts/feed_discovery/subregion/enrich_countries.py \
        scripts/feed_discovery/subregion/test_enrich.py
git commit -m "feat: add SubRegion model and enrich_countries script
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: is_local() heuristic + global blocklist

**Files:**
- Modify: `scripts/feed_discovery/heuristic.py`
- Create: `scripts/feed_discovery/subregion/test_is_local.py`

**Interfaces:**
- Produces: `is_local(url: str, subregion_name: str, country: Country, feed_title: str = "", blocklist: set[str] | None = None) -> tuple[bool, str]`
- Produces: `GLOBAL_BLOCKLIST: set[str]` — domínios que nunca são locais

- [ ] **Step 1: Write test_is_local.py**

```python
# scripts/feed_discovery/subregion/test_is_local.py

from scripts.feed_discovery.heuristic import is_local, GLOBAL_BLOCKLIST, host_of
from scripts.feed_discovery.models import Country

NG = Country("nigeria", "Nigeria", "ng", True, "en", "ng-en", [])


def test_domain_contains_city_name():
    assert is_local("https://lagosnews.com/feed/", "Lagos", NG) == (True, "domain_contains_city")


def test_feed_title_contains_city():
    assert is_local("https://example.com/feed/", "Lagos", NG, feed_title="Lagos Today News") == (True, "title_contains_city")


def test_discovered_by_city_query_fallback():
    assert is_local("https://random-ng-site.com/feed/", "Lagos", NG) == (True, "discovered_by_city_query")


def test_global_blocklist_never_local():
    assert is_local("https://cnn.com/feed/", "Lagos", NG) == (False, "global_blocklist")


def test_bbc_blocklisted():
    assert is_local("https://bbc.com/rss/", "Delhi", NG) == (False, "global_blocklist")


def test_city_name_in_domain_fuzzy():
    # "rio" should match in "riotimesonline.com"
    BR = Country("brazil", "Brazil", "br", True, "pt", "br-pt", [])
    assert is_local("https://riotimesonline.com/feed/", "Rio de Janeiro", BR) == (True, "domain_contains_city")


def test_empty_host_returns_false():
    assert is_local("not-a-url", "Lagos", NG) == (False, "foreign")


def test_host_of_strips_www():
    assert host_of("https://www.kalangonews.com/feed/") == "kalangonews.com"


def test_GLOBAL_BLOCKLIST_contains_major_global():
    assert "cnn.com" in GLOBAL_BLOCKLIST
    assert "bbc.com" in GLOBAL_BLOCKLIST
    assert "nytimes.com" in GLOBAL_BLOCKLIST
    assert "techcrunch.com" in GLOBAL_BLOCKLIST
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_is_local.py -v
```
Expected: All tests FAIL — `is_local` and `GLOBAL_BLOCKLIST` not defined

- [ ] **Step 3: Add is_local() and GLOBAL_BLOCKLIST to heuristic.py**

```python
# Add at the top of heuristic.py, after the imports:

# Domains that are never "local" to any city/region — global outlets.
GLOBAL_BLOCKLIST: set[str] = {
    "cnn.com", "bbc.com", "bbc.co.uk", "nytimes.com", "washingtonpost.com",
    "theguardian.com", "reuters.com", "apnews.com", "bloomberg.com",
    "wsj.com", "economist.com", "techcrunch.com", "theverge.com", "wired.com",
    "arstechnica.com", "engadget.com", "cnet.com", "mashable.com",
    "buzzfeed.com", "vice.com", "vox.com", "politico.com", "huffpost.com",
    "forbes.com", "businessinsider.com", "theatlantic.com", "newyorker.com",
    "npr.org", "aljazeera.com", "france24.com", "dw.com", "rt.com",
    "reddit.com", "medium.com", "substack.com", "spotify.com",
    "apple.com", "google.com", "youtube.com", "facebook.com", "twitter.com",
    "instagram.com", "tiktok.com", "yahoo.com", "msn.com",
}


def is_local(
    url: str,
    subregion_name: str,
    country: Country | None = None,
    feed_title: str = "",
    blocklist: set[str] | None = None,
) -> tuple[bool, str]:
    """Check if a feed URL belongs to a specific sub-region (city/state).

    Uses multiple signals, ordered from strongest to weakest:

    1. **Global blocklist** — domains that are never local.
    2. **Domain contains city** — hostname mentions the city name.
    3. **Feed title contains city** — the feed's <title> mentions the city.
    4. **Fallback** — accept as "discovered by city query" (weakest).

    Args:
        url: Feed URL to classify.
        subregion_name: Human-readable city/region name (e.g. "Lagos").
        country: Parent Country object (for cctld check, not used alone).
        feed_title: Feed title from verification (optional, strengthens signal).
        blocklist: Additional domains to reject (defaults to GLOBAL_BLOCKLIST).

    Returns:
        (is_local_bool, reason_str)
    """
    host = host_of(url)
    if not host:
        return False, "foreign"

    bl = blocklist if blocklist is not None else GLOBAL_BLOCKLIST

    # 1. Global blocklist — fast reject.
    if host in bl or any(host.endswith("." + d) for d in bl):
        return False, "global_blocklist"

    # 2. Domain contains city name (normalised).
    city_lower = subregion_name.lower()
    # Also try individual words for multi-word cities: "Rio de Janeiro" → "rio"
    city_words = [w for w in city_lower.split() if len(w) > 2]
    host_lower = host.lower()

    if city_lower.replace(" ", "") in host_lower.replace("-", "").replace(".", ""):
        return True, "domain_contains_city"
    for word in city_words:
        if word in host_lower:
            return True, "domain_contains_city"

    # 3. Feed title mentions the city.
    if feed_title and city_lower in feed_title.lower():
        return True, "title_contains_city"

    # 4. Fallback — the feed was discovered by a city-targeted query.
    return True, "discovered_by_city_query"
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_is_local.py -v
```
Expected: All 9 tests PASS

- [ ] **Step 5: Verify existing tests still pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_heuristic.py -v
```
Expected: All existing heuristic tests PASS

- [ ] **Step 6: Commit**

```bash
git add scripts/feed_discovery/heuristic.py \
        scripts/feed_discovery/subregion/test_is_local.py
git commit -m "feat: add is_local() heuristic and global blocklist for sub-region classification
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: opml_writer.py — write Candidates to OPML files

**Files:**
- Create: `scripts/feed_discovery/subregion/opml_writer.py`
- Create: `scripts/feed_discovery/subregion/test_opml_writer.py`

**Interfaces:**
- Produces: `write_subregion_opml(opml_path: Path, candidates: list[Candidate]) -> int` — returns count of feeds written
- Produces: `read_existing_feeds(opml_path: Path) -> set[str]` — returns set of normalized URLs already in the OPML

- [ ] **Step 1: Write test_opml_writer.py**

```python
# scripts/feed_discovery/subregion/test_opml_writer.py

import tempfile
from pathlib import Path

from scripts.feed_discovery.models import Candidate
from scripts.feed_discovery.subregion.opml_writer import (
    write_subregion_opml,
    read_existing_feeds,
)


SAMPLE_EMPTY_OPML = """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head>
    <title>Lagos Feeds</title>
  </head>
  <body>
</body>
</opml>
"""

SAMPLE_POPULATED_OPML = """<?xml version="1.0" encoding="UTF-8"?>
<opml version="1.0">
  <head>
    <title>Texas Feeds</title>
  </head>
  <body>
    <outline text="News">
      <outline title="Houston Chronicle" xmlUrl="https://www.houstonchronicle.com/rss" type="rss"/>
    </outline>
</body>
</opml>
"""


def test_write_into_empty_opml():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_EMPTY_OPML)

        candidates = [
            Candidate(url="https://lagosnews.com/feed/", category="News",
                      title="Lagos News", genre=""),
            Candidate(url="https://lagos.podcast.com/feed/", category="Podcasts",
                      title="Lagos Pod", genre="Talk"),
        ]
        count = write_subregion_opml(path, candidates)
        assert count == 2

        result = path.read_text()
        assert "Lagos News" in result
        assert 'xmlUrl="https://lagosnews.com/feed/"' in result
        assert "Lagos Pod" in result
        assert 'xmlUrl="https://lagos.podcast.com/feed/"' in result


def test_write_preserves_existing_feeds():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_POPULATED_OPML)

        candidates = [
            Candidate(url="https://new-texas-blog.com/feed/", category="Blogs",
                      title="New Texas Blog", genre=""),
        ]
        count = write_subregion_opml(path, candidates)
        assert count == 1

        result = path.read_text()
        # Existing feed preserved
        assert "Houston Chronicle" in result
        assert "houstonchronicle.com" in result
        # New feed added
        assert "New Texas Blog" in result
        # Original categories preserved
        assert 'text="News"' in result
        assert 'text="Blogs"' in result


def test_read_existing_feeds_from_empty_opml():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_EMPTY_OPML)
        feeds = read_existing_feeds(path)
        assert feeds == set()


def test_read_existing_feeds_from_populated_opml():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_POPULATED_OPML)
        feeds = read_existing_feeds(path)
        assert "https://www.houstonchronicle.com/rss" in feeds


def test_write_deduplicates_existing():
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "test.opml"
        path.write_text(SAMPLE_POPULATED_OPML)

        candidates = [
            Candidate(url="https://www.houstonchronicle.com/rss", category="News",
                      title="Houston Chronicle", genre=""),
            Candidate(url="https://new-one.com/feed/", category="News",
                      title="New One", genre=""),
        ]
        count = write_subregion_opml(path, candidates)
        # Only the new feed should be written; Houston Chronicle was already there
        assert count == 1
        assert "New One" in path.read_text()
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_opml_writer.py -v
```
Expected: All tests FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write opml_writer.py**

```python
# scripts/feed_discovery/subregion/opml_writer.py

from __future__ import annotations

import xml.etree.ElementTree as ET
from pathlib import Path

from ..models import Candidate
from ..opml import normalize_url


def read_existing_feeds(opml_path: Path) -> set[str]:
    """Return the set of normalized feed URLs already in the OPML file."""
    if not opml_path.exists():
        return set()
    try:
        tree = ET.parse(str(opml_path))
    except ET.ParseError:
        return set()
    root = tree.getroot()
    body = root.find("body")
    if body is None:
        return set()
    urls: set[str] = set()
    for outline in body.findall(".//outline"):
        xml_url = outline.get("xmlUrl")
        if xml_url:
            urls.add(normalize_url(xml_url))
    return urls


def write_subregion_opml(opml_path: Path, candidates: list[Candidate]) -> int:
    """Write candidates into the sub-region OPML, preserving existing content.

    Feeds already present in the OPML (by normalized URL) are skipped.
    New feeds are grouped by candidate.category under <outline text="Category">
    elements. Existing category groups are preserved; new ones are appended.

    Args:
        opml_path: Path to the .opml file (must exist).
        candidates: List of Candidate objects to add.

    Returns:
        Number of feeds actually written (excluding duplicates).
    """
    existing_urls = read_existing_feeds(opml_path)

    # Parse existing OPML
    try:
        tree = ET.parse(str(opml_path))
    except ET.ParseError:
        return 0
    root = tree.getroot()
    body = root.find("body")
    if body is None:
        body = ET.SubElement(root, "body")

    # Index existing category groups by their text attribute
    existing_cats: dict[str, ET.Element] = {}
    for elem in body.findall("outline"):
        text = elem.get("text", "")
        existing_cats[text] = elem

    # Group new candidates by category
    new_by_cat: dict[str, list[Candidate]] = {}
    for c in candidates:
        norm = normalize_url(c.url)
        if norm in existing_urls:
            continue
        cat = c.category or "Other"
        new_by_cat.setdefault(cat, []).append(c)

    written = 0
    for cat, cands in new_by_cat.items():
        if cat in existing_cats:
            parent = existing_cats[cat]
        else:
            parent = ET.SubElement(body, "outline")
            parent.set("text", cat)

        for c in cands:
            attrs = {
                "title": c.title or "",
                "xmlUrl": c.url,
                "type": "rss",
            }
            if c.genre:
                attrs["category"] = c.genre
            child = ET.SubElement(parent, "outline")
            for k, v in attrs.items():
                child.set(k, v)
            written += 1

    # Pretty-print back to file
    _indent_xml(root)
    raw = ET.tostring(root, encoding="unicode")
    opml_path.write_text('<?xml version="1.0" encoding="UTF-8"?>\n' + raw.split("?>", 1)[-1].lstrip(), encoding="utf-8")
    return written


def _indent_xml(elem: ET.Element, level: int = 0) -> None:
    """Add whitespace indentation to an ElementTree for readability."""
    indent = "\n" + "  " * level
    if len(elem):
        if not elem.text or not elem.text.strip():
            elem.text = indent + "  "
        if not elem.tail or not elem.tail.strip():
            elem.tail = indent
        for sub in elem:
            _indent_xml(sub, level + 1)
        if not elem[-1].tail or not elem[-1].tail.strip():
            elem[-1].tail = indent
    else:
        if level and (not elem.tail or not elem.tail.strip()):
            elem.tail = indent
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_opml_writer.py -v
```
Expected: All 5 tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/subregion/opml_writer.py \
        scripts/feed_discovery/subregion/test_opml_writer.py
git commit -m "feat: add opml_writer for sub-region OPML updates with dedup
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: discover_subregion.py — 3-via discovery for one sub-region

**Files:**
- Create: `scripts/feed_discovery/subregion/discover_subregion.py`

**Interfaces:**
- Produces: `async discover_subregion(subregion: SubRegion, country: Country, session: aiohttp.ClientSession, cfg: Config) -> list[Candidate]`
- Produces: `build_subregion_queries(subregion_name: str, country_name: str, native_name: str) -> list[str]`

- [ ] **Step 1: Write test for build_subregion_queries in existing test file**

Add to `scripts/feed_discovery/subregion/test_enrich.py`:

```python
from scripts.feed_discovery.subregion.discover_subregion import build_subregion_queries


def test_build_subregion_queries():
    queries = build_subregion_queries("Lagos", "Nigeria", "Nigeria")
    assert any("Lagos" in q for q in queries)
    assert any("Nigeria" in q for q in queries)
    assert any("news" in q.lower() for q in queries)


def test_build_subregion_queries_with_native_name():
    queries = build_subregion_queries("São Paulo", "Brazil", "Brasil")
    assert any("São Paulo" in q for q in queries)
    assert any("Brasil" in q for q in queries)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_enrich.py::test_build_subregion_queries -v
```
Expected: FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write discover_subregion.py**

```python
# scripts/feed_discovery/subregion/discover_subregion.py

from __future__ import annotations

import asyncio
import json
import time
from urllib.parse import urlencode, urlparse

import aiohttp

from .. import discover, search, verify
from ..heuristic import is_local
from ..models import Candidate, SubRegion
from ..opml import normalize_url
from ..pipeline import Config
from ..sources.youtube import (
    _BROWSER_UA,
    _CHANNEL_ID,
    _CHANNEL_PATH,
    _COUNTRY,
    _OG_TITLE,
    about_url,
    channel_rss_url,
    extract_channel_refs,
    extract_video_urls,
)

ITUNES_SEARCH = "https://itunes.apple.com/search"


def build_subregion_queries(subregion_name: str, country_name: str, native_name: str) -> list[str]:
    """Build DDG search queries for a sub-region's text/news feeds.

    Returns a list of query strings using city name + country name combinations.
    """
    queries = [
        f"{subregion_name} {country_name} news",
        f"{subregion_name} {country_name} newspaper",
        f"{subregion_name} {country_name} blog",
        f"{subregion_name} {country_name} rss",
    ]
    if native_name and native_name != country_name:
        queries.append(f"{subregion_name} {native_name} notícias")
    return queries


def _root_of(url: str) -> str:
    parsed = urlparse(url)
    return f"{parsed.scheme}://{parsed.netloc}"


async def _discover_text(
    subregion: SubRegion,
    country_name: str,
    native_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover text/news feeds for a sub-region via DDG search."""
    candidates: list[Candidate] = []
    seen_feed_urls: set[str] = set()
    root_feeds: dict[str, list[str]] = {}

    queries = build_subregion_queries(subregion.name, country_name, native_name)

    # Collect page URLs from DDG
    page_urls: list[str] = []
    seen_pages: set[str] = set()
    for qi, query in enumerate(queries):
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "search" / f"{qi}.json"
        for url in search.search(
            query, subregion.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
        ):
            if url not in seen_pages:
                seen_pages.add(url)
                page_urls.append(url)

    # Discover feeds from page URLs
    roots = list(dict.fromkeys(_root_of(u) for u in page_urls))
    pending = [r for r in roots if r not in root_feeds]
    sem = asyncio.Semaphore(max(1, cfg.concurrency))

    async def _discover_one(root: str) -> tuple[str, list[str]]:
        async with sem:
            feeds = await discover.discover_feeds(session, root, cfg.timeout)
            return root, feeds

    discovered = await asyncio.gather(*(_discover_one(r) for r in pending))
    for root, feeds in discovered:
        root_feeds[root] = feeds

    # Collect all unique feed URLs
    feed_urls: list[str] = []
    for root in roots:
        for feed in root_feeds.get(root, []):
            norm = normalize_url(feed)
            if norm not in seen_feed_urls:
                seen_feed_urls.add(norm)
                feed_urls.append(feed)

    # Classify & verify
    to_verify: list[tuple[str, str]] = []  # (url, title)
    for feed_url in feed_urls:
        norm = normalize_url(feed_url)
        is_loc, reason = is_local(feed_url, subregion.name, None)  # Country not needed
        if not is_loc:
            continue
        is_new = norm not in existing_urls
        if not is_new:
            candidates.append(Candidate(
                url=feed_url, category="News", title="", genre="",
                national=True, national_reason=reason, is_new=False,
            ))
            continue
        to_verify.append((feed_url, reason))

    # Verify liveness concurrently
    sem_v = asyncio.Semaphore(max(1, cfg.concurrency))

    async def _verify_one(url: str, reason: str) -> Candidate | None:
        async with sem_v:
            is_live, status, title = await verify.verify_feed(session, url, cfg.timeout)
            if is_live and discover.is_comment_feed_title(title):
                is_live = False
            if not is_live:
                return None
            # Re-check is_local with feed title now available
            is_loc2, reason2 = is_local(url, subregion.name, None, feed_title=title)
            if not is_loc2:
                return None
            return Candidate(
                url=url, category="News", title=title, genre="",
                national=True, national_reason=reason2, is_live=True, status_code=status,
            )

    results = await asyncio.gather(*(_verify_one(u, r) for u, r in to_verify))
    for c in results:
        if c is not None:
            candidates.append(c)

    return candidates


async def _discover_podcasts(
    subregion: SubRegion,
    country_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover podcast feeds for a sub-region via iTunes Search API.

    Uses the sub-region name as the primary search term, falling back to
    country name. Filters results to those mentioning the city in title/artist.
    """
    def _itunes_url(term: str) -> str:
        q = urlencode({"term": term, "country": subregion.iso2, "entity": "podcast", "limit": 50})
        return f"{ITUNES_SEARCH}?{q}"

    def _safe(term: str) -> str:
        return "".join(ch if ch.isalnum() else "_" for ch in term)

    candidates: list[Candidate] = []
    seen: set[str] = set()
    city_lower = subregion.name.lower()

    terms = [subregion.name, f"{subregion.name} {country_name}"]
    for term in terms:
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "itunes" / (_safe(term) + ".json")
        if not cfg.fresh and cache_path.exists():
            payload = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            payload = {"results": []}
            try:
                async with session.get(
                    _itunes_url(term),
                    timeout=aiohttp.ClientTimeout(total=cfg.timeout),
                ) as resp:
                    if resp.status == 200:
                        payload = await resp.json(content_type=None)
            except (aiohttp.ClientError, TimeoutError):
                payload = {"results": []}
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            if cfg.delay:
                time.sleep(cfg.delay)

        for r in payload.get("results", []):
            feed = r.get("feedUrl")
            if not feed or feed in seen:
                continue
            # Accept if country matches OR city name appears in title/artist
            country_match = (r.get("country") or "").upper() == subregion.iso3.upper()
            title = r.get("collectionName", "")
            artist = r.get("artistName", "")
            city_mention = city_lower in title.lower() or city_lower in artist.lower()
            if not country_match and not city_mention:
                continue
            seen.add(feed)
            norm = normalize_url(feed)
            if norm in existing_urls:
                candidates.append(Candidate(
                    url=feed, category="Podcasts", title=title,
                    genre=r.get("primaryGenreName", ""),
                    national=True, national_reason="itunes_city_match", is_new=False,
                ))
                continue
            candidates.append(Candidate(
                url=feed, category="Podcasts", title=title,
                genre=r.get("primaryGenreName", ""),
                national=True, national_reason="itunes_city_match",
            ))

    return candidates


async def _discover_youtube(
    subregion: SubRegion,
    country_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover YouTube channels for a sub-region.

    Reuses youtube.py's discovery logic but with city-targeted queries and
    a city-name filter instead of country-name filter.
    """
    # Build city-targeted queries
    queries = [
        f"site:youtube.com {subregion.name} {country_name}",
        f"site:youtube.com {subregion.name}",
    ]
    urls: list[str] = []
    for qi, query in enumerate(queries):
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "youtube_search" / f"{qi}.json"
        urls.extend(search.search(
            query, subregion.ddg_region, cfg.max_results, cache_path, cfg.delay, cfg.fresh
        ))

    city_lower = subregion.name.lower()
    refs = extract_channel_refs(urls)
    seen_refs: set[str] = set(refs)

    # Resolve video URLs to channels
    for vurl in extract_video_urls(urls):
        vcache = cfg.cache_dir / "subregion" / subregion.slug / "youtube_videos" / (
            "".join(ch if ch.isalnum() else "_" for ch in vurl.split("youtube.com/", 1)[-1]) + ".json"
        )
        if not cfg.fresh and vcache.exists():
            cid = json.loads(vcache.read_text(encoding="utf-8")).get("channel_id", "")
        else:
            cid = ""
            try:
                async with session.get(
                    vurl, headers={"User-Agent": _BROWSER_UA},
                    timeout=aiohttp.ClientTimeout(total=cfg.timeout),
                ) as resp:
                    if resp.status == 200:
                        m = _CHANNEL_ID.search(await resp.text())
                        if m:
                            cid = m.group(1)
            except (aiohttp.ClientError, TimeoutError):
                pass
            vcache.parent.mkdir(parents=True, exist_ok=True)
            vcache.write_text(json.dumps({"channel_id": cid}, ensure_ascii=False), encoding="utf-8")
        if cid:
            ref = f"https://www.youtube.com/channel/{cid}"
            if ref not in seen_refs:
                seen_refs.add(ref)
                refs.append(ref)

    # Resolve channel About pages
    candidates: list[Candidate] = []
    seen_ids: set[str] = set()

    for ref in refs:
        chan_slug = "".join(ch if ch.isalnum() else "_" for ch in ref.rstrip("/").split("youtube.com/", 1)[-1])
        cache_path = cfg.cache_dir / "subregion" / subregion.slug / "youtube_channels" / (chan_slug + ".json")

        if not cfg.fresh and cache_path.exists():
            triple = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            cid = country_field = title = ""
            try:
                async with session.get(
                    about_url(ref), headers={"User-Agent": _BROWSER_UA},
                    timeout=aiohttp.ClientTimeout(total=cfg.timeout),
                ) as resp:
                    if resp.status == 200:
                        html = await resp.text()
                        m_id = _CHANNEL_ID.search(html)
                        m_co = _COUNTRY.search(html)
                        m_ti = _OG_TITLE.search(html)
                        cid = m_id.group(1) if m_id else ""
                        country_field = m_co.group(1) if m_co else ""
                        title = m_ti.group(1) if m_ti else ""
            except (aiohttp.ClientError, TimeoutError):
                pass
            triple = {"channel_id": cid, "country": country_field, "title": title}
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(triple, ensure_ascii=False), encoding="utf-8")

        cid = triple.get("channel_id", "")
        title = triple.get("title", "")
        if not cid or cid in seen_ids:
            continue

        # City filter: title or country match
        title_lower = title.lower()
        country_field = triple.get("country", "").strip().lower()
        if city_lower not in title_lower and country_field != country_name.lower():
            continue

        seen_ids.add(cid)
        url = channel_rss_url(cid)
        norm = normalize_url(url)
        if norm in existing_urls:
            candidates.append(Candidate(
                url=url, category="YouTube", title=title, genre="",
                national=True, national_reason="youtube_city_match", is_new=False,
            ))
            continue
        candidates.append(Candidate(
            url=url, category="YouTube", title=title, genre="",
            national=True, national_reason="youtube_city_match",
        ))

    return candidates


async def discover_subregion(
    subregion: SubRegion,
    country_name: str,
    native_name: str,
    existing_urls: set[str],
    session: aiohttp.ClientSession,
    cfg: Config,
) -> list[Candidate]:
    """Discover feeds for a single sub-region using all 3 vias in parallel.

    Args:
        subregion: SubRegion metadata.
        country_name: Parent country's English name (e.g. "Nigeria").
        native_name: Parent country's native name (e.g. "Brasil").
        existing_urls: Set of normalized URLs already in any OPML (for dedup).
        session: Shared aiohttp session.
        cfg: Discovery configuration.

    Returns:
        List of Candidate objects from all 3 vias combined.
    """
    text_cands, podcast_cands, youtube_cands = await asyncio.gather(
        _discover_text(subregion, country_name, native_name, existing_urls, session, cfg),
        _discover_podcasts(subregion, country_name, existing_urls, session, cfg),
        _discover_youtube(subregion, country_name, existing_urls, session, cfg),
    )
    # Deduplicate by normalized URL across vias
    seen: set[str] = set()
    result: list[Candidate] = []
    for c in text_cands + podcast_cands + youtube_cands:
        norm = normalize_url(c.url)
        if norm in seen:
            continue
        seen.add(norm)
        result.append(c)
    return result
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_enrich.py::test_build_subregion_queries \
       feed_discovery/subregion/test_enrich.py::test_build_subregion_queries_with_native_name -v
```
Expected: All 2 tests PASS

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/subregion/discover_subregion.py \
        scripts/feed_discovery/subregion/test_enrich.py
git commit -m "feat: add discover_subregion with 3-via discovery (text, podcasts, YouTube)
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 5: populate.py — orchestrator with progress tracking

**Files:**
- Create: `scripts/feed_discovery/subregion/populate.py`

**Interfaces:**
- Produces: `async populate_country(country_slug: str, enriched: dict, cfg: Config, session: aiohttp.ClientSession) -> dict` — returns summary
- Produces: `async populate_all(enriched_path: Path, opml_base: Path, cfg: Config) -> None`
- Consumes: `enrich_countries.enrich()`, `discover_subregion.discover_subregion()`, `opml_writer.write_subregion_opml()`

- [ ] **Step 1: Write populate.py**

```python
# scripts/feed_discovery/subregion/populate.py

from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path

import aiohttp

from ..models import SubRegion
from ..opml import normalize_url
from ..pipeline import Config
from .discover_subregion import discover_subregion
from .enrich_countries import POPULATION, enrich
from .opml_writer import read_existing_feeds, write_subregion_opml

PROGRESS_FILE = Path(__file__).parent / "progress.json"


def load_progress() -> dict:
    """Load progress tracking, returning empty dict if no progress file exists."""
    if PROGRESS_FILE.exists():
        return json.loads(PROGRESS_FILE.read_text(encoding="utf-8"))
    return {}


def save_progress(progress: dict) -> None:
    """Atomically write progress to disk."""
    tmp = PROGRESS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(progress, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(PROGRESS_FILE)


async def populate_country(
    country_slug: str,
    enriched: dict,
    cfg: Config,
    session: aiohttp.ClientSession,
) -> dict:
    """Populate all sub-region OPMLs for one country.

    Args:
        country_slug: e.g. "nigeria"
        enriched: Full enriched countries dict.
        cfg: Discovery config.
        session: Shared aiohttp session.

    Returns:
        Summary dict: {country_slug, total_subregions, populated, failed, total_feeds}
    """
    country_data = enriched.get(country_slug)
    if not country_data:
        return {"country": country_slug, "error": "not in enriched data"}

    sub_data = country_data.get("subregions", [])
    if not sub_data:
        return {"country": country_slug, "total_subregions": 0, "populated": 0, "failed": 0, "total_feeds": 0}

    country_name = country_data["name"]
    native_name = country_data.get("native_name", country_name)

    # Collect all existing URLs across all sub-regions to feed dedup
    all_existing: set[str] = set()
    for sd in sub_data:
        opml_path = Path(sd["opml_path"])
        if opml_path.exists():
            all_existing |= read_existing_feeds(opml_path)

    sem = asyncio.Semaphore(cfg.concurrency)

    async def _process_one(sd: dict) -> tuple[str, int]:
        sub = SubRegion(
            slug=sd["slug"], name=sd["name"],
            parent_country=sd["parent_country"],
            iso2=sd["iso2"], iso3=sd["iso3"],
            ddg_region=sd["ddg_region"],
            opml_path=sd["opml_path"],
        )
        async with sem:
            try:
                cands = await discover_subregion(
                    sub, country_name, native_name, all_existing, session, cfg
                )
            except Exception:
                return (sd["slug"], -1)

        opml_path = Path(sd["opml_path"])
        if cands:
            written = write_subregion_opml(opml_path, cands)
            return (sd["slug"], written)
        return (sd["slug"], 0)

    results = await asyncio.gather(*(_process_one(sd) for sd in sub_data))

    summary = {
        "country": country_slug,
        "total_subregions": len(sub_data),
        "populated": 0,
        "failed": 0,
        "total_feeds": 0,
    }
    for slug, count in results:
        if count < 0:
            summary["failed"] += 1
        elif count > 0:
            summary["populated"] += 1
        summary["total_feeds"] += max(0, count)

    return summary


async def populate_all(
    enriched_path: Path,
    opml_base: Path,
    cfg: Config | None = None,
) -> None:
    """Run the full sub-region population pipeline for all countries.

    Processes countries in descending population order. Progress is saved
    after each country to `progress.json` so the pipeline can be resumed.

    Args:
        enriched_path: Path to countries_enriched.json.
        opml_base: Path to feedmine/Resources/Feeds/countries/.
        cfg: Optional Config override.
    """
    if cfg is None:
        cfg = Config()

    enriched = json.loads(Path(enriched_path).read_text(encoding="utf-8"))
    progress = load_progress()

    # Sort countries by population descending
    sorted_countries = sorted(
        enriched.keys(),
        key=lambda s: enriched[s].get("population", 0),
        reverse=True,
    )

    connector = aiohttp.TCPConnector(limit=cfg.concurrency)
    async with aiohttp.ClientSession(connector=connector) as session:
        for country_slug in sorted_countries:
            # Skip if already done
            if country_slug in progress and all(
                v in ("done", "failed") for v in progress[country_slug].values()
            ):
                print(f"[SKIP] {country_slug} — already complete")
                continue

            print(f"\n{'='*60}")
            print(f"[{country_slug}] Starting {enriched[country_slug].get('name', country_slug)} "
                  f"(pop: {enriched[country_slug].get('population', 0):,})")
            print(f"{'='*60}")

            t0 = time.monotonic()
            summary = await populate_country(country_slug, enriched, cfg, session)
            elapsed = time.monotonic() - t0

            # Update progress
            country_progress = {}
            for sd in enriched[country_slug].get("subregions", []):
                country_progress[sd["slug"]] = "done"
            progress[country_slug] = country_progress
            save_progress(progress)

            print(f"[{country_slug}] Done in {elapsed:.0f}s — "
                  f"{summary['populated']}/{summary['total_subregions']} populated, "
                  f"{summary['total_feeds']} feeds, "
                  f"{summary['failed']} failed")
```

- [ ] **Step 2: Create the CLI entry point**

Add at the bottom of `populate.py`:

```python
if __name__ == "__main__":
    import sys

    REPO_ROOT = Path(__file__).resolve().parents[3]
    OPML_BASE = REPO_ROOT / "feedmine" / "Resources" / "Feeds" / "countries"
    COUNTRIES_JSON = Path(__file__).resolve().parents[1] / "data" / "countries.json"
    ENRICHED_PATH = Path(__file__).resolve().parents[1] / "data" / "countries_enriched.json"

    if not ENRICHED_PATH.exists():
        print("Generating countries_enriched.json ...")
        enrich(OPML_BASE, COUNTRIES_JSON, ENRICHED_PATH)
        print(f"  → wrote {ENRICHED_PATH}")

    fresh = "--fresh" in sys.argv
    commit = "--commit" in sys.argv
    cfg = Config(fresh=fresh, concurrency=50)

    asyncio.run(populate_all(ENRICHED_PATH, OPML_BASE, cfg))

    if commit:
        import subprocess
        subprocess.run(["git", "-C", str(REPO_ROOT), "add", str(OPML_BASE)])
        subprocess.run(["git", "-C", str(REPO_ROOT), "commit", "-m",
                        f"data: sub-region OPML population run"])
```

- [ ] **Step 3: Run a dry-run smoke test on one country**

```bash
# Run from the scripts/ directory so package imports work
cd scripts && python -m feed_discovery.subregion.populate
```
Expected: Generates `countries_enriched.json`, starts processing India first.
Let it run for 1-2 countries to verify the pipeline works end-to-end, then Ctrl+C.

- [ ] **Step 4: Verify OPML output**

```bash
# Check that at least one sub-region OPML now has content
find feedmine/Resources/Feeds/countries/india -name "*.opml" -exec grep -l 'xmlUrl=' {} \; | head -5
```
Expected: One or more India sub-region OPMLs now contain `xmlUrl` entries.

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/subregion/populate.py \
        scripts/feed_discovery/subregion/progress.json
git commit -m "feat: add populate.py orchestrator with progress tracking and resume
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 6: Integration test — end-to-end on one country

**Files:**
- Create: `scripts/feed_discovery/subregion/test_integration.py`

**Interfaces:**
- Tests full pipeline: enrich → discover → write for a single country with mocked HTTP

- [ ] **Step 1: Write integration test**

```python
# scripts/feed_discovery/subregion/test_integration.py

import json
import tempfile
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

from scripts.feed_discovery.models import Candidate, SubRegion
from scripts.feed_discovery.pipeline import Config
from scripts.feed_discovery.subregion.discover_subregion import discover_subregion
from scripts.feed_discovery.subregion.enrich_countries import enrich, humanize_slug
from scripts.feed_discovery.subregion.opml_writer import read_existing_feeds, write_subregion_opml


@pytest.mark.asyncio
async def test_discover_subregion_returns_candidates():
    """Smoke test: discover_subregion should run without crashing and return a list."""
    sub = SubRegion(
        slug="nigeria-lagos", name="Lagos", parent_country="nigeria",
        iso2="ng", iso3="NGA", ddg_region="ng-en",
        opml_path="/tmp/test.opml",
    )
    cfg = Config(max_results=2, timeout=5, concurrency=2, fresh=False)

    import aiohttp
    async with aiohttp.ClientSession() as session:
        candidates = await discover_subregion(
            sub, "Nigeria", "Nigeria", set(), session, cfg,
        )
    assert isinstance(candidates, list)


def test_enrich_and_write_roundtrip():
    """Test that enrich + write produces valid OPML with feed URLs."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        # Create a minimal countries.json
        countries = {
            "testland": {
                "name": "Testland", "native_name": "Testland",
                "cctld": "tl", "use_cctld": True, "lang": "en",
                "ddg_region": "tl-en", "iso2": "tl", "iso3": "TST",
                "cities": ["Test City"],
            }
        }
        countries_json = tmp / "countries.json"
        countries_json.write_text(json.dumps(countries))

        # Create a sub-region OPML directory with one empty OPML
        opml_dir = tmp / "testland"
        opml_dir.mkdir()
        sub_opml = opml_dir / "testland-test-city.opml"
        sub_opml.write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<opml version="1.0">\n'
            '  <head><title>Test City Feeds</title></head>\n'
            '  <body>\n</body>\n</opml>\n'
        )

        # Run enrich
        enriched_path = tmp / "enriched.json"
        result = enrich(opml_dir.parent, countries_json, enriched_path)

        assert "testland" in result
        assert len(result["testland"]["subregions"]) == 1
        assert result["testland"]["subregions"][0]["name"] == "Test City"

        # Write a candidate to the OPML
        cand = Candidate(
            url="https://testcitynews.com/feed/", category="News",
            title="Test City News", genre="Local",
        )
        count = write_subregion_opml(sub_opml, [cand])
        assert count == 1

        # Read back
        feeds = read_existing_feeds(sub_opml)
        assert "https://testcitynews.com/feed/" in feeds

        # Write again — should dedup
        count2 = write_subregion_opml(sub_opml, [cand])
        assert count2 == 0


def test_humanize_slug_all_patterns():
    assert humanize_slug("usa-texas") == "Texas"
    assert humanize_slug("brazil-rio-de-janeiro") == "Rio De Janeiro"
    assert humanize_slug("romania-bucuresti") == "Bucuresti"
    assert humanize_slug("china-hong-kong") == "Hong Kong"
```

- [ ] **Step 2: Run integration tests**

```bash
cd scripts && python -m pytest feed_discovery/subregion/test_integration.py -v
```
Expected: All 3 tests PASS (the async test will skip if no network, that's fine)

- [ ] **Step 3: Run all subregion tests together**

```bash
cd scripts && python -m pytest feed_discovery/subregion/ -v
```
Expected: All tests PASS

- [ ] **Step 4: Run existing tests to verify no regressions**

```bash
cd scripts && python -m pytest feed_discovery/tests/ -v
```
Expected: All existing tests PASS

- [ ] **Step 5: Final commit**

```bash
git add scripts/feed_discovery/subregion/test_integration.py \
        scripts/feed_discovery/data/countries_enriched.json
git commit -m "test: add integration tests for sub-region pipeline
Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Execution Order

```
Task 1 → Task 2 → Task 3 → Task 4 → Task 5 → Task 6
```

Tasks 1-2 can be done in parallel (independent files). Tasks 3-4 depend on 1-2. Task 5 depends on 3-4. Task 6 is final validation.
