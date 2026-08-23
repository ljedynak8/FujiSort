# SPIKE-FINDINGS — PhotoKit diagnostic harness

- Generated: 2026-08-23T01:45:33Z
- Device: iPhone, iOS 27.0
- Launch authorization: **authorized (full)**
- Note: the `fujisort-photokit` skill is not present in this repo/config, so contradictions are checked against **CLAUDE.md** only.

## 1 · Full-res latency under iCloud optimization

**Sample:** 20 images, evenly spread across the library by capture date.
**On-device vs must-download:** determined by requesting original data with `isNetworkAccessAllowed = false` and reading `info[PHImageResultIsInCloudKey]`.

- Classified on-device: 0 · needs-download: 20

**Network disallowed pass:** 20 of 20 requests returned no data (must download).

**`requestImageDataAndOrientation` with network allowed (seconds):**
- on-device: _no assets in this bucket_
- downloaded: min 0.295 s · median 0.402 s · max 0.616 s

**Two full-res images held simultaneously:**
- Sizes: 3541×2348 px, 1569×1098 px
- Footprint: baseline 34.1 MB → peak 59.5 MB (holding 2 decoded images)
- Delta: 25.3 MB


## 2 · Identifier stability

Recorded for 10 assets (spread across the library). Re-run after a device restore and diff this table against the earlier export.

| # | localIdentifier | creationDate | pixels | dHash |
|---|---|---|---|---|
| 1 | `AD9C7734-4310-4266-B13A-ECDED572481F/L0/001` | 2003-09-19T08:00:59Z | 3541×2348 | `1ef6e6e67ec8c1c8` |
| 2 | `638853BE-3D92-44BB-B2A2-415E61614A1E/L0/001` | 2021-07-04T20:54:23Z | 2049×1537 | `184bc7d0d414323f` |
| 3 | `8E849A4B-AB7B-4AFC-81F2-EDBC409558B8/L0/001` | 2022-02-02T19:06:27Z | 1512×2016 | `06dc32322f2f6e3a` |
| 4 | `8F5971DD-9297-4D0D-8D06-827A2B5D9C12/L0/001` | 2022-06-12T17:15:35Z | 3024×4032 | `d11f0d8d8edcfefe` |
| 5 | `2ADBEDBE-1E49-47D7-AEBD-644D9F260D71/L0/001` | 2022-12-02T03:55:11Z | 3024×4032 | `fbcd5dcc8de7efff` |
| 6 | `65EC6BB3-834D-441E-BCAC-1A6F4E228A05/L0/001` | 2023-06-29T03:02:44Z | 3024×4032 | `61c3d232eccc8665` |
| 7 | `B7447212-001F-4562-920D-EF351319E687/L0/001` | 2024-03-17T22:44:40Z | 3024×4032 | `8c84c40e0658b421` |
| 8 | `795A8479-EF02-49F1-AFC2-0A7E04E07C65/L0/001` | 2025-02-24T03:07:41Z | 3024×4032 | `1771f0cece60c167` |
| 9 | `19A23EDF-15C6-45C6-90D7-928B5D744BE2/L0/001` | 2026-02-24T13:52:34Z | 912×1621 | `0170038306060133` |
| 10 | `9815D39C-4C72-4BC5-8332-912CC67ACF32/L0/001` | 2026-05-28T11:25:23Z | 3840×2560 | `10d8b9a44ca868c8` |

**localIdentifier format:** `AD9C7734-4310-4266-B13A-ECDED572481F/L0/001` — a `/`-separated string. Leading segment `AD9C7734-4310-4266-B13A-ECDED572481F` **is a UUID**; trailing segments (e.g. `/L0/001`) are PhotoKit-internal. Nothing in the string is an obviously human-readable device or library name, but whether the UUID survives a restore is exactly what the re-run measures — do not assume it is stable until confirmed.


## 3 · Persistent change tokens

**API surface:** `PHPhotoLibrary.shared().currentChangeToken -> PHPersistentChangeToken`; `func fetchPersistentChanges(since: PHPersistentChangeToken) throws -> PHPersistentChangeFetchResult`. Enumerate the result for `PHPersistentChange`, then `changeDetails(for: .asset)` → inserted/updated/deleted local identifiers. **iOS floor: 16.0.**

