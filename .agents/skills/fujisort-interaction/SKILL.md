---
name: fujisort-interaction
description: FujiSort's interaction model — the sort deck, the analysis state, comparison, tier movement, gesture allocation, and undo. Use when building or changing any FujiSort view, gesture, or navigation transition.
---

# FujiSort interaction model

The full specification for how FujiSort behaves under the user's hands. `CLAUDE.md` carries the summary; this is the detail.

## Two states, and their relationship

**Sort is the spine. Analysis is a per-photo detour.** Finishing with a photo in analysis returns to the deck, advanced to the next photo. Analysis is never navigable through the queue — you cannot walk the session from inside it.

The one exception: analysis may move within a set the user **explicitly assembled** (a compare set). That set is bounded and hand-picked; it is not a window onto the deck.

## When the deck runs out

**Skipped photos come back first, then any pinned set.** Both are offers, not forced laps:

```
   14 skipped — another lap?     [ Yes ]  [ Leave them ]

    5 pinned — compare them?     [ Yes ]  [ Later ]
```

**Skip is a verdict, and that is what makes this work.** The lap is derived from the verdict rather than from tracked membership — the same trick as the deck itself. Nothing stores "which photos were skipped this session"; the set is recomputed. Declining the lap leaves them skipped, and they surface again next session.

This is the whole reason Skip means "decide later" rather than "decide never". A Skip that removed a photo permanently would be a worse Reject.

## Sort mode

One photo, no chrome except the count pill and a small button strip. The photograph reads as a *card* — inset from the safe area, rounded, hairline edge (decision 0011; see fujisort-design for the geometry). It is a card in a stack; analysis and compare, having no stack, stay full-bleed.

### Gesture allocation

Directions are assigned by **frequency, not importance** — the two commonest verdicts get the easy horizontal thumb motions.

| Gesture | Verdict | Expected share |
|---|---|---|
| Swipe left | Reject | ~28% |
| Swipe right | Keep | ~53% |
| Swipe up | Candidate | ~8% |
| Swipe down | Skip — returns in the end-of-deck lap, not gone | ~4% |

Swipes should be **velocity-triggered with a low displacement threshold** — a flick, not a drag across the screen. The card follows the thumb and flies away in the swipe direction.

### Zoom in sort mode: springy

Pinch to magnify, and the card **snaps back to fit on release**. The zoom is held open by the fingers, not by state. There is no exit to remember and no way to get stranded zoomed mid-session.

This is deliberate: a one-to-two-second sharpness check is comfortable held; anything longer is not, which is why the sticky version lives in analysis.

**Pinch and pan are both two-fingered in sort mode** — a pinch pans naturally as its centroid moves. One-finger swipe-to-decide is therefore never contested.

### Tap

Single tap enters analysis. This is deliberately the app's *accident sink*: the most likely accidental input mapped to the most harmless outcome — instantly reversible, nothing recorded.

### The count pill

Always present during pass 1. Shows the **current outing's** remaining count, not the whole deck:

```
         ╭─────────────────╮
         │  Saturday · 118 │
         ╰─────────────────╯
```

The deck may span several outings; a bare number would be meaningless. Tapping expands it to the full picture.

### Buttons

Deliberately few: **undo** and **pin-for-compare**. A pin marks the photo a candidate *and* adds it to a set offered at the end of the deck. Pinning never interrupts the pass.

Persistent chrome in the deck is capped at the button strip plus the pill. Do not add more.

## Analysis mode

Entered by tap. Same full-bleed frame; zoom now **sticks**.

- Pinch to magnify, hands off the glass, pan with one finger.
- A detent at 1:1 is worth having — critical focus needs actual pixels — but it is a convenience within free zoom, not a replacement for it.
- **No algorithmic targeting.** Do not jump to a detected eye or face. The user aims their own zoom.
- HUD available: shutter, ISO, aperture, camera model. **Focus point and film simulation are not available** — measured absent from transferred Fuji frames; do not design around them. **Off by default.** Clipping indication (zebras) is the likely exception, being glanceable rather than readable — a histogram must be *read*, which costs attention the sorting path can't afford.

### The button strip in analysis

The four verdicts appear as buttons, plus the long tail (colours, delete, pin). This is the frequency principle applied to a changed context: in sort mode aiming is expensive because it breaks rhythm; in analysis the user has already stopped, so precision beats speed.

**There is no "compare" button in single-photo analysis.** Pin *is* the assembling action — a compare-of-one is meaningless, and a button that gathered other photos would have to navigate the queue from inside analysis, which is forbidden. Compare is entered from an assembled set, never from a single photo. In the review (pass 2), long-press multi-select provides the second entry path.

