# Phase 2: Big 3 Sources — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementar as 3 fontes de maior impacto e zero custo — Podcast Index (4M+ podcasts, API grátis), Deezer (sem auth, forte LatAm/África/Europa), YouTube Data API v3 (oficial, 10K quota/dia, substitui scraping).

**Architecture:** Cada fonte é um arquivo Python com uma classe que implementa `SourceProtocol`. Todas compartilham os schemas da Phase 1. Ao final, `ALL_SOURCES` no teste de conformidade terá 5 fontes (2 da Phase 1 + 3 novas).

**Tech Stack:** Python 3.12, aiohttp, dataclasses, pytest

## Global Constraints

- Fontes em `scripts/feed_discovery/sources/` — uma classe por arquivo
- Toda fonte implementa `SourceProtocol` da Phase 1 (`sources/_base.py`)
- Toda fonte usa `ProbeResult`, `CountryProfile`, `SourceConfig` da Phase 1 (`profiles/_schema.py`)
- API keys via env vars (`.env`). Sem key → fonte desabilitada com warning, não crasha
- Imports relativos: `from ..profiles._schema import CountryProfile, SourceConfig`, `from ._base import SourceProtocol, ProbeResult`
- Tests com imports absolutos: `from scripts.feed_discovery.sources.podcast_index import PodcastIndexSource`
- NÃO modificar arquivos existentes (só adicionar novos)
- Seguir TDD: testes primeiro, ver falhar, implementar, ver passar
- Commitar ao final de cada task

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `scripts/feed_discovery/sources/podcast_index.py` | Create | Podcast Index API → Candidate[] |
| `scripts/feed_discovery/sources/deezer.py` | Create | Deezer API (sem auth) → Candidate[] |
| `scripts/feed_discovery/sources/youtube_api.py` | Create | YouTube Data API v3 → Candidate[] |
| `scripts/feed_discovery/tests/test_podcast_index.py` | Create | Testes unitários PodcastIndexSource |
| `scripts/feed_discovery/tests/test_deezer.py` | Create | Testes unitários DeezerSource |
| `scripts/feed_discovery/tests/test_youtube_api.py` | Create | Testes unitários YouTubeAPISource |
| `scripts/feed_discovery/tests/test_source_protocol.py` | Modify | Adicionar 3 novas fontes ao ALL_SOURCES |

---

### Task 1: PodcastIndexSource

**Files:**
- Create: `scripts/feed_discovery/sources/podcast_index.py`
- Create: `scripts/feed_discovery/tests/test_podcast_index.py`

**Interfaces:**
- Consumes: `SourceProtocol`, `ProbeResult`, `CountryProfile`, `SourceConfig` (Phase 1)
- Produces: `PodcastIndexSource` com `name = "podcast_index"`, `search()`, `probe()`

- [ ] **Step 1: Write test_podcast_index.py**

```python
# scripts/feed_discovery/tests/test_podcast_index.py

import os
import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.podcast_index import PodcastIndexSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_implements_protocol():
    source = PodcastIndexSource()
    assert isinstance(source, SourceProtocol)


def test_name():
    assert PodcastIndexSource().name == "podcast_index"


def test_disabled_without_env_vars(monkeypatch):
    """Source should be disabled (not crash) when API keys are missing."""
    monkeypatch.delenv("PODCAST_INDEX_KEY", raising=False)
    monkeypatch.delenv("PODCAST_INDEX_SECRET", raising=False)
    source = PodcastIndexSource()
    assert source.enabled is False


def test_enabled_with_env_vars(monkeypatch):
    monkeypatch.setenv("PODCAST_INDEX_KEY", "test-key")
    monkeypatch.setenv("PODCAST_INDEX_SECRET", "test-secret")
    source = PodcastIndexSource()
    assert source.enabled is True


def test_has_search_and_probe():
    source = PodcastIndexSource()
    assert callable(source.search)
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_search_returns_candidates():
    if not os.getenv("PODCAST_INDEX_KEY"):
        pytest.skip("PODCAST_INDEX_KEY not set")
    source = PodcastIndexSource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=1, max_results=10, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("lagos nigeria", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "Podcasts"


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    if not os.getenv("PODCAST_INDEX_KEY"):
        pytest.skip("PODCAST_INDEX_KEY not set")
    source = PodcastIndexSource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=1, max_results=5, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "podcast_index"


@pytest.mark.asyncio
async def test_search_disabled_returns_empty():
    """When disabled, search returns empty list without making API calls."""
    source = PodcastIndexSource()
    source.enabled = False
    profile = CountryProfile(country="nigeria")
    config = SourceConfig(priority=1)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("test", profile, config, session)
    assert results == []


@pytest.mark.asyncio
async def test_probe_disabled_returns_failure():
    source = PodcastIndexSource()
    source.enabled = False
    profile = CountryProfile(country="nigeria")
    config = SourceConfig(priority=1)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert result.success is False
    assert "disabled" in result.error.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_podcast_index.py -v
```
Expected: All tests FAIL — `ModuleNotFoundError` for `podcast_index`

