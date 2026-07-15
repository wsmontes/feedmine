# Task 4: Fix ImportPipeline data integrity

**Status:** Complete

**Commit:**
- `b5ed08c`

**Changes made to `feedmine/Services/ImportPipeline.swift`:**

### 4a: Preserve duplicate URL categories (lines ~189-198)

Replaced `Dictionary(parsedSources.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })` with explicit deduplication: iterates `parsedSources`, normalizes each URL via `OPMLParser.normalizeURL`, and only keeps the first occurrence via a `Set<String>` of seen URLs. The `titleMap` is now built with `Dictionary(uniqueKeysWithValues:)` (safe since keys are guaranteed unique), and `urls` is derived from `dedupedSources` so `ingest()` receives deduplicated URLs too.

### 4b: Guard OPMLImportDelegate stacks against XMLParser error recovery

Added `parserDidEndDocument(_:)` and `parser(_:parseErrorOccurred:)` methods to `OPMLImportDelegate` that clear both `categoryStack` and `outlinePushStack`, preventing desync when XMLParser skips `didEndElement` calls after a fatal parse error.

**Build:**
```
xcodebuild -project feedmine.xcodeproj -scheme feedmine \
  -destination 'platform=iOS Simulator,name=iPhone 14 Plus' build
```
**BUILD SUCCEEDED**