- The strip is a **superset**, not a duplicate — it can afford labels and can show which marks are already applied.
- **Same icons, same order as sort mode**, so muscle memory transfers.
- **Retreat while the fingers are down** — hide during an active pinch or pan, restore on release, so it never covers what is being studied.

### Exits

| Action | Result |
|---|---|
| Verdict | commits, advances, returns to sort |
| Annotation (colour, pin) | applies, stays in analysis |
| Cancel | returns to sort, same photo, nothing recorded |

The cancel path matters as much as the verdict path. If entering analysis obliged a decision, it would become a state users avoid — and then focus gets judged from a fit-to-screen card.

## Comparison

**One photo at a time, full screen, with thumbnails of the selected set along the bottom.** Tap a thumbnail or swipe to move between them.

```
┌──────────────────────────┐
│                          │
│      full-bleed photo    │
│                          │
├──────────────────────────┤
│  ▪ ▪ [▪] ▪ ▪ ▪ ▪         │
├──────────────────────────┤
│  Portfolio  Strong  Out  │
└──────────────────────────┘
```

**Nothing is ever shown side by side.** Reasons, in order of weight:

1. **Same retinal position.** Toggling frames through one position is far more sensitive to small differences than side-by-side, because the change lands in the same place instead of requiring a saccade and a memory. Blinks, focus on the wrong eye, a hand moved slightly — the cases the app exists for.
2. **Zoom works.** At full screen, pinching to 1:1 is meaningful; at quarter-screen it isn't. Because it's one viewport, **zoom position carries across photo switches for free** — sit at 100% on an eye and toggle through seven burst frames. This is the single most useful thing the design does.
3. **No decay with set size.** Two behaves like seven. There is no layout penalty for adding photos.

Comparison is **analysis with a filmstrip**, not a separate mode. Same sticky zoom, same HUD, same button strip.

**The app never starts a comparison on its own.** Two entry paths, and they belong to different passes:

- **Pinning**, during pass 1. The pinned set is offered when the deck runs out. This is the *only* path available in pass 1 — there is no grid to multi-select on, and opening a comparison mid-deck would interrupt the one pass that exists not to be interrupted.
- **Long-press multi-select**, in the pass-2 review grid, where a grid exists to select on.

Gesture detail: swipe moves along the strip, but one-finger drag pans when zoomed. **Tapping a thumbnail must always switch**, with swipe reserved for when the photo is at fit.

## Pass 2: the review

Tile grid with a filter bar. The counts in the filter chips carry the shape of the take — they are what make the layout work without spending screen on lanes.

```
┌────────────────────────────────────────┐
│  All 45  │  Portfolio 7  │  Strong 38  │
├────────────────────────────────────────┤
│   ▣ᴾ      ▣ˢ      ▣ˢ      ▣ᴾ           │
│   ▣ˢ      ▣ˢ      ▣ˢ      ▣ˢ           │
└────────────────────────────────────────┘
```

The grid is **utilitarian by intent** — an operating table, not a wall. Square crops are acceptable here precisely because this isn't for looking.

The review is **not scoped to a session**: it pools every candidate still awaiting judgment. Sort options: capture date (newest first, default), by outing, by visual similarity.

### Moving photos between tiers

Three paths, matched to three levels of need. **No dragging anywhere.**

| Need | Gesture |
|---|---|
| Nudge one photo | Horizontal swipe on a tile — right promotes, left demotes |
| Assign after a close look | Tap → analysis → tier buttons |
| Move several | Long-press → multi-select → bottom bar |

Horizontal swipe is free because the grid scrolls vertically. With two tiers it needs no picker: from Strong, right promotes to Portfolio and left demotes out of the review; from Portfolio, left returns to Strong.

**Tap still means analysis.** Nothing is relearned between the deck and the review.

Every move shows a brief confirmation naming the destination, with undo attached. Demoting while filtered to a tier makes the photo vanish — correct, but disorienting without a response.

## Undo

> **Internal judgments are freely reversible; library writes are committed with a stated recovery path.**

- One stack per app run, unlimited depth, covering verdicts and tier moves.
- Undoing a verdict issued from analysis returns to the **deck** at that photo, unjudged — not back into analysis.
- **No redo.** After an undo you are on the photo with no verdict, and the only way forward is to choose one. Undo can therefore never leave an ambiguous state behind.
- Undo must be one-swipe-granular. Framework undo managers group by change-set and may revert a batch; a purpose-built stack above the store is likely simpler.

## Things deliberately not built

Do not add these. Each was considered and rejected:

- Side-by-side comparison layouts
- A cap on Portfolio size, or automatic eviction duels
- A third pass-2 tier
- Algorithmic zoom targeting (jump-to-eye)
- Galleries, slideshows, or any presentation view
- Gamification: streaks, scores, badges
- Modal confirmations on per-photo actions