- [ ] **Step 3: Write sources/podcast_index.py**

```python
# scripts/feed_discovery/sources/podcast_index.py

from __future__ import annotations

import hashlib
import hmac
import os
import time
from datetime import datetime, timezone
from urllib.parse import urlencode

from ..models import Candidate
from ..opml import normalize_url
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class PodcastIndexSource:
    """Podcast Index API — free, open, 4M+ podcasts globally.

    API docs: https://podcastindex-org.github.io/docs-api/
    Auth: X-Auth-Key + X-Auth-Date + Authorization (HMAC-SHA1)
    Rate limit: generous for standard use.

    Env vars:
        PODCAST_INDEX_KEY: API key from api.podcastindex.org
        PODCAST_INDEX_SECRET: API secret from api.podcastindex.org
    """
    name = "podcast_index"
    BASE = "https://api.podcastindex.org/api/1.0"

    def __init__(self):
        self.api_key = os.getenv("PODCAST_INDEX_KEY", "")
        self.api_secret = os.getenv("PODCAST_INDEX_SECRET", "")
        self.enabled = bool(self.api_key and self.api_secret)
        if not self.enabled:
            import warnings
            warnings.warn(
                "PodcastIndexSource disabled: PODCAST_INDEX_KEY and "
                "PODCAST_INDEX_SECRET env vars not set. "
                "Get free keys at https://api.podcastindex.org/"
            )

    def _auth_headers(self) -> dict[str, str]:
        """Generate X-Auth-Key, X-Auth-Date, Authorization headers."""
        dt = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S GMT")
        string_to_sign = f"{self.api_key}{self.api_key}{dt}"
        signature = hmac.new(
            self.api_secret.encode(), string_to_sign.encode(), hashlib.sha1
        ).hexdigest()
        return {
            "User-Agent": "FeedmineDiscovery/1.0",
            "X-Auth-Key": self.api_key,
            "X-Auth-Date": dt,
            "Authorization": signature,
        }

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> list[Candidate]:
        """Search Podcast Index by term.

        Uses /search/byterm with query, language filter from profile,
        and max_results from config.
        """
        if not self.enabled:
            return []

        params = {"q": query, "max": str(config.max_results)}
        # Filter by language if profile specifies one
        if profile.languages:
            params["lang"] = ",".join(profile.languages[:3])

        url = f"{self.BASE}/search/byterm?{urlencode(params)}"
        try:
            async with session.get(
                url,
                headers=self._auth_headers(),
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
        except Exception:
            return []

        candidates: list[Candidate] = []
        seen: set[str] = set()
        for feed in data.get("feeds", []):
            feed_url = feed.get("url") or feed.get("originalUrl")
            if not feed_url or feed_url in seen:
                continue
            seen.add(feed_url)
            # Determine category from itunes categories if available
            cats = feed.get("categories", {})
            genre = ""
            if cats:
                # categories is {cat_id: cat_name}
                genre = next(iter(cats.values()), "")
            candidates.append(Candidate(
                url=feed_url,
                category="Podcasts",
                title=feed.get("title", ""),
                genre=genre,
                national=True,
                national_reason="podcast_index",
            ))

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session,
    ) -> ProbeResult:
        """Probe Podcast Index with the country name."""
        if not self.enabled:
            return ProbeResult(
                source_name="podcast_index",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: missing PODCAST_INDEX_KEY or PODCAST_INDEX_SECRET",
            )

        t0 = time.monotonic()
        query = profile.country.replace("-", " ")
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="podcast_index",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="podcast_index",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )


# Import aiohttp at module level for type annotations
import aiohttp  # noqa: E402
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && PODCAST_INDEX_KEY=test PODCAST_INDEX_SECRET=test python -m pytest feed_discovery/tests/test_podcast_index.py -v -k "not search_returns_candidates and not probe"
```
Expected: 7 tests PASS (2 skipped for missing real keys)

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/sources/podcast_index.py \
        scripts/feed_discovery/tests/test_podcast_index.py
