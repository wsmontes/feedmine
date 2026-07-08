from __future__ import annotations

from scripts.feed_discovery import report
from scripts.feed_discovery.models import Candidate


def _cand(cat, national, reason, live, new):
    return Candidate(url="https://x.br/f", category=cat, national=national,
                     national_reason=reason, is_live=live, is_new=new)


def test_summarize_counts():
    cands = [
        _cand("News", True, "cctld", True, True),
        _cand("News", True, "cctld", True, False),   # not new (dedup)
        _cand("Sports", False, "blocked", False, True),
        _cand("Sports", False, "foreign", False, True),
    ]
    s = report.summarize("brazil", cands)
    assert s["slug"] == "brazil"
    assert s["total"] == 4
    assert s["national"] == 2
    assert s["blocked"] == 1
    assert s["foreign"] == 1
    assert s["live"] == 2
    assert s["new"] == 1
    assert s["per_category_new"]["News"] == 1


def test_render_markdown_has_country_heading():
    s = report.summarize("brazil", [_cand("News", True, "cctld", True, True)])
    md = report.render_markdown([s])
    assert "brazil" in md
    assert "| News |" in md
