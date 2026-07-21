# Feed catalog curation

This directory keeps editorial review artifacts outside the app bundle.

- `staging/discovery-candidates.opml` contains only non-production editorial
  endpoints (empty, failed, or policy-excluded). They are not loaded by
  Feedmine. Synthetic Google News search URLs are deliberately omitted.
- `curation-summary.json` records counts and classification outcomes for the
  current curated release.
- `source-disposition-ledger.csv.gz` accounts for every normalized source
  identity, including production, empty, failed, policy-excluded, and synthetic
  discovery rows.
- `source-placement-decisions.csv.gz` is the audit trail from previous OPML
  memberships to each source's new primary placement and freshness policy.
- `recovery-summary.json` records the recovery queues, retry outcomes, policy
  exclusions, and final ledger reconciliation.
- `policy-exclusions.csv` is the human-reviewed list of compromised, polluted,
  or redundant editorial endpoints. Generic Google News topic queries are
  excluded separately by deterministic policy.
- `source-experience.md` defines the single-home OPML invariant, direct Source
  View, tiered search, history boundary, and personal source collections.
- `validation/unified-search-astronomy-source.png` is the final simulator
  evidence that a content-derived source match opens with its description,
  tags, format, activity, language, and enablement control.

The 2026-07-20 release contains 34,243 analyzed production sources in 118 OPML
files, with zero duplicate placements, invalid outlines, or missing metadata.
Another 6,129 editorial identities remain isolated in staging with an explicit
reason: 1,500 returned no entries, 4,437 failed fetching or parsing, and 192
were excluded by policy. The ledger also records 26,867 synthetic Google News
search URLs, but those are not feeds and are deliberately omitted from staging.
The freshness policy keeps 3,165 dormant current-sensitive or personal sources
searchable but disabled by default; dormant evergreen and archival material
remains enabled.

The original corpus contained 33,927 successful rows. Runtime-equivalent URL
variants (`http/https`, `www`, trailing slash, tracking parameters, or fragment)
collapsed 142 redundant rows into 33,785 physical source identities. Recovery
added 458 production identities, for the final 34,243. The complete ledger is
still exactly 67,239 normalized identities.

### What the old “29 thousand candidates” meant

They were not a second, uniformly ignored half of the catalog. Before recovery,
the complete inventory was 33,785 production sources, 1,481 processed-empty
sources, 4,266 failed sources, 840 editorial sources that had never been tried,
and 26,867 synthetic search-query URLs. The earlier staging export was
incomplete because it did not include all failed rows. The current ledger
retains the full identity universe, while staging retains only non-production
editorial endpoints, so synthetic search queries cannot be mistaken for feeds.

The 840 never-attempted editorial sources were fetched in isolation: 595
returned real content, 15 were empty, and 230 failed. Content samples from up to
five fetched entries per source were used for LLM descriptions and tags. Policy
then excluded 184 generic Google News topic endpoints and three compromised or
redundant feeds, leaving 408 new production sources. A direct retry of 640
recoverable failures found 55 live feeds; five were policy exclusions, so 50
more entered production. See `recovery-summary.json` for the full reconciliation.

Regenerate the production tree and reports from the analyzed Parquet corpus:

```bash
.venv_feeds/bin/python scripts/curate_opml_catalog.py \
  --now 2026-07-20T00:00:00Z
python3 scripts/build_catalog.py \
  --feeds-root build/feed-curation/Feeds \
  --output build/feed-curation/catalog.sqlite \
  --manifest-output build/feed-curation/catalog-manifest.json
```

The curation command never replaces `feedmine/Resources/Feeds`; publishing is
kept as an explicit, reviewable step after its validation report passes.

The runtime search order is sources/tags, saved items, then remaining local
history/cache. Source matches use the bundled catalog's FTS5 index; saved item
identities live in `user.sqlite` and are mirrored as retention pins so the
content cache cannot expunge a bookmark's article body.

Final release validation:

- 46 Python curation, identity, fetch, enrichment, merge, and diagnostics tests;
- 233 Swift unit/integration tests across the store, catalog, engine,
  browser model, and taxonomy (zero failures);
- SQLite `quick_check`, source/FTS/placement parity, and manifest count checks;
- eight focused XCUITests covering onboarding personalization, tiered source
  search, source collections, exact-source long press, and taxonomy categories;
  five catalog-sensitive scenarios were rerun after the final semantic
  refinement (zero failures).