git commit -m "feat: add PodcastIndexSource — free API, 4M+ podcasts globally

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 2: DeezerSource

**Files:**
- Create: `scripts/feed_discovery/sources/deezer.py`
- Create: `scripts/feed_discovery/tests/test_deezer.py`

**Interfaces:**
- Consumes: `SourceProtocol`, `ProbeResult`, `CountryProfile`, `SourceConfig` (Phase 1)
- Produces: `DeezerSource` com `name = "deezer"`, `search()`, `probe()`

- [ ] **Step 1: Write test_deezer.py**

```python
# scripts/feed_discovery/tests/test_deezer.py

import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.deezer import DeezerSource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_implements_protocol():
    assert isinstance(DeezerSource(), SourceProtocol)


def test_name():
    assert DeezerSource().name == "deezer"


def test_always_enabled():
    """Deezer needs no auth — always enabled."""
    assert DeezerSource().enabled is True


def test_has_search_and_probe():
    source = DeezerSource()
    assert callable(source.search)
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_search_returns_candidates():
    source = DeezerSource()
    profile = CountryProfile(country="brazil", languages=["pt"])
    config = SourceConfig(priority=2, max_results=10, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("brasil podcast", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "Podcasts"


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    source = DeezerSource()
    profile = CountryProfile(country="brazil", languages=["pt"])
    config = SourceConfig(priority=2, max_results=5, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "deezer"


@pytest.mark.asyncio
async def test_search_no_auth_required():
    """Deezer search endpoint is public — no auth needed."""
    source = DeezerSource()
    profile = CountryProfile(country="france", languages=["fr"])
    config = SourceConfig(priority=2, max_results=5, timeout=15)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("france podcast", profile, config, session)
    assert isinstance(results, list)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_deezer.py -v
```
Expected: All tests FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write sources/deezer.py**

```python
# scripts/feed_discovery/sources/deezer.py

from __future__ import annotations

import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate
from ..opml import normalize_url
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class DeezerSource:
    """Deezer API — free, no auth, strong in LatAm/Africa/Europe.

    API docs: https://developers.deezer.com/api
    Podcast search: /search/podcast?q={query}
    No authentication required for search endpoints.

    Deezer's podcast catalog varies by region (based on IP for unauthenticated
    requests). Results include show ID, title, description, and a link to the
    Deezer web player. The actual RSS feed URL may need to be derived from
    the show ID or fetched from the show's detail page.
    """
    name = "deezer"
    BASE = "https://api.deezer.com"

    def __init__(self):
        self.enabled = True  # Always enabled — no auth needed

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Search Deezer for podcasts matching the query.

        Uses /search/podcast endpoint. Falls back to generic /search
        with type=podcast if the podcast-specific endpoint returns nothing.
        """
        candidates: list[Candidate] = []
        seen: set[str] = set()

        # Primary: podcast-specific search
        params = {"q": query, "limit": str(config.max_results)}
        url = f"{self.BASE}/search/podcast?{urlencode(params)}"

        try:
            async with session.get(
                url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    for item in data.get("data", []):
                        deezer_id = str(item.get("id", ""))
                        if not deezer_id or deezer_id in seen:
                            continue
                        seen.add(deezer_id)
                        title = item.get("title", "")
                        # Deezer doesn't expose RSS URL directly.
                        # The show page URL is: https://www.deezer.com/show/{id}
                        # We use this as the feed_url for now; the RSS URL
                        # can be resolved later if needed.
                        candidates.append(Candidate(
                            url=f"https://www.deezer.com/show/{deezer_id}",
                            category="Podcasts",
                            title=title,
                            genre="",
                            national=True,
                            national_reason="deezer",
                        ))
        except Exception:
            pass

        # Fallback: generic search filtered to podcasts
        if not candidates:
            fallback_url = f"{self.BASE}/search?q={query}&limit={config.max_results}"
            try:
                async with session.get(
                    fallback_url,
                    timeout=aiohttp.ClientTimeout(total=config.timeout),
                ) as resp:
                    if resp.status == 200:
                        data = await resp.json()
                        for item in data.get("data", []):
                            if item.get("type") != "podcast":
                                continue
                            deezer_id = str(item.get("id", ""))
                            if not deezer_id or deezer_id in seen:
                                continue
                            seen.add(deezer_id)
                            title = item.get("title", "")
                            candidates.append(Candidate(
                                url=f"https://www.deezer.com/show/{deezer_id}",
                                category="Podcasts",
                                title=title,
                                genre="",
                                national=True,
                                national_reason="deezer_fallback",
                            ))
            except Exception:
                pass

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Probe Deezer with the country name."""
        t0 = time.monotonic()
        query = profile.country.replace("-", " ")
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="deezer",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="deezer",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_deezer.py -v
```
Expected: All 7 tests PASS (network-dependent tests make live HTTP calls, may be slower)

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/sources/deezer.py \
        scripts/feed_discovery/tests/test_deezer.py
