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


@dataclass
class Candidate:
    url: str
    category: str
    title: str = ""
    source_page: str = ""
    national: bool = False
    national_reason: str = ""
    is_live: bool = False
    status_code: int = 0
    is_new: bool = True
