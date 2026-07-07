# feedmine Brand Assets

Generated asset package for the iOS app. This is the "Warm editorial" direction —
a Wawasoft-family variation that keeps the shared symbol geometry and neutrals,
with a new accent gradient tuned for a reading product.

## Recommended usage

### Primary app icon
Use:

```text
AppIcon.appiconset
```

Copy this folder into:

```text
feedmine/Resources/Assets.xcassets/
```

Then select `AppIcon` as the app icon set in Xcode if needed.

### Main logo / wordmark
Use:

```text
Wordmark-Horizontal-Light-Transparent.png
Wordmark-Horizontal-Dark-Transparent.png
Wordmark-Horizontal.svg
```

### Symbol-only logo
Use:

```text
Symbol-Gradient-Transparent-1024.png
Symbol-White-Transparent-1024.png
Symbol-Ink-Transparent-1024.png
Symbol-Gradient.svg
Symbol-Ink.svg
```

(Also provided at 512 / 256 / 128 for in-app UI, favicons, and smaller placements.)

### Splash / welcome screen
Use:

```text
Splash-iPhone14Plus-Dark.png
```

### Alternate app icons (iOS tinted appearance)
Use:

```text
AppIcon-Coral-1024.png
AppIcon-Gold-1024.png
AppIcon-Rust-1024.png
AppIcon-Berry-1024.png
AppIcon-Mono-Light-1024.png
AppIcon-Mono-Dark-1024.png
```

These are full-render previews of iOS 18 tinted/mono appearance options. If you
configure real alternate icons in Xcode, generate matching `.appiconset` folders
from these the same way `AppIcon.appiconset` was built.

## Color direction — Warm editorial

Primary gradient:

```text
Amber       #FFB238
Coral       #FF7A45
Deep coral  #E8483C
```

Shared Wawasoft neutrals (unchanged across the family):

```text
Ink       #141C2A
Deep navy #050A18
Muted text #5E6473
```

## What changed vs. the wawa-note mark, and what didn't

- **Unchanged:** the symbol's path geometry, stroke weight, dot size and
  placement, the ink/navy neutrals, and the two-tone wordmark construction
  (base word in ink, suffix in the accent color).
- **Changed:** only the gradient — cyan/blue/purple became amber/coral/deep
  coral, a warmer palette suited to a reading product ("feed" stays ink,
  "mine" carries the new accent, echoing the wawa-note / -note split).

## Product fit

The mark is unchanged from the shared Wawasoft symbol:

- rounded waveform-like W, reused as-is for family recognition
- soft dot for AI/assistant presence, recolored to the new accent
- rounded geometry for native iOS friendliness
- warm gradient signals "reading / editorial" rather than "recording / audio"

## Notes

- App icon PNG files are square and opaque, as expected for iOS app icons.
- Transparent PNGs are intended for in-app UI, splash screens, documents, and marketing.
- SVG files are useful for future refinement or web/marketing usage.
- Wordmark text is set in Poppins Bold as a stand-in for the system font used
  in the original wawa-note kit (SF Pro Display); swap the font-family in
  `Wordmark-Horizontal.svg` if you want to match SF Pro exactly on macOS.