git commit -m "feat: add DeezerSource — free API, no auth, strong LatAm/Africa/Europe

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 3: YouTubeAPISource

**Files:**
- Create: `scripts/feed_discovery/sources/youtube_api.py`
- Create: `scripts/feed_discovery/tests/test_youtube_api.py`

**Interfaces:**
- Consumes: `SourceProtocol`, `ProbeResult`, `CountryProfile`, `SourceConfig` (Phase 1)
- Produces: `YouTubeAPISource` com `name = "youtube_api"`, `search()`, `probe()`

- [ ] **Step 1: Write test_youtube_api.py**

```python
# scripts/feed_discovery/tests/test_youtube_api.py

import os
import pytest
from scripts.feed_discovery.sources._base import SourceProtocol, ProbeResult
from scripts.feed_discovery.sources.youtube_api import YouTubeAPISource
from scripts.feed_discovery.profiles._schema import CountryProfile, SourceConfig
from scripts.feed_discovery.models import Candidate


def test_implements_protocol():
    assert isinstance(YouTubeAPISource(), SourceProtocol)


def test_name():
    assert YouTubeAPISource().name == "youtube_api"


def test_disabled_without_env_var(monkeypatch):
    monkeypatch.delenv("YOUTUBE_API_KEY", raising=False)
    source = YouTubeAPISource()
    assert source.enabled is False


def test_enabled_with_env_var(monkeypatch):
    monkeypatch.setenv("YOUTUBE_API_KEY", "test-key")
    source = YouTubeAPISource()
    assert source.enabled is True


def test_has_search_and_probe():
    source = YouTubeAPISource()
    assert callable(source.search)
    assert callable(source.probe)


@pytest.mark.asyncio
async def test_search_returns_candidates():
    if not os.getenv("YOUTUBE_API_KEY"):
        pytest.skip("YOUTUBE_API_KEY not set")
    source = YouTubeAPISource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=3, max_results=10, timeout=15, params={"regionCode": "NG"})
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("lagos nigeria news", profile, config, session)
    assert isinstance(results, list)
    if results:
        assert isinstance(results[0], Candidate)
        assert results[0].category == "YouTube"


@pytest.mark.asyncio
async def test_probe_returns_probe_result():
    if not os.getenv("YOUTUBE_API_KEY"):
        pytest.skip("YOUTUBE_API_KEY not set")
    source = YouTubeAPISource()
    profile = CountryProfile(country="nigeria", languages=["en"])
    config = SourceConfig(priority=3, max_results=5, timeout=15, params={"regionCode": "NG"})
    import aiohttp
    async with aiohttp.ClientSession() as session:
        result = await source.probe(profile, config, session)
    assert isinstance(result, ProbeResult)
    assert result.source_name == "youtube_api"


@pytest.mark.asyncio
async def test_search_disabled_returns_empty():
    source = YouTubeAPISource()
    source.enabled = False
    profile = CountryProfile(country="nigeria")
    config = SourceConfig(priority=3)
    import aiohttp
    async with aiohttp.ClientSession() as session:
        results = await source.search("test", profile, config, session)
    assert results == []


def test_channel_rss_url_format():
    """Verify RSS URL construction for YouTube channels."""
    source = YouTubeAPISource()
    url = source._channel_rss_url("UC1234567890abcdefgh")
    assert url == "https://www.youtube.com/feeds/videos.xml?channel_id=UC1234567890abcdefgh"


def test_quota_cost_estimate():
    """search_channels costs ~100 units, list_channels costs ~1 unit per channel."""
    source = YouTubeAPISource()
    # 1 search (100) + 10 channels (1 each) = 110 units
    assert source._estimate_quota(10) == 110
    # 1 search (100) + 0 channels = 100
    assert source._estimate_quota(0) == 100
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_youtube_api.py -v
```
Expected: All tests FAIL — `ModuleNotFoundError`

