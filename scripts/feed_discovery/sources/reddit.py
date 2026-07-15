# scripts/feed_discovery/sources/reddit.py

from __future__ import annotations

import time

from ..models import Candidate
from ..profiles._schema import CountryProfile, SourceConfig
from ._base import ProbeResult


class RedditSource:
    """Reddit RSS feeds — every subreddit has native Atom RSS at /r/{name}/.rss.

    Generates RSS URLs for country/city subreddits, language communities,
    and niche interest subreddits. No API key required — Reddit RSS is
    open and free.

    The app fetches the RSS content when the user subscribes, so we don't
    pre-fetch here (avoids Reddit's rate limiting).
    """

    name = "reddit"

    # Global high-quality niche subreddits (language-agnostic)
    GLOBAL_NICHE = [
        "science", "technology", "space", "history", "books",
        "philosophy", "AskHistorians", "TrueReddit", "depthhub",
        "Foodforthought", "indepthstories", "longtext",
        "economics", "linguistics", "anthropology",
    ]

    # Country-specific subreddits
    _COUNTRY_SUBS: dict[str, list[str]] = {
        "brazil": ["brasil", "conversas", "futebol", "livros"],
        "india": ["india", "indiasocial", "indiansports", "indianbooks"],
        "usa": ["news", "politics", "science", "technology", "books"],
        "uk": ["unitedkingdom", "ukpolitics", "london"],
        "canada": ["canada", "onguardforthee", "toronto", "vancouver"],
        "germany": ["de", "germany", "berlin"],
        "france": ["france", "paris"],
        "japan": ["japan", "newsokur", "tokyo"],
        "australia": ["australia", "melbourne", "sydney"],
        "mexico": ["mexico"],
        "argentina": ["argentina"],
        "spain": ["spain", "es", "madrid", "barcelona"],
        "italy": ["italy", "italia"],
        "netherlands": ["thenetherlands", "amsterdam"],
        "sweden": ["sweden", "stockholm"],
        "nigeria": ["nigeria"],
        "kenya": ["kenya"],
        "south-africa": ["southafrica", "capetown"],
        "philippines": ["philippines"],
        "indonesia": ["indonesia"],
        "turkey": ["turkey"],
        "russia": ["russia", "moscow"],
        "portugal": ["portugal", "porto", "lisboa"],
        "poland": ["poland", "polska"],
        "austria": ["austria", "wien"],
        "switzerland": ["switzerland", "zurich"],
        "belgium": ["belgium", "brussels"],
        "norway": ["norway"],
        "denmark": ["denmark"],
        "finland": ["finland"],
        "ireland": ["ireland"],
        "new-zealand": ["newzealand"],
        "singapore": ["singapore"],
        "malaysia": ["malaysia"],
        "thailand": ["thailand"],
        "vietnam": ["vietnam"],
        "colombia": ["colombia"],
        "chile": ["chile"],
        "peru": ["peru"],
        "egypt": ["egypt"],
        "saudi-arabia": ["saudiarabia"],
        "uae": ["dubai", "abudhabi"],
        "pakistan": ["pakistan"],
        "bangladesh": ["bangladesh"],
        "south-korea": ["korea"],
        "taiwan": ["taiwan"],
        "ukraine": ["ukraine"],
        "czech-republic": ["czech"],
        "romania": ["romania"],
        "hungary": ["hungary"],
        "greece": ["greece"],
        "bulgaria": ["bulgaria"],
        "serbia": ["serbia"],
        "croatia": ["croatia"],
        "slovenia": ["slovenia"],
        "slovakia": ["slovakia"],
        "lithuania": ["lithuania"],
        "latvia": ["latvia"],
        "estonia": ["estonia"],
        "israel": ["israel"],
        "morocco": ["morocco"],
        "tunisia": ["tunisia"],
        "ghana": ["ghana"],
        "ethiopia": ["ethiopia"],
        "senegal": ["senegal"],
        "venezuela": ["vzla"],
        "cuba": ["cuba"],
        "bolivia": ["bolivia"],
        "paraguay": ["paraguay"],
        "uruguay": ["uruguay"],
        "costa-rica": ["costarica"],
        "panama": ["panama"],
        "dominican-republic": ["dominican"],
        "puerto-rico": ["puertorico"],
        "jamaica": ["jamaica"],
        "iceland": ["iceland"],
        "luxembourg": ["luxembourg"],
        "malta": ["malta"],
        "cyprus": ["cyprus"],
    }

    def __init__(self):
        self.enabled = True

    def _slug_to_sub(self, name: str) -> str:
        """Convert a city/country name to a Reddit subreddit slug."""
        return name.lower().replace(" ", "").replace("-", "").replace(".", "")

    def _make_sub_candidate(self, sub: str, country: str, reason: str) -> Candidate:
        return Candidate(
            url=f"https://www.reddit.com/r/{sub}/.rss",
            category="Forum",
            title=f"r/{sub}",
            genre="",
            national=bool(country),
            national_reason=reason,
        )

    async def search(
        self, query: str, profile: CountryProfile,
        config: SourceConfig, session,
    ) -> list[Candidate]:
        country_slug = (profile.country or "").lower()
        candidates: list[Candidate] = []
        seen: set[str] = set()

        # Strategy 1: Country subreddits from static map
        country_subs = self._COUNTRY_SUBS.get(country_slug, [])
        for sub in country_subs:
            if sub not in seen:
                seen.add(sub)
                candidates.append(self._make_sub_candidate(
                    sub, country_slug, f"reddit:country:{country_slug}",
                ))

        # Strategy 2: Country name itself as subreddit (e.g., r/brazil)
        country_sub = self._slug_to_sub(country_slug)
        if country_sub not in seen:
            seen.add(country_sub)
            candidates.append(self._make_sub_candidate(
                country_sub, country_slug, f"reddit:country_name:{country_slug}",
            ))

        # Strategy 3: Language subreddits from profile languages
        for lang in profile.languages[:3]:
            lang_sub = f"learn{lang}" if len(lang) == 2 else lang.lower()
            if lang_sub not in seen:
                seen.add(lang_sub)
                candidates.append(self._make_sub_candidate(
                    lang_sub, country_slug, f"reddit:lang:{lang}",
                ))
            # Also try just the language code
            if lang not in seen:
                seen.add(lang)
                candidates.append(self._make_sub_candidate(
                    lang, country_slug, f"reddit:lang_code:{lang}",
                ))

        # Strategy 4: Global niche subreddits (quality content)
        for sub in self.GLOBAL_NICHE:
            if sub not in seen and len(candidates) < config.max_results:
                seen.add(sub)
                candidates.append(self._make_sub_candidate(
                    sub, "", f"reddit:global:{sub}",
                ))

        return candidates[:config.max_results]

    async def probe(
        self, profile: CountryProfile,
        config: SourceConfig, session,
    ) -> ProbeResult:
        t0 = time.monotonic()
        try:
            results = await self.search("", profile, config, session)
            elapsed = (time.monotonic() - t0) * 1000
            return ProbeResult(
                source_name="reddit", success=len(results) > 0,
                result_count=len(results), latency_ms=elapsed,
            )
        except Exception as e:
            return ProbeResult(
                source_name="reddit", success=False,
                result_count=0, latency_ms=(time.monotonic() - t0) * 1000,
                error=str(e)[:200],
            )
