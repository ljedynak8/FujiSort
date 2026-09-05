---
name: fujisort-photokit
description: FujiSort's PhotoKit contract — library access, session scoping, the internal store and asset identity, the image pipeline, album sync, and deletion. Use when touching any code that reads the photo library, persists judgments, or writes back to Apple Photos.
---

# FujiSort PhotoKit contract

> **Confidence markers.** **[solid]** — long-standing framework behaviour, safe to design against. **[likely]** — believed correct, worth a quick check. **[verify]** — genuinely uncertain; confirm before depending on it. These come from the project's research notes, not from device testing. If reality differs, say so rather than working around it silently.

## There is no import

The photos are **already in Apple Photos** — the camera's wireless transfer puts them there before FujiSort runs. The app reads the library in place and keeps only its own judgments. No copying, no second library, no pixel storage. **[solid]**

## Access

`PHPhotoLibrary.requestAuthorization(for: .readWrite)`. **[solid]**

**Limited library access is not a supported mode.** It would show only hand-picked photos, which is the work the app exists to avoid. Request full access; if only limited is granted, explain plainly what the app cannot do rather than degrading into a confusing half-working state. **[likely]**

`PHPickerViewController` is not a substitute — it hands back items rather than a browsable library, and its identifiers still need library authorization to resolve. **[likely]**

## How the deck fills: unjudged, not recent

**A capture-date high-water mark cannot work here.** Photos shot Saturday and transferred Tuesday carry Saturday's `creationDate`, so a Tuesday watermark skips the entire take. The transfer-days-later pattern makes capture date useless as a progress marker.

Three mechanisms, layered:

**1. The store is the truth.** A photo belongs in the deck if there is **no judgment record for it**. `PHFetchResult` is lazily evaluated and database-backed, so enumerating identifiers across a large library without touching image data is cheap **[likely]**; subtracting a `Set<String>` of judged identifiers gives the deck exactly. This is always correct and is the reconciliation path after a restore.

**2. Persistent change tokens give the real "since last open."** `PHPhotoLibrary.shared().currentChangeToken`, persisted between launches, and `fetchPersistentChanges(since:)`. **[likely — verify the API surface and iOS floor]** Unlike `PHPhotoLibraryChangeObserver`, which only fires while registered and running, this survives termination. It reports *library insertions* rather than anything derived from EXIF, so Tuesday's transfer registers on Tuesday.

Tokens can expire or be rejected **[verify]**. Treat token failure as routine and fall back to mechanism 1.

**3. Recently Added is a first-run scope, not an incremental mechanism.** `.smartAlbumRecentlyAdded` is a rolling system window. It answers "what arrived lately," never "what arrived since you last looked."

### Arrival finds them; capture date groups them

- **Arrival** (change token) determines *what is in the queue*.
- **Capture date** determines *how the queue divides into sessions* — clustering by gaps recovers "Saturday's outing" and "Sunday morning" as separate takes even though both arrived in one Tuesday transfer.

Using arrival for both lumps two days together; using capture date for both loses the take entirely.

## What enters the deck

Camera-agnostic, **not** media-agnostic. A Fuji outing is a clean batch of photographs; an everyday iPhone library is a mixed trickle containing a great deal that isn't photography at all. Both must sort, so the filter is on *media kind*, never on camera.

Build the fetch predicate from these:

| Rule | Mechanism |
|---|---|
| Images only | `PHAsset.mediaType == .image` **[solid]** |
| No screenshots | `NOT ((mediaSubtypes & %d) == %d)` — see the bitmask trap below **[measured]** |
| User's own captures only | `PHAssetSourceType.typeUserLibrary` — excludes cloud-shared and iTunes-synced **[likely]** |
| Every burst frame | `PHFetchOptions.includeAllBurstAssets = true` — **defaults to `false`**, which returns representatives only **[likely — verify]** |

**Set `includeAllBurstAssets = true` regardless — but the reasoning has changed.** Measured on the real library: default returns 10,613 images, `true` returns 10,614. **One frame in the whole library.** **[measured]** iOS burst *groups* are effectively absent here, so they cannot be the justification for the compare design.