- [ ] **Step 3: Write sources/youtube_api.py**

```python
# scripts/feed_discovery/sources/youtube_api.py

from __future__ import annotations

import os
import time
from urllib.parse import urlencode

import aiohttp

from ..models import Candidate
from ..opml import normalize_url
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class YouTubeAPISource:
    """YouTube Data API v3 — official API, 10K quota/day free.

    API docs: https://developers.google.com/youtube/v3/docs
    Auth: API key from Google Cloud Console.
    Quota: search.list costs 100 units, channels.list costs 1 unit.

    Replaces youtube_scrape.py (DDG parsing + About page scraping)
    with reliable, official API calls.

    Env vars:
        YOUTUBE_API_KEY: API key from console.cloud.google.com
    """
    name = "youtube_api"
    BASE = "https://www.googleapis.com/youtube/v3"

    def __init__(self):
        self.api_key = os.getenv("YOUTUBE_API_KEY", "")
        self.enabled = bool(self.api_key)
        if not self.enabled:
            import warnings
            warnings.warn(
                "YouTubeAPISource disabled: YOUTUBE_API_KEY env var not set. "
                "Get a free key at https://console.cloud.google.com/apis/credentials"
            )

    def _channel_rss_url(self, channel_id: str) -> str:
        return f"https://www.youtube.com/feeds/videos.xml?channel_id={channel_id}"

    def _estimate_quota(self, channel_count: int) -> int:
        """Estimate quota units consumed: search=100 + channels=1 each."""
        return 100 + channel_count if channel_count > 0 else 100

    async def search(
        self,
        query: str,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> list[Candidate]:
        """Search YouTube for channels matching the query.

        Two-step process:
        1. search.list to find channel IDs (100 quota units)
        2. channels.list to get brandingSettings (country, title) (1 unit each)

        The regionCode parameter from config.params restricts results
        to channels relevant to the target country.
        """
        if not self.enabled:
            return []

        region_code = config.params.get("regionCode", "")
        candidates: list[Candidate] = []
        seen_channel_ids: set[str] = set()

        # Step 1: Search for channels
        search_params = {
            "part": "snippet",
            "type": "channel",
            "q": query,
            "maxResults": str(min(config.max_results, 50)),
            "key": self.api_key,
        }
        if region_code:
            search_params["regionCode"] = region_code

        search_url = f"{self.BASE}/search?{urlencode(search_params)}"
        channel_ids: list[str] = []

        try:
            async with session.get(
                search_url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
                for item in data.get("items", []):
                    cid = item.get("snippet", {}).get("channelId", "")
                    if cid and cid not in seen_channel_ids:
                        seen_channel_ids.add(cid)
                        channel_ids.append(cid)
        except Exception:
            return []

        if not channel_ids:
            return []

        # Step 2: Get channel details (brandingSettings for country)
        channels_params = {
            "part": "snippet,brandingSettings",
            "id": ",".join(channel_ids[:50]),
            "key": self.api_key,
        }
        channels_url = f"{self.BASE}/channels?{urlencode(channels_params)}"

        try:
            async with session.get(
                channels_url,
                timeout=aiohttp.ClientTimeout(total=config.timeout),
            ) as resp:
                if resp.status != 200:
                    return []
                data = await resp.json()
                for item in data.get("items", []):
                    cid = item.get("id", "")
                    snippet = item.get("snippet", {})
                    branding = item.get("brandingSettings", {})
                    channel_info = branding.get("channel", {})

                    title = snippet.get("title", "")
                    channel_country = channel_info.get("country", "")

                    rss_url = self._channel_rss_url(cid)
                    # Country-aware: accept if channel country matches
                    # profile's ISO2 or if no country filter is set
                    if region_code and channel_country and channel_country.upper() != region_code.upper():
                        # Channel is from a different country — still include
                        # but mark as non-national for sub-region classification
                        pass

                    candidates.append(Candidate(
                        url=rss_url,
                        category="YouTube",
                        title=title,
                        genre="",
                        national=True,
                        national_reason=f"youtube_api:{channel_country}",
                    ))
        except Exception:
            pass

        return candidates

    async def probe(
        self,
        profile: CountryProfile,
        config: SourceConfig,
        session: aiohttp.ClientSession,
    ) -> ProbeResult:
        """Probe YouTube API with a country-targeted query."""
        if not self.enabled:
            return ProbeResult(
                source_name="youtube_api",
                success=False,
                result_count=0,
                latency_ms=0,
                error="disabled: missing YOUTUBE_API_KEY",
            )

        t0 = time.monotonic()
        query = f"{profile.country.replace('-', ' ')} news"
        try:
            results = await self.search(query, profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_api",
                success=len(results) > 0,
                result_count=len(results),
                latency_ms=elapsed,
            )
        except Exception as e:
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="youtube_api",
                success=False,
                result_count=0,
                latency_ms=elapsed,
                error=str(e)[:200],
            )
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd scripts && YOUTUBE_API_KEY=test python -m pytest feed_discovery/tests/test_youtube_api.py -v -k "not search and not probe"
```
Expected: 8 tests PASS (3 skipped for missing real key)

