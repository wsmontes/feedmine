# Source experience

This document defines how catalog placement, search, direct source browsing,
and personal source collections fit together.

## One source, one editorial home

The canonical source identity is its normalized feed URL. Each production
source has one physical OPML placement. The OPML folder and file path determine
its editorial home and menu order; numeric folder prefixes are ordering
metadata, not part of the visible category name.

Tags, media format, language, activity, and default-enabled state are virtual
facets. They can surface one source in many discovery experiences without
copying it into more OPML files. Personal collections also reference this same
identity and never move or duplicate its OPML placement.

## Search order and navigation

Unified search presents results in this order:

1. content-analyzed sources, including title, description, and tags;
2. articles explicitly saved by the user;
3. other articles still present in the local content database.

Choosing a source result opens Source View. Choosing an article opens that
article. Source View is also available directly from a card's long-press menu
and from a source inside a personal collection. `Source` is the product term
for RSS/Atom feeds, YouTube channels, podcasts, forums, and other feed-backed
publishers.

Taxonomy names are not globally unique. Search therefore ranks exact matches
first, the primary editorial taxonomy before country/language/import branches,
then shallower and better-covered nodes. Results display their ancestor path
so a global topic and `Countries › Ireland` remain distinguishable.

## Explicit source loading and history boundary

Opening Source View is explicit intent. Feedmine refreshes that source even if
it is dormant or disabled in the automatic feed, persists every post returned
by the current endpoint payload, and merges those posts with all locally
retained history for the same normalized URL. This does not silently enable the
source for future automatic refreshes.

RSS and Atom do not define a universal archive protocol. “All source posts”
therefore means all posts currently exposed by the feed plus older posts still
retained locally; it does not promise every page in the publisher's website
archive. The Source View states this boundary and links to the website when one
is known.

An explicitly opened source receives a rolling 30-day exception from the
ordinary per-source cache cap. Bookmarked articles retain their existing,
independent persistence protection.

## Personal source collections

Source Collections are reusable live filters, similar to playlists. Their
membership is many-to-many: a bundled or imported source can belong to any
number of collections. Membership lives in `user.sqlite` as the normalized
source URL plus small display snapshots. Deleting a collection or removing a
member deletes only user state, never a catalog source, imported source, or
OPML classification.

Opening a collection refreshes each member source with bounded concurrency and
merges up to 1,000 available posts. A collection does not grant long-term
retention to every member, which prevents a large playlist from pinning an
unbounded content database. Opening an individual member in Source View does
grant the explicit-source retention window described above.
