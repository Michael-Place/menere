# P27-T0 — Apple TV screensaver curation: feasibility findings

**Question (Michael):** "Can Apple TV use OUR content as the screensaver?"
**Short answer:** Yes — via **Photos**, and the curation is **fully automatable** with a **single
one-time user step**. tvOS has **no third-party screensaver API**, so the only path to being the
true system screensaver is to put our best family shots into a Photos album the TV points at. We
proved on-device that PhotoKit lets us create + fill that album programmatically.

This document is the deliverable answering the open question in the roadmap: *how automatic can the
new-photo flow be, given iCloud Shared Albums' limited programmatic write?*

---

## What the spike actually did (proven on the simulator)

`PhotoCurationClient` (new MenerePackage target) was exercised end-to-end via an in-app harness
(`PhotoCurationDemoView`, reached by the DEBUG `-photoCurationSpike` launch argument). Live run log:

```
Existing add-only status: authorized
Authorization: authorized
Ensuring album "Bacán — TV"…
Album id: A872D351-A4F9-454F-BD67-2241FEBB9E3B/L0/040
Adding 2 sample images…
Added 2 asset(s).
New asset ids: B6CF8856, 245B208D
Album now holds 2 asset(s). ✅
```

The album was **created**, **two images saved as new `PHAsset`s and added**, and a **re-query of
the album returned 2** — the writes really landed. Evidence: `PhotoCuration-spike.png` (success log)
and `PhotoCuration-consent-prompt.png` (the one-time system consent picker).

### Exact PhotoKit calls used
- Auth: `PHPhotoLibrary.authorizationStatus(for: .addOnly)` / `(for: .readWrite)`;
  `PHPhotoLibrary.requestAuthorization(for: .readWrite) { … }`.
- Find album: `PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular,
  options:)` with `NSPredicate(format: "title = %@", name)`.
- **Create** album: `PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle:)`
  → `request.placeholderForCreatedAssetCollection.localIdentifier`, then re-fetch via
  `fetchAssetCollections(withLocalIdentifiers:options:)`.
- **Add images**: `PHAssetCreationRequest.forAsset()` +
  `addResource(with: .photo, data:, options:)` → `placeholderForCreatedAsset`; then
  `PHAssetCollectionChangeRequest(for: album).addAssets(_:)`. All inside a single
  `PHPhotoLibrary.shared().performChanges(_:completionHandler:)`.
- Verify: `PHAsset.fetchAssets(in: album, options:).count`.

---

## THE definitive shared-album finding

**Regular (user) album — FULLY AUTOMATABLE.** ✅
PhotoKit can create a regular `PHAssetCollection` and add assets to it freely and repeatedly, with
no per-add prompt. This is what the app should curate into. The only gate is a **one-time** Photos
permission grant per install ("Allow Full Access"), which is unavoidable and normal.

**iCloud Shared Album — NOT automatable (no public write API).** ❌
Investigated the PhotoKit shared-album surface directly:
- There is **no** creation API for a shared album. `creationRequestForAssetCollection(withTitle:)`
  always makes a **regular** collection; there is no `.albumCloudShared` creation variant, and no
  `CloudSharedAlbum` change-request type exists in PhotoKit.
- `PHAssetCollection` with `subtype == .albumCloudShared` is **read-only** to PhotoKit — it surfaces
  shared albums that already exist (created by the user in Photos), but a
  `PHAssetCollectionChangeRequest(for:)` on one cannot add assets (the collection reports it can't
  perform add-content mutations). You cannot `addAssets` into a shared album programmatically.
- The only way to *create/publish* a shared album is the **user** doing it in the Photos app
  (New Shared Album), or Apple's share sheet — neither is scriptable. (CloudKit `CKShare` shares
  `CKRecord`s, not `PHAsset`s; it is not a path to iCloud Shared Photo Albums.)

**Conclusion:** full hands-off *shared-album* publishing is **impossible** from code. But — and this
is the important part — **we don't need a shared album at all** for the Apple TV screensaver.

---

## Why a regular album is enough (the mechanism that makes it automatic)

The Apple TV screensaver (Settings → Screen Saver → Photos) can point at **any album in the iCloud
Photos library the TV is signed into — regular albums included, not just Shared Albums.** If the
curating iPhone has **iCloud Photos** turned on and the Apple TV is signed into the **same Apple ID
/ family library**, then:

1. The app adds a `PHAsset` to the regular "Bacán — TV" album (automatic, no prompt after the
   one-time grant).
2. iCloud Photos syncs that asset + album membership to the cloud automatically.
3. The Apple TV, pointed at that album, shows the new photo on its next screensaver cycle — **no
   further user action**.

So new photos **do** flow automatically on an ongoing basis. Shared Albums would only be required if
the TV were signed into a *different* Apple ID than the phone — a case we should avoid by pointing
the TV at the family's iCloud Photos account.

---

## Recommended UX

- **App curates album "Bacán — TV"** automatically: the P27 pipeline (subject-lifted pets, plant
  milestones, kid moments) drops each chosen shot into the regular `PHAssetCollection` via
  `PhotoCurationClient.addImages(_:toAlbumNamed:)`. First run triggers the one-time Photos
  "Allow Full Access" consent; after that, adds are silent and repeatable.
- **One-time user step on the Apple TV:** Settings → Screen Saver → Photos → **Bacán — TV**. Done
  once, ever.
- **New photos flow automatically** thereafter via **iCloud Photos sync** — provided (a) the phone
  has iCloud Photos on, and (b) the Apple TV is signed into the same iCloud/family library. No
  shared album, no re-share, no ongoing taps.
- **Caveat to surface in-app:** if the family's Apple TV uses a different Apple ID, there is no
  automatable path (shared-album writes aren't allowed by PhotoKit); the fix is to point the TV at
  the family iCloud Photos account, which we should recommend during setup.

**Bottom line:** T0 is low-code and real. Ship `PhotoCurationClient` + a "Curate for the TV" action
and a short setup card explaining the one-time TV screensaver pick. Skip Shared Albums entirely.

---

## Files delivered by this chunk
- `ios/MenerePackage/Sources/PhotoCurationClient/PhotoCurationClient.swift` — the reusable
  `@DependencyClient`.
- `ios/MenerePackage/Sources/PhotoCurationClient/PhotoCurationDemoView.swift` — throwaway spike
  harness (removable with the `AppView` launch-arg branch).
- `ios/MenerePackage/Tests/PhotoCurationClientTests/PhotoCurationClientTests.swift` — unit tests.
- `PhotoCuration-spike.png`, `PhotoCuration-consent-prompt.png` — on-device evidence.