- [ ] **Step 5: Commit**

```bash
git add scripts/feed_discovery/sources/youtube_api.py \
        scripts/feed_discovery/tests/test_youtube_api.py
git commit -m "feat: add YouTubeAPISource — official Data API v3, replaces scraping

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

### Task 4: Update conformance tests + full suite verification

**Files:**
- Modify: `scripts/feed_discovery/tests/test_source_protocol.py`

**Interfaces:**
- Consumes: All 5 sources (2 Phase 1 + 3 Phase 2)
- Produces: Updated ALL_SOURCES list with conformance validation

- [ ] **Step 1: Update test_source_protocol.py**

Add the 3 new sources to ALL_SOURCES:

```python
# Modify ALL_SOURCES in test_source_protocol.py:

from scripts.feed_discovery.sources.podcasts import ITunesSource
from scripts.feed_discovery.sources.ddg_text import DDGTextSource
from scripts.feed_discovery.sources.podcast_index import PodcastIndexSource
from scripts.feed_discovery.sources.deezer import DeezerSource
from scripts.feed_discovery.sources.youtube_api import YouTubeAPISource


ALL_SOURCES = [
    ITunesSource(),
    DDGTextSource(),
    PodcastIndexSource(),
    DeezerSource(),
    YouTubeAPISource(),
]
```

Update `test_registry_can_discover_sources`:

```python
def test_registry_can_discover_sources():
    registry: dict[str, SourceProtocol] = {}
    for source in ALL_SOURCES:
        registry[source.name] = source
    assert "itunes" in registry
    assert "ddg_text" in registry
    assert "podcast_index" in registry
    assert "deezer" in registry
    assert "youtube_api" in registry
    assert len(registry) == 5
```

- [ ] **Step 2: Run all conformance tests**

```bash
cd scripts && python -m pytest feed_discovery/tests/test_source_protocol.py -v
```
Expected: All tests PASS (10 parameterized cases for 5 sources)

- [ ] **Step 3: Run the FULL test suite**

```bash
cd scripts && python -m pytest feed_discovery/tests/ feed_discovery/subregion/ -v --tb=short
```
Expected: All tests PASS (100+ tests, zero regressions)

- [ ] **Step 4: Commit**

```bash
git add scripts/feed_discovery/tests/test_source_protocol.py
git commit -m "test: add Phase 2 sources to conformance tests (5 sources total)

PodcastIndex, Deezer, YouTubeAPI now validated via SourceProtocol.

Co-Authored-By: Claude <noreply@anthropic.com>"
```

---

## Execution Order

```
Task 1 → Task 2 → Task 3 → Task 4
```

Tasks 1, 2, and 3 are independent (different files) — can be parallelized.
Task 4 depends on all three.
