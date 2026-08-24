# FujiSort

**This file is read at the start of every session.** It carries the settled rules for FujiSort — scope, interaction model, vocabulary, and design system. Corrections found while building get folded back in here.

---

FujiSort is an iPhone app for **culling photos** — the step between shooting hundreds of frames in a day and knowing which handful are worth editing. It works over the photos already in the Apple Photos library.

## Scope boundaries

These are settled. Do not build past them, and do not propose features that cross them.

- **Sorting only.** No editing. Editing happens in Lightroom and Snapseed.
- **Acting, not looking.** Every state exists to make a decision. Browsing finished work happens in Apple Photos. Do not build galleries, slideshows, or presentation views.
- **Fuji-aware, never Fuji-dependent.** Any photo in the library must be sortable, including native iPhone photos. Fuji metadata is a bonus facet that degrades to absent — and measured, most of it *is* absent: camera make and model survive the transfer, but **film simulation, lens, and focus point do not**. Do not design around them. **Never filter the deck by camera** — no code path may treat a Fuji frame as more sortable than an iPhone one.

## What counts as sortable

The deck is camera-agnostic but **not** media-agnostic. An everyday iPhone library holds a lot that isn't photography, and feeding it into the deck would break the rhythm the whole design rests on.

| Included | Excluded (v1) |
|---|---|
| Images from any camera, Fuji or iPhone | Videos, screen recordings, time-lapses |
| Live Photos — sorted as stills, video component ignored | Screenshots |
| Portraits, panoramas, HDR, RAW | Cloud-shared and iTunes-synced assets |
| All frames of a burst, not just the representative | |

- **Screenshots are excluded by default**, with a setting to include them. They are not photographs and would interrupt a pass.
- **Videos are out of scope for v1.** Culling video is a different problem — say so if a design decision starts to assume video support.
- **Bursts show every frame.** The default fetch returns representatives only; that is wrong here, because choosing between burst frames is precisely what the app exists for.

Every exclusion is a filter on what enters the deck, never a judgment about quality. Nothing here decides which photographs are good — see the automation boundary.

## The automation boundary

> **Automation may reduce how much has to be waded through. It may not do the looking or the judging.**

Ordering a queue, grouping likely duplicates, and flagging technically broken frames are allowed. Scoring photographs for quality, hiding likely rejects, and deciding where in a frame the user should look are not. When a feature is ambiguous, apply this test.

## Interaction model

Two states. **Sort is home; analysis is a per-photo detour.**

**Sort** — full-bleed card deck, one photo.

| Gesture | Meaning |
|---|---|
| Swipe left | Reject |
| Swipe right | Keep — fine, not for analysis |
| Swipe up | Candidate — worth a closer look |
| Swipe down | Skip — decide later |
| Pinch | Zoom, **springs back on release** |
| Tap | Enter analysis |

A count pill is always visible, showing the current outing's remaining count.

**Analysis** — entered by tapping. Zoom **sticks**. HUD available. The four verdicts appear as buttons. Three exits:

| Action | Result |
|---|---|
| Verdict | commits, advances, returns to sort |
| Annotation (colour, pin) | applies, stays in analysis |
| Cancel | returns to sort, same photo, nothing recorded |

**Analysis never navigates the queue.** It may move within a set the user explicitly assembled (a compare set), never through the deck.

**Comparison** is analysis with a filmstrip: one photo full screen, thumbnails of the selected set along the bottom, tap or swipe to move between them. Zoom position carries across switches. **Nothing is ever shown side by side.**

## Vocabulary

**Pass 1 verdicts:** Reject · Keep · Candidate · Skip.

**Pass 2 tiers:** Portfolio · Strong. Candidates arrive in Strong; promote to Portfolio or demote out (which returns them to Keep and removes them from the review). **Portfolio is uncapped** — photos are never evicted to make room.

The pass-1 **Keep** verdict and the pass-2 tiers are distinct concepts. Do not introduce a "Keep" tier.

## Rules that are already decided