**Compare is justified by near-duplicates, not by bursts** — the many similar frames a photographer takes in sequence, which PhotoKit does not group and cannot detect for you. Set the flag anyway (it is free and correct), but do not build burst-specific affordances, and do not assume a burst representative is hiding alternatives.

### The `mediaSubtypes` bitmask trap

**`NSPredicate` does not evaluate `(mediaSubtypes & bit) == 0` the way Swift would.** It collapses to `mediaSubtypes == 0`, which matches only assets with *no* subtype flags at all — silently dropping every Live Photo, HDR, panorama, and depth-effect asset.

Measured on the real library, milestone 03:

| Predicate form | Deck size | |
|---|---|---|
| `(mediaSubtypes & bit) == 0` | 5,127 | wrong — drops 3,144 Live Photos and more |
| `(mediaSubtypes & bit) != bit` | 5,127 | wrong, same collapse |
| `NOT ((mediaSubtypes & bit) == bit)` | 9,593 | **correct** |

**Only the negated bit-set form works.** Use it for any subtype exclusion, not just screenshots.

**This class of bug cannot be caught by unit tests with injected data** — the predicate is only evaluated by PhotoKit, against a real library. It passed milestone 02's full test suite and surfaced only when real assets hit it. **Any change to a fetch predicate must be verified by counting against the real library**, and the expected count is in `SPIKE-FINDINGS.md` §7.

Live Photos are ordinary images with a video component; sort them as stills and ignore the motion. Portraits, panoramas, HDR and RAW all sort normally.

Screenshot exclusion is a **user setting**, defaulting to off. Videos are out of scope for v1 — if a design decision starts to assume video support, flag it rather than building it.

None of this is a quality judgment. These filters decide what is a *photograph*; nothing here decides which photographs are good.

### iPhone libraries behave differently from Fuji outings

Worth designing for, not just tolerating:

- **Capture-date clustering produces many tiny sessions** — three photos Tuesday, one Wednesday — rather than a few large ones. The count pill will often read `Tuesday · 3`. That is correct behaviour, not a bug.
- **The trickle has no natural batch boundary.** Change-token arrivals may be single photos rather than a transfer of hundreds.
- **Most everyday photos are utility shots** that deserve one swipe right and nothing more. The `Keep` verdict already handles this; do not add a separate lightweight path for them.

## The identity problem

`PHAsset.localIdentifier` is the obvious key and is stable in normal use **[solid]** — but it is **not** stable across a device restore or migration, and the same photo has different identifiers on different devices sharing an iCloud library. **[likely]**

Mitigations, all worth doing from the start:

- **Store a fallback fingerprint alongside the identifier** — creation date, pixel dimensions, and ideally a small perceptual hash — so records can be re-matched after a restore. **This cannot be added retroactively for existing records**, so it must be written at record-creation time.
- **Implement `PHPhotoLibraryChangeObserver` from day one** **[solid]** to keep up with deletions and edits happening elsewhere. Without it the store accumulates references to photos that no longer exist.
- **Treat a missing asset as dormant, not deleted.** Do not discard a judgment because the asset can't be found this launch.

## The image pipeline

`PHCachingImageManager` with `startCachingImages(for:targetSize:contentMode:options:)` keeps the deck fluid — prefetch ahead of the current card, evict behind it. `PHImageRequestOptions.deliveryMode = .opportunistic` gives a fast low-quality image immediately followed by a better one. **[solid]**

**This is not a hazard, it is the steady state.** Measured on the real library: **0 of 20 sampled originals were on-device. All 20 required a network download.** With `isNetworkAccessAllowed = false`, all 20 returned no data. **[measured]**

Full-resolution latency, network allowed: **min 0.295 s · median 0.402 s · max 0.616 s** — on good wifi. **[measured]** That clears the redesign threshold (hundreds of milliseconds, not seconds), so sticky zoom survives. But it means:

- **Prefetch is mandatory, not an optimization.** Every uncached full-res view costs a round trip.
- **Zoom must degrade gracefully.** Use `deliveryMode = .opportunistic` so a low-quality image appears immediately and sharpens on arrival. Never block the gesture on the download.
- **These numbers are the good case.** Cellular or weak wifi will be worse, and culling away from home is a real scenario. Never assume the 400 ms.
- Holding two decoded full-res images cost 25.3 MB (peak 59.5 MB). **[measured]** Memory is not a constraint — but note nothing is ever shown side by side anyway, so this rarely arises.

