# Feedmine — In-App Article Reader Design Spec

**Date:** 2026-07-01
**Scope:** Replace ArticlePreviewSheet with direct in-app article reading via WKWebView

## Concept

Tap on any card opens the full article in a sheet via WKWebView. The card in the feed IS the preview — no intermediate screen. A single Safari button in the top-right serves as fallback for sites that don't render well in the WebView.

## Flow

```
Tap card → .sheet(.large) → ArticleReaderView (WKWebView) → swipe down → back to feed
                                    ↓
                           [Safari button] → system browser (fallback)
```

## What Changes

- **Remove:** `ArticlePreviewSheet.swift` (entire file)
- **Remove:** `selectedArticle: ArticleRoute?` state (unused after change)
- **Remove:** `SafariView` in FeedScreen (inline SFSafariViewController wrapper)
- **Modify:** `FeedScreen` — tap opens reader instead of preview
- **Create:** `ArticleReaderView.swift` — new view with WKWebView

## ArticleReaderView

```swift
struct ArticleReaderView: View {
    let item: FeedItem
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ArticleWebView(url: URL(string: item.url))
                .ignoresSafeArea(edges: .bottom)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Link(destination: URL(string: item.url)!) {
                            Image(systemName: "safari")
                        }
                    }
                }
        }
    }
}
```

- WKWebView with reader-friendly configuration (no popups, minimal JS)
- Single Safari button in toolbar as fallback
- Swipe down to dismiss
- No title, no chrome — focus on content

## ArticleWebView (UIViewRepresentable)

- Wraps WKWebView
- Configuration: suppresses popups, disables data detectors, basic navigation
- Loads the article URL directly
- User can scroll and read full article within the sheet

## Files

- Create: `feedmine/Views/ArticleReaderView.swift`
- Delete: `feedmine/Views/ArticlePreviewSheet.swift`
- Modify: `feedmine/Views/FeedScreen.swift` (remove preview, wire reader)

## Acceptance

- Tap card → sheet opens with full article via WKWebView
- Sheet dismisses by swiping down
- Safari button opens system browser (no second modal)
- No ArticlePreviewSheet remains in the project