- **Comparison is always user-initiated.** The app never starts one on its own.
- **A verdict commits and advances. An annotation stays.** True regardless of whether it was triggered by swipe or button.
- **Zoom is free pinch, aimed by the user.** No algorithmic targeting — do not jump to detected faces or eyes.
- **Undo covers the store, never the library.** One stack per app run, unlimited depth, no redo.
- **Album sync runs when the user leaves the review**, not on a Finish button. It is idempotent and one-way: the store is the truth, the album is a projection.
- **`isFavorite` is never written** unless explicitly opted into. Reading it is fine.
- **Rejects are deleted as one batch at session end**, never per photo.
- **The deck is "photos with no verdict recorded."** No cursor, no saved position. A *record* is not a *verdict* — records legitimately exist without one (created-then-undone, or dormant after the asset was deleted elsewhere), and those photos stay in the deck.
- **Deck order is newest outing first, capture order ascending within each outing.** Not pure chronological order: with unjudged photos going back to 2003, a purely ascending deck would open in the distant past, which contradicts [decision 0003](../03-decisions/0003-first-run-starts-with-the-most-recent-take.md). The scoped PhotoKit fetch sorts ascending; the deck builder reverses at the *cluster* level, never within one.
- **Skip removes a photo from the current pass, not from the session.** When the deck runs out, skipped photos come back for another lap, offered rather than forced — *"14 skipped — another lap?"* — followed by any pinned set. This is what makes Skip mean "decide later" instead of "decide never", and it is why Skip is still a verdict: the lap is defined by the verdict, not by tracking membership.
- **Sessions are labels, not containers.** A session is a capture-date cluster used for naming and grouping on screen. It never scopes a queue.

## Visual design

**The photograph is the content. Everything else defers to it.** The interface is dark and achromatic because colour near a photograph contaminates perception of colour in it, and a light surround shifts perceived exposure.

- Surfaces: `#0B0B0C` (deck, analysis), `#141416` (review grid), `#1C1C1E` (raised chrome). **Never pure black.**
- Ink is white at opacity — 92% / 60% / 38% — not fixed greys, so it composites over photographs.
- **One saturated colour in the app: `#E0A33C`, reserved for Portfolio.** Verdict colour is transient only and never persists next to an image.
- SF Pro throughout. No custom or serif faces. Monospaced digits on numeric values.
- Photos are full-bleed: no inset, corner radius, border, or shadow.
- Haptics are the primary confirmation channel in sort mode, with a distinct signature per verdict.

**Do not use the default AI aesthetic** — cream backgrounds, serif display type, terracotta accents, editorial layout. A cream background is the worst possible surround for judging a photograph. Full system in the `fujisort-design` skill; use its values as specified, and if one seems wrong, say so rather than substituting.

## Data model rules

- Judgments live in the app's own store. **PhotoKit cannot store custom metadata** — there is no API for ratings, keywords, or colour labels on a `PHAsset`.
- Records are keyed by `PHAsset.localIdentifier` **plus a fallback fingerprint** (creation date, pixel dimensions, perceptual hash). The fingerprint must be written at record-creation time; it cannot be backfilled.
- There is no import step. The app reads the library in place and never copies pixels.

## Project facts

- Scheme: FujiSort
- Test target: FujiSortTests
- UI test target: FujiSortUITests
- Testing framework: Swift Testing (unit tests) · XCTest (UI tests) — see setup notes
- Minimum iOS: 26.0 — clears every feature minimum (highest is 18.0); personal single-device tool, no older install base to support.
- Bundle identifier: com.fianchetto.FujiSort
- Photo library usage key: NSPhotoLibraryUsageDescription
- Persistence: SwiftData
- Library access: PhotoKit, full authorization required (limited access is not a supported mode)

## What the spike measured

Milestone 01, on the real device and library. These are facts now, not assumptions — see `SPIKE-FINDINGS.md`.