This lands directly on zoom, since 1:1 is exactly the operation that needs the original:

- **Sort-mode springy zoom must tolerate showing an upscaled preview and sharpening when the original lands.** The gesture masks the wait. This is load-bearing, not a nicety.
- **Analysis needs a visible loading state** — the wait may be seconds on a poor connection.
- **Prefetch should speculatively pull originals** for the current card and its immediate neighbours, not just thumbnails.

## Fuji metadata

EXIF requires reading actual image data — `PHImageManager.requestImageDataAndOrientation`, then `CGImageSourceCopyPropertiesAtIndex` from ImageIO to read properties without a full decode. **[likely]** Too slow to do inline for hundreds of photos; use a background pass or evaluate lazily when a photo reaches analysis.

Camera make and model are ordinary EXIF and reliably distinguish a Fuji frame from an iPhone one — measured `FUJIFILM` / `X100VI`. **[measured]**

**Film simulation is not readable. Settled, not open.** ImageIO exposed no Fuji maker-note dictionary at all (`kCGImagePropertyMakerFujiDictionary` absent) on a real transferred frame. **[measured]** The wireless transfer produces JPEG only — no RAW. **[measured]** Do not build a film-simulation facet, do not put it in a HUD, and do not spend a milestone trying to recover it. If it ever becomes available it is new work, not deferred work.

**What a Fuji frame actually carries**, measured: make, model, `ExposureTime`, `ISOSpeedRatings`, `FNumber`. **Absent:** `LensModel` (both Exif and Aux), `SubjectArea` (focus point), maker note, RAW. **[measured]**

**EXIF parsing is 1 ms; getting the bytes to parse is ~400 ms.** The parse is free, the fetch is not — see the image pipeline below. Reading EXIF for a photo already in hand is inline-cheap; reading it across a session is a background pass. **[measured]**

## What can be written back

**PhotoKit cannot store arbitrary metadata.** There is no API for custom keywords, star ratings, or colour labels on a `PHAsset`. **[solid]** The writable surface is:

| Writable | How |
|---|---|
| Favorite flag | `PHAssetChangeRequest(for:).isFavorite` **[solid]** |
| Album membership | `PHAssetCollectionChangeRequest` **[solid]** |
| Deletion | `PHAssetChangeRequest.deleteAssets(_:)` **[solid]** |

This is why the internal store is a necessity rather than a preference — tiers and compare history have nowhere else to live.

**Never write `isFavorite` by default.** Overwriting the user's own hearts destroys information the app didn't create and cannot restore. Offer it as an explicit opt-in; read it freely as an input signal.

## Album sync

Each tier maps to an album with a namespaced title — `FujiSort · Portfolio`, `FujiSort · Strong`. Album membership is a **reference, not a copy** **[solid]**, so it costs no storage and the photo does not move. Lightroom and Snapseed read the Photos library, so the picks are visible to them the moment the album exists.

**One-way, app as source of truth.** The store is the truth; the album is a projection. If they diverge, the app rewrites the album. Do not implement two-way sync: removing a photo from the album in Photos is ambiguous (deliberate? album deleted? tidying?), and reconciling it silently loses judgments the user made.

**Timing:** write when the user leaves the review — backgrounding, navigating away, or finishing. Not continuously as tiers change, which would thrash while judgments are being revised. Sync is idempotent; the worst case of running it again is rewriting the same membership. Batch changes into one `performChanges` block. **[solid]**

Album sync is opt-in **once**, at first finish, then automatic and revocable in settings. Consent to the mechanism, not to each firing.

## Deletion

`deleteAssets` triggers a **system confirmation dialog the app cannot suppress** **[solid]**, and deleted photos go to Recently Deleted for 30 days rather than vanishing. **[solid]**

The confirmation makes per-photo deletion during a fast pass impossible — one modal per swipe would destroy the sorting rhythm. So: **rejects are marked, never deleted immediately, and offered as a single batch deletion at session end.** One prompt for ninety photos instead of ninety prompts. State the 30-day recovery window in the confirmation.

Deletion is the only irreversible thing the app does, and it is the only decision that belongs on the finish screen.
