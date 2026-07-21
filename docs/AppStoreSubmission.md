# App Store submission preflight

This document records the release facts and outstanding App Store Connect work
for FeedMine's first public iOS submission. It is a release checklist, not a
privacy policy or legal advice.

## Release facts

| Field | Current value |
|---|---|
| App name | FeedMine |
| Bundle ID | `com.feedmine.app` |
| Version / build | `1.0` / `1` |
| Minimum OS | iOS 18.0 |
| Devices | iPhone |
| Account required | No |
| Advertising / tracking SDK | None identified |
| In-app purchase | None identified |

## Privacy implementation

- `PrivacyInfo.xcprivacy` declares the required-reason APIs used by the app:
  - `UserDefaults` (`CA92.1`) for app-private settings.
  - File timestamps (`C617.1`) for local cache ordering and cleanup.
- The app does not include analytics, advertising, account, or tracking code in
  the current source audit.
- No location APIs or weather service are included in the release build.

## Required before upload

- [ ] Create or confirm the App Store Connect record for `com.feedmine.app`.
- [ ] Create a public privacy-policy URL that accurately covers local reading
  data, user-added feeds, and direct requests to public feed publishers.
- [ ] Set the App Privacy answers to match the executable build.
- [ ] Create an App Store distribution certificate and provisioning profile, or
  confirm that automatic signing selects them for an archive.
- [ ] Archive a Release build and validate it in Xcode Organizer.
- [ ] Upload the archive to App Store Connect / TestFlight.
- [ ] Supply App Store metadata: subtitle, description, keywords, support URL,
  marketing URL, copyright, category, age rating, and review contact.
- [ ] Capture the required iPhone screenshots from the approved release build.
- [ ] Complete export-compliance questions after inspecting the archive.
- [ ] Test the exact archive on a physical device and submit to TestFlight
  before App Review.

## Suggested App Review notes

FeedMine is a local-first RSS, podcast, YouTube, video, and forum reader. It
does not require an account. Users can add their own feeds or choose sources
from the bundled catalog. The app fetches public feed URLs directly and stores
reading state locally. It does not request the device's location.