**Baseline token saved.** Now add a photo to the library (take one, or import), relaunch the app, and run this diagnostic again to see the change reported. Forcing a stale token on demand is not possible; if expiry occurs on a real run the error type is reported here.


## 4 · Fuji metadata survival

Found a Fuji-origin asset after scanning 35 recent images.

**EXIF fields present:**
| Field | Value |
|---|---|
| Make (TIFF) | FUJIFILM |
| Model (TIFF) | X100VI |
| LensModel (Exif) | — |
| LensModel (Aux) | — |
| ExposureTime | 0.02941176470588235 |
| ISOSpeedRatings | 200 |
| FNumber | 2 |
| SubjectArea (focus) | — |

**Maker note:** ImageIO did **not** expose a Fuji maker-note dictionary (`kCGImagePropertyMakerFujiDictionary` absent). Film simulation is not readable via ImageIO on this asset.

**Resources (RAW vs JPEG):** `public.jpeg` (1). RAW present: no — JPEG only.

**EXIF read time (one asset):** 0.001 s — fast enough to read inline.


## 5 · Arrival vs capture date

**No public "date added":** `PHAsset` exposes only `creationDate` and `modificationDate`; there is no arrival-date property. Confirmed.

**`.smartAlbumRecentlyAdded`:** 281 assets. creationDate window inside it: 2003-09-19T08:00:59Z … 2026-08-23T00:49:51Z.

**Capture vs arrival:** an asset in Recently Added has creationDate 2026-06-20T21:40:52Z — older than 30 days while appearing in Recently Added. So `creationDate` reflects **capture**, not arrival. Confirmed.


## 6 · Limited-access behaviour

**Current authorization:** authorized (full).
**Fetch-everything (`fetchAssets(with: nil)`) returns:** 11852 assets.

Full access. To measure limited behaviour: Settings → Privacy & Security → Photos → FujiSort → **Limited**, then re-run this diagnostic. Under limited, the fetch count above will drop to the selected subset and `presentLimitedLibraryPicker` becomes available.


## 7 · What is actually in this library

**Whole-library counts**
| Metric | Count |
|---|---|
| Total assets | 11852 |
| Images | 10613 |
| Videos | 1239 |
| Screenshots (`.photoScreenshot`) | 1020 |
| Time-lapses (`.videoTimelapse`) | 8 |
| Live Photos (`.photoLive`) | 3144 |
| Portraits (`.photoDepthEffect`) | 406 |
| Panoramas (`.photoPanorama`) | 10 |
| User-library (`.typeUserLibrary`) | 11852 |
| Cloud-shared (`.typeCloudShared`) | 0 |
| iTunes-synced (`.typeiTunesSynced`) | 0 |
| Fuji by EXIF Make (**sample of 40**) | 6 |

Screen recordings: **not separately countable** — PhotoKit exposes no dedicated subtype.

**Bursts:** `includeAllBurstAssets` default → 10613 images; set to `true` → 10614 images. The `true` setting returns every frame (representatives-only is the default and is wrong for this app).

**Realistic deck preview** (images · no screenshots · user library · all burst frames): 9594 assets — 80.9% of the raw total.

**Last 30 days shape:** 23 distinct capture-day clusters; sizes 67, 66, 28, 13, 6, 4, 4, 4, 3, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1.


## Contradictions

- Q4: No Fuji maker-note dictionary via ImageIO — film simulation unreadable. CLAUDE.md expects Fuji metadata to degrade to absent; confirmed.

## Method limits
- Screen recordings have no dedicated `PHAssetMediaSubtype`; they cannot be counted distinctly and are reported as an unmeasurable gap, not zero.
- Q1 downloads real iCloud originals; timings for cloud assets include network transfer.
- Q4 Fuji-find and Q7 Fuji-count read original data per asset, so they scan a capped sample and say so.
- Q2 (post-restore) and Q3 (post-add-photo) require a second manual run; state is persisted so the re-run completes them.
- Simulator libraries are synthetic — these numbers are only meaningful on the physical device.
