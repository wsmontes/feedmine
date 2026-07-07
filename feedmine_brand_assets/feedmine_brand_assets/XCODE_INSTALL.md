# Installing feedmine App Icon in Xcode

1. Open the project in Xcode.
2. In Finder, open this asset package.
3. Copy `AppIcon.appiconset`.
4. Paste it into:

```text
feedmine/Resources/Assets.xcassets/
```

5. If Xcode asks to replace the existing AppIcon set, choose Replace.
6. Build and run on simulator or iPhone.

Optional:
- Keep `AppIcon-Dark.appiconset` as an alternative, but do not enable both at the same time unless you configure alternate app icons later.
- The Coral / Gold / Rust / Berry / Mono renders are previews for iOS 18's
  tinted and mono icon appearances. To wire these up as selectable alternate
  icons, add entries under `CFBundleIcons > CFBundleAlternateIcons` in
  Info.plist and build matching `.appiconset` folders for each.
