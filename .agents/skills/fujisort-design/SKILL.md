---
name: fujisort-design
description: FujiSort's visual design system — surfaces, ink, the single accent, type, motion, haptics, and accessibility. Use when building or changing any FujiSort view, and before choosing any colour, font, spacing, or animation value.
---

# FujiSort design system

## The governing principle

**The photograph is the content. Everything else defers to it.**

This is not a style preference — it follows from what the app does. A culling tool exists so the user can judge photographs, and every pixel of chrome competes with that judgment. Where a design choice is unclear, the resolution is whichever option intrudes less on the image.

Two consequences that decide most questions before they are asked:

1. **The interface is dark and achromatic.** Colour anywhere near a photograph contaminates perception of colour *in* the photograph, and a light surround shifts perceived exposure. Every serious culling tool — Lightroom, Capture One, Photo Mechanic — is dark neutral grey for this reason.
2. **Colour marks the exception, never the norm.** The app has exactly one saturated colour, reserved for Portfolio. Everything else is white at some opacity.

## Do not use the default aesthetic

Left open-ended, AI-generated interfaces converge on a recognisable house style: warm cream or off-white backgrounds around `#F4F1EA`, serif display faces (Georgia, Fraunces, Playfair), italic word-accents, terracotta or amber accents. It reads well for editorial and hospitality work. **It is wrong for this app in every particular** — a cream background is the single worst possible surround for judging a photograph.

Generic redirection ("don't use cream", "make it minimal") tends to substitute a different fixed palette rather than produce the right one. That is why the values below are given concretely. **Use them as specified.** If a value seems wrong, say so and propose a specific alternative with a reason — do not quietly substitute.

## Surfaces

| Token | Value | Used for |
|---|---|---|
| `surface.deck` | `#0B0B0C` | Deck and analysis background — recedes so the photo dominates |
| `surface.grid` | `#141416` | Review grid — slightly lifted so tiles separate from the field |
| `surface.raised` | `#1C1C1E` | Button strip, count pill, sheets, toasts |
| `hairline` | white @ 8% | Dividers, tile borders |

**Never pure `#000000`.** Two reasons: OLED black smearing during card animation and grid scrolling, and pure black destroys the low end of a photograph's shadows by contrast, which is exactly the judgment the user is trying to make.

## Ink

Text and icons are **white at opacity**, not fixed greys. Opacity composites correctly over both surfaces and photographs; a fixed grey that reads well on `#1C1C1E` disappears over a bright frame.

| Token | Value | Used for |
|---|---|---|
| `ink.primary` | white @ 92% | Labels, active icons |
| `ink.secondary` | white @ 60% | Counts, metadata, inactive icons |
| `ink.tertiary` | white @ 38% | Disabled, placeholder |

Anything sitting **directly over a photograph** needs a scrim — a subtle bottom gradient from `#0B0B0C` @ 70% to transparent — never a solid bar, and never text alone over an unknown image.

## The accent

**One saturated colour in the entire app: `#E0A33C`, reserved for Portfolio.**

It marks the tier badge on a tile, the Portfolio filter chip when active, and the Portfolio button in the analysis strip. Nothing else. Its scarcity is what makes it mean something.

Strong tier gets no colour — `ink.secondary` only.

## Verdict feedback — transient only

The four verdicts need to feel distinct in the hand, but **colour must not persist next to a photograph**. So verdict colour appears only during the swipe and in the confirmation that follows, then disappears.

| Verdict | Direction | Transient tint | Persistent colour |
|---|---|---|---|
| Reject | left | `#D9483F` @ low opacity | none |
| Keep | right | none — the common case stays achromatic | none |
| Candidate | up | `#E0A33C` | none |
| Skip | down | white @ 20% | none |

The tint appears as a directional edge glow on the card as it passes the commit threshold — not a full-card wash, which would misrepresent the photo's colour at the exact moment it's being judged.

**Colour is never the sole signifier.** Every verdict is also carried by direction, icon, and haptic. The app must be fully usable by someone who cannot distinguish the tints.

## Type

**SF Pro throughout.** No custom faces, no serif display type. This is a tool, not a brand — SF is optimised for iOS legibility at small sizes over unpredictable backgrounds, and using it removes an entire category of decorative choices.

| Role | Style |
|---|---|
| Count pill | `.subheadline`, medium, **monospaced digits** |
| Button labels | `.caption`, medium |
| HUD metadata | `.caption2`, regular, monospaced digits for numeric values |
| Sheet titles | `.headline`, semibold |

**Monospaced digits are load-bearing on the count pill** — without them the number jitters horizontally as it decrements, which is distracting in peripheral vision precisely where the pill lives.

## Motion

Motion is where the deck earns its feel. Get this right before adjusting anything visual.

- **The card tracks the thumb 1:1** during a drag, with a slight rotation proportional to horizontal offset (max ~8°). No lag, no smoothing — latency here reads as the whole app being slow.
- **Commit** flies the card off in the swipe direction, ~220 ms, ease-out. The next card is already beneath it; there is no gap.
- **Cancel** springs back with a soft spring — response ~0.35, damping ~0.75.
- **Springy zoom release** returns to fit with the same spring. It should feel elastic, not mechanical; an instant snap reads as breakage.
- **Analysis entry and exit** cross-fade with a slight scale, ~200 ms. It is a detour, not a page push — it should not feel like navigation.
- **Tier moves in the review** animate the tile to its new position when the destination is visible, and fade out when it isn't, with the confirmation toast carrying the explanation.

