# Task 4 Report: Update ALL_SOURCES with Phase 2 Sources

## Changes Made

**File modified:** `scripts/feed_discovery/tests/test_source_protocol.py`

- Added imports for `PodcastIndexSource`, `DeezerSource`, and `YouTubeAPISource`
- Added `PodcastIndexSource()`, `DeezerSource()`, and `YouTubeAPISource()` to `ALL_SOURCES`
- Updated `test_registry_can_discover_sources` to assert all 5 source names and `len(registry) == 5`

## Test Results

### Phase 2 source tests (44 passed, 4 skipped)
```
44 passed, 4 skipped in 1.47s
```
The 4 skips are live API integration tests (`test_search_returns_candidates`, `test_probe_returns_probe_result`) that correctly skip when API keys are not set.

### Full regression suite (160 passed, 4 skipped, 1 failed)
```
1 failed, 160 passed, 4 skipped in 6.27s
```
The single failure is **pre-existing** (confirmed by testing on unmodified code): `test_ddg_text_source.py::test_search_returns_candidates` fails with `ModuleNotFoundError: No module named 'ddgs'` — a missing dependency unrelated to this task.

No regressions introduced by the Phase 2 source additions.
