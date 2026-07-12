from __future__ import annotations

from dataclasses import dataclass, field


@dataclass
class Country:
    slug: str
    name: str
    cctld: str
    use_cctld: bool
    lang: str
    ddg_region: str
    allowlist: list[str] = field(default_factory=list)
    native_name: str = ""
    cities: list[str] = field(default_factory=list)
    iso2: str = ""
    iso3: str = ""


@dataclass
class SubRegion:
    slug: str              # "nigeria-lagos"
    name: str              # "Lagos"
    parent_country: str    # "nigeria"
    iso2: str              # "ng"
    iso3: str              # "NGA"
    ddg_region: str        # "ng-en"
    opml_path: str = ""    # absolute path to the .opml file


@dataclass
class Candidate:
    url: str
    category: str
    title: str = ""
    genre: str = ""
    source_page: str = ""
    national: bool = False
    national_reason: str = ""
    is_live: bool = False
    status_code: int = 0
    is_new: bool = True