**Respect Reduce Motion.** When enabled, replace card flight and tile animation with cross-fades of the same duration. Never remove feedback entirely — just change its form.

## Haptics

With attention on the photograph rather than on controls, **haptics are how the user knows a verdict registered.** They are functional, not decorative, and are the primary confirmation channel in sort mode.

| Event | Feedback |
|---|---|
| Reject | `.impact(.rigid)` — sharpest, most final |
| Keep | `.impact(.light)` — the common case, deliberately unobtrusive |
| Candidate | `.impact(.medium)` — richer, marks the promotion |
| Skip | `.impact(.soft)` — least assertive |
| Crossing the commit threshold mid-drag | `.selection` — tells the hand the swipe will take before release |
| Undo | `.notification(.warning)` |
| Zoom reaching 1:1 detent | `.selection` |

The threshold tick matters more than it looks: it is what lets a user commit or cancel a swipe without watching the card.

### Pass 2: tier moves

**The axis is character, not magnitude.** In pass 1 `Skip` is `.soft` because it is a deferral, not because it is a small act — read pass 2 the same way.

| Event | Feedback | Why |
|---|---|---|
| Promote to Portfolio | `.impact(.medium)` | A promotion — the same character as Candidate in pass 1 |
| Demote Portfolio → Strong | `.impact(.light)` | A small correction, deliberately unobtrusive |
| Demote Strong → out of review | `.impact(.soft)` | A settling: "this is a Keep, I am done considering it" — nearer Skip than Reject |
| A no-op (Portfolio, promote) | **none** | Nothing was recorded. Never confirm an action that did not happen |

**Distinguish the two demote paths.** They differ in consequence — one adjusts a tier, the other removes the photo from the review and makes the tile vanish. The hand should know which happened without looking, for the same reason the confirmation toast exists.

**Never use `.rigid` in pass 2.** It is Reject's signature, and nothing in the review rejects anything — demoting out returns a photo to `Keep`.

**Multi-select moves fire once for the batch**, not once per photo. A haptic per tile in a twelve-photo move is noise, not confirmation.

## The count pill label

**Progressive date disclosure — terse where it can be, specific where it must be.**

| Outing age | Label |
|---|---|
| Within the last 7 days | `Saturday · 118` |
| Earlier this year | `23 Aug · 118` |
| Older | `23 Aug 2026 · 118` |

The deck spans unjudged photos back to 2003 across 1,851 clusters, so a bare weekday is genuinely ambiguous for old outings — but the overwhelmingly common case is culling something recent, and that case should read as short as possible. Never show the full date when the weekday alone is unambiguous.

**Monospaced digits on the count**, always. Without them the number jitters horizontally as it decrements, right where peripheral vision sits.

## Layout

- Photo is **full-bleed** in analysis and compare — the looking states. No inset, no corner radius, no border, no drop shadow. The frame is the frame.
- **The sort deck is the exception (decision 0011).** There the photograph reads as a *card*: inset from the safe area on all four sides (`DeckCard.inset`, default 12 pt), rounded (`DeckCard.radius`, default 14 pt), with a `hairline` edge. The card is the photograph's own bounds — it changes shape with the photo (wide for landscape, tall for portrait), never normalised to a fixed size, and nothing is drawn behind it. **Still no drop shadow, ever** — a shadow implies a light source and lays a grey halo against the edge, shifting perceived exposure; the hairline does the edge's job at one pixel. Both constants are empirical and tunable.
- Chrome sits within thumb reach — the button strip along the bottom safe area, the count pill top-centre where the thumb never travels.
- **Minimum 44 pt tap targets**, including tier buttons in the analysis strip.
- Review grid: 3 columns portrait, 2 pt gutters. Tiles are square-cropped; this is a working surface, not a presentation.
- Persistent chrome in the deck is capped at the button strip plus the count pill. Adding a third element requires removing one.

## Accessibility

- **Dynamic Type** on all chrome text. The layout must survive the largest accessibility sizes — the count pill may wrap, the button strip may need to scroll.
- **VoiceOver:** each card announces the photo's capture date and any existing marks. Verdicts are custom actions on the card so the whole vocabulary is reachable without gestures.
- **Reduce Motion** as above; **Reduce Transparency** replaces scrims with solid `surface.raised`.
- **Contrast:** `ink.primary` on `surface.deck` exceeds 7:1. Verify anything over a photograph against a worst-case bright frame, not a mid-grey placeholder.

## Never

- Cream, off-white, or any light background
- Serif or display typefaces; italic word-accents
- Gradients behind or over photographs, beyond the functional scrim
- Corner radii or borders on photographs in analysis or compare (the sort deck card is the deliberate exception — decision 0011); a **drop shadow anywhere, ever**
- More than one saturated colour
- Persistent colour adjacent to an image
- Decorative iconography, illustration, or empty-state art
- Any styling that would make a screenshot look like a magazine layout rather than an instrument