- **Nothing is on-device.** 0 of 20 sampled originals were local; all required a network download. **Prefetch is mandatory and zoom must sharpen progressively** (`deliveryMode = .opportunistic`), never block on the download.
- **The number that matters is time-to-first-pixel: ~3 ms.** Time-to-sharp ranges 148 ms to over 1 s (measured 1067 ms for a 24 MP original on a contended connection). Never treat 400 ms as a guarantee — it was a median on a good single request.
- **`NSPredicate` mistranslates `mediaSubtypes` bit tests.** `(mediaSubtypes & bit) == 0` collapses to `mediaSubtypes == 0` and silently drops every Live Photo, HDR, panorama, and depth asset. Only `NOT ((mediaSubtypes & bit) == bit)` is correct. **Any fetch-predicate change must be count-verified against the real library** — unit tests with injected data cannot catch this, and did not.
- **The deck is ~9,594 photos** — 80.9% of an 11,852-asset library after filtering. Screenshots alone remove 1,020.
- **iOS bursts are effectively absent** (one extra frame library-wide). Compare exists for near-duplicates, which PhotoKit does not group for you — not for burst frames.
- **Sessions really are tiny.** Last 30 days: 23 capture-day clusters, sizes 67, 66, 28, 13, then mostly 1–4. A count pill reading `Tuesday · 1` is correct behaviour.
- **Persistent change tokens exist** with an iOS 16.0 floor — comfortably under the 26.0 target.
- **`creationDate` is capture, not arrival.** Confirmed: assets appear in Recently Added with creation dates months old.
- **Still open:** whether `localIdentifier` survives a device restore (needs a post-restore re-run). The fallback fingerprint is therefore **mandatory**, not belt-and-braces.

## Milestone map

Numbering starts at **00**. Where a session says "milestone N", this is N.

| | | |
|---|---|---|
| 00 | Project scaffold — create project, deployment target, device build | done |
| 01 | PhotoKit spike — throwaway diagnostics on a real library | done — see spike section above |
| 02 | Store and asset identity — judgments, fingerprints, change tokens | next |
| 03 | Library layer and image pipeline — session scoping, caching, prefetch | |
| 04 | Pass 1 deck — four swipe verdicts, count pill, undo | |
| 05 | Analysis state — sticky zoom, HUD, verdict buttons, filmstrip compare | |
| 06 | Review view — tiles, tier filters, movement, compare | |
| 07 | Finish — album sync on leaving review, batch reject deletion | |
| 08 | First-run experience | |

**01 was the gate and it passed** — full-resolution latency cleared the redesign threshold. Its measurements are above and are binding. The asset fingerprint remains mandatory: identifier stability across a device restore is still unmeasured, and the fingerprint cannot be backfilled onto records created without it.

## Project setup notes

Established at milestone 00. Stated as rules, because that is how they matter later.

- **iPhone-only. Never re-add macOS or visionOS.** The Xcode template generated multiplatform — `SUPPORTED_PLATFORMS`, device family `1,2,7`, Mac sandbox settings — and it was stripped back to iOS. If you add a target, check it did not return. `REGISTER_APP_GROUPS = YES` remains; harmless on iOS.
- **"Persistent change tokens" means PhotoKit**, not SwiftData. SwiftData has its own separate history API (iOS 18). Do not conflate the two — they solve different problems and appear in different milestones.
- **The UI test target is XCTest on purpose.** XCUIAutomation only runs under the XCTest harness; Swift Testing does not host UI tests. This is not a mistake to "fix."
- **`ContentView.swift` is throwaway scaffolding** — the SwiftData `Item` template list, plus a `.task` requesting photo-library authorization. Both get replaced when the real culling flow lands. Do not build on them or preserve their shape.
- **Signing is a paid team (`5357VRG3AN`).** Device builds need Developer Mode enabled on the phone, but no on-device "Trust" step.

## Working agreements

- **Use plan mode at the start of each milestone.** Produce the plan, wait for review, then build.
- **Verify before declaring done.** Build, run the tests, and where the change is visible, check it on a device or simulator.
- **Report contradictions.** If something in this file or a prompt turns out to be wrong against real PhotoKit behaviour, say so plainly rather than working around it silently. Corrections get folded back into this file.
- **Stay in scope.** Deliver the milestone as specified. If a better approach exists, say so in a sentence and continue with the task as asked.
