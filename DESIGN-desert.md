<!-- SPDX-License-Identifier: Apache-2.0 -->
# Desert: a design study

**Status: a study, not merged.** It is applied to the website (`site/index.html`, `site/terms.html`, branch `website`) and the keyholder page (`keyholder/src/page.css` and `page.html`, branch `keyholder-page`) so the owner can see it. Lumen stays the reference until the owner chooses.

The owner's direction: make the UI *subtly* inspired by the art around the Christian desert fathers. The aim is the feeling of a quiet, lime-washed cell at dawn: calm, plain, well made. The page should still read as a modern Mac product page, not a museum piece.

## What the art gives us, and what we leave

Egyptian and Coptic monastic art of the 4th to 7th centuries:

- **Painted apse niches** at the monasteries of Apa Apollo at Bawit and Apa Jeremias at Saqqara (6th to 7th century, now mostly in the Coptic Museum in Cairo and the Louvre): a round arch over a straight wall, framed by painted bands.
- **Panel icons**, such as the Bawit icon of Christ and Abbot Mena (Louvre): a plain ground, figures in halos, a fine frame.
- **Wall paintings at the Monastery of St Antony** by the Red Sea. Older 6th to 7th century paintings survive beside the 13th century programme that ARCE conserved between 1996 and 1999. A study of green pigment from the monastery's Coptic wall paintings found green earth (glauconite).
- **Pigments**: the long-standing Egyptian palette of Egyptian blue, green earth and copper greens, red and yellow ochre, and carbon black, with gold leaf on icons, on a ground of lime plaster.
- **Coptic textiles**: undyed linen with wool tapestry bands and roundels. The interlace, braids and endless knots were often worked in one dark colour.

We take the palette, the materials, some proportions, and four shapes: the arch, the halo ring, the double rule and the two-strand braid. We leave out figures, saints, crosses, any other religious symbol, and any text from scripture. Nothing should look carved, aged, cracked or "ancient". There's no texture and no parchment.

## Tokens

Keep the token names and swap the values. The accent stays in Lumen's teal family and moves a step toward malachite. Neutrals are lime plaster, cool and slightly green, never cream. Dark mode is lapis night. Gold appears only as hairlines and one dot.

| Token | Role | Lumen light | **Desert light** | Lumen dark | **Desert dark** |
|---|---|---|---|---|---|
| `--bg` | page: lime plaster / lapis night | `#f3f6f6` | **`#eff1ec`** | `#0b1112` | **`#0c1222`** |
| `--card` | panels: whitewash / night panel | `#ffffff` | **`#fbfbf8`** | `#121a1c` | **`#131a2d`** |
| `--text` | lamp-black / plaster white | `#0e1b1d` | **`#151c1b`** | `#ecf4f3` | **`#eceee6`** |
| `--muted` | secondary text: limestone shadow | `#56686b` | **`#45504d`** | `#97aaa8` | **`#a9b1bf`** |
| `--line` | stone joint | `#dde6e6` | **`#d8dcd3`** | `#22322f` | **`#252e46`** |
| `--accent` | malachite (buttons, focus, dots) | `#0b7f73` | **`#0b7363`** | `#4fd8c4` | **`#5cd3bc`** |
| `--accent-press` | pressed button | `#086a60` | **`#085e51`** | `#3cc2ae` | **`#49c2aa`** |
| `--accent-soft` | malachite wash (badges, friend panel) | `#dcf1ee` | **`#e0ede7`** | `#123430` | **`#13303a`** |
| `--on-accent` | text on the accent | `#ffffff` | **`#ffffff`** | `#06201c` | **`#071d19`** |
| `--accent-text`, `--link` (keyholder `--accent-ink`) | malachite ink: links, eyebrows | `#086a60` | **`#06594d`** | `#4fd8c4` | **`#6fd9c4`** |
| `--gold` | gold leaf: one dot | (none) | **`#a68338`** | (none) | **`#c9a961`** |
| `--gold-line` | gold hairline | (none) | **`rgba(166,131,56,.5)`** (keyholder `.42`) | (none) | **`rgba(201,169,97,.36)`** (keyholder `.30`) |
| `--gold-wash` | light at the top of an arch | (none) | **`rgba(196,160,82,.13)`** | (none) | **`rgba(201,169,97,.07)`** |
| `--glow` | dawn light behind the top of the page | teal `.11` | **`rgba(196,160,82,.09)`** | teal `.09` | **`rgba(201,169,97,.05)`** |
| `--stone` | the covered picture in the hero drawing | (accent-soft) | **`#e4e7e0`** | (accent-soft) | **`#182033`** |
| `--knot` | interlace strand | (none) | **`#87908b`** | (none) | **`#6d7791`** |
| `--ill` | outline in the home page's drawings | (none) | **`#7c8681`** | (none) | **`#75809b`** |
| `--night` | the night niche (step 3): pale Egyptian blue / deep lapis | (none) | **`#dce5eb`** | (none) | **`#121c3a`** |
| `--moon` | the moon in step 3 | (none) | **`#fbfbf8`** | (none) | **`#dcdfd4`** |
| `--soft` (keyholder) | fields and panels | `#ecf2f2` | **`#eceee8`** | `#16231f` | **`#182035`** |
| `--radius` | cards | `22px` | **`20px`** (keyholder stays `22px`) | | |

Unchanged: the error colours (`#a3261b` on `#f9e7e3`; `#ff9b8c` on `#3a1d22`), the QR colours (black on white), the system sans and monospace stacks.

**For the app's covers** (not a web token, given here so the app can follow): cover `#e5e7e1` light and `#121828` dark. The way-out line uses `--card` and `--text`. Key caps are `#f2f3ef` with a `#cdd2ca` edge and a `#b9bfb6` base and `#151c1b` glyphs in light, and `#252e47` / `#3a4562` / `#2e3853` with `#f1f2ec` glyphs in dark.

### Contrast (WCAG 2)

| Pair | Light | Dark |
|---|---|---|
| text on bg / card | 15.2 / 16.7 | 15.9 / 14.8 |
| muted on bg / card | **7.4 / 8.1** (Lumen was 5.4 / 5.9) | 8.7 / 8.0 |
| link on bg / card | 7.3 / 8.0 | 11.0 / 10.2 |
| link on accent-soft (labels) | 6.9 | 8.2 |
| button text on accent | 5.8 | 9.6 |
| accent (focus ring, dots) on bg | 5.1 | 9.5 on card |

Body text clears 7:1 and every UI pair clears 4.5:1. Gold never carries text or meaning, so it has no contrast target.

### Not SHIFT

SHIFT is warm cream with terracotta. The study keeps away from that in three ways. The accent stays malachite. Neutrals are cool and slightly green: `#eff1ec` leans grey-green, where a cream like `#f6f1e7` leans yellow. Gold covers no area larger than a wash under 13% opacity. Red ochre isn't used at all; the error red is the one red on the page, as before.

## Type

- **Headings (h1 to h3), the "Why it exists" closing line and the promise:** `ui-serif, "New York", "Iowan Old Style", Georgia, serif`, weight 600 for headings and 400 to 500 for display text, with tracking between -0.016em and -0.004em (serifs need less tightening than SF). Nothing is downloaded. Safari renders New York. Chrome on a Mac can't reach New York by name, so it renders Iowan Old Style, which also ships with macOS (checked with Chrome's own font report). Both read as book faces, and the screenshots show Iowan.
- **The second half of the hero heading** is italic in malachite ("Once it's on, it stays on."). This echoes manuscript rubrication, where a phrase was written in a second ink.
- **Step numbers** are serif italic with old-style figures.
- **Everything else stays in the system sans:** body, buttons, labels, eyebrows, tables, the keyholder's facts and fields, and every code.

## The motifs, and exactly where each may appear

There are four shapes plus one rule for gold. Each is used where listed and nowhere else.

### 1. The arch (apse niche)

A round arch over a straight wall. On small marks the top is a full half-circle (top corner radii of half the width, small radii below). On wide panels it's an elliptical arch whose height is set by `--arch`.

- **Brand mark:** the 36×40 tile in the site header and footer, and the 30×34 tile on the keyholder page. The favicon has the same shape.
- **Feature badges:** the icon tiles on the home page (46×50) and the terms page (42×46).
- **Hero drawing:** the window stands in a niche whose sides fade out below.
- **The walkthrough:** five small niches in "How it stays on", one per step, each holding a drawing. A row of five on wide screens (true half-circle tops), alternating left and right on tablets, and a wide shallow arch on phones. No border and no gold rule; the plain plaster ground, except step 3 (night) and step 5 (a dawn wash rising from the floor).
- **The promise:** one centred panel, at most 52rem wide, with `--arch` set to `clamp(112px, 24vw, 236px)`.
- **The keyholder card:** a gentle arch (`--arch` 56px on phones, 84px from 560px up).
- **Never** on buttons, fields, tables, list rows, pills, the QR frame, covers or the way-out line. Never on more than one large panel per screen.

### 2. The halo ring

A thin circle around something kept safe.

- **Hero drawing:** a 1.25px gold ring with an 8% gold fill behind the covered picture.
- **The "Early preview" pill:** a 1px gold ring around the malachite dot.
- **Never** around a person, a face, an avatar or the friend icon. Never on a real cover.

### 3. The double rule (fresco border)

A stone line, a gap of 3 to 7px, and a second line, like the painted bands that frame a fresco panel.

- **Home page:** the top and bottom edges of each full-width band (`.sec-band`), with both lines in stone.
- **Terms page:** the top of each section, and the footer.
- **The promise and the keyholder card:** the stone edge plus a gold hairline 8px (promise) or 6px (card) inside, following the arch.
- **Never** on cards that sit inside a band, on table rows or on buttons. Only one panel per page gets the gold inner rule.

### 4. The interlace (two-strand braid)

A short braid from Coptic textile borders: two strands with real over-and-under crossings, seven eyes, one colour (`--knot`) and a gold dot in the middle eye. It's drawn as inline SVG with a casing stroke in the ground colour to make the gaps, 87×16px on the site and 70×13px on the keyholder page, flanked by stone hairlines on the site.

- **Home page:** once, between "Why it exists" and its closing line.
- **Keyholder page:** once, above "This page sends nothing and keeps nothing."
- **Never** more than one per page. Never as a repeating border or background, never animated, never longer than seven eyes, and never in the app's covers or alerts.

### 5. Gold leaf

Gold is a highlight, not a colour of the theme.

- Allowed: the hairlines named above (the hero niche's inner arch, the halo ring, the pill ring, the promise rule, the keyholder card rule), the interlace's one dot, and a wash of 13% or less at the top of an arch or the page.
- In the walkthrough, gold belongs to step 5 alone: the doorway's inner hairline, the low sun's outline and rays, and the dawn light in the doorway and on the floor, all as hairlines or washes of 13% or less.
- **Never** gold text, gold buttons, gold icons, gold fills or gold focus rings.

### 6. Drawings (home page)

The owner asked for more pictures and a simpler walkthrough, so the home page now has a small set of line drawings. They are inline SVG, coloured only from the tokens, so both themes work and nothing is downloaded.

- **Style:** warm, plain line drawings. Every outline is 1.5px (`vector-effect: non-scaling-stroke`, so the weight holds at any size) in `--ill`, with flat fills from the page's own colours: `--card` for paper, `--tile` and `--glyph` for content, `--stone` for covers, `--accent-soft` and malachite for the one thing that matters in each drawing. No shading, no gradients except the dawn, no texture, and no motion.
- **Where:** the five walkthrough steps (a calendar and dial; a window with a covered picture and a covered video; a quiet desk at night with a locked screen; a countdown ring with a Stay button and a small friend badge; dawn through an arched doorway), the three parts in "How it works" (the screen cover, the lock, the menu-bar app), three overlapping windows beside "Hard to get around, by design", "only this Mac" beside "What it can't do", and an arch being built beside "What we're building now": the finished stones in paper, the stone being set in malachite, and the stones still to come as dashed outlines, over a plain timber form. It never gets scaffolding bars, a crane or a figure.
- **Covers in drawings** follow the real covers: plain `--stone` with the faint seal (ring and dot), never a halo, gold or ornament.
- **Status chips** in "What we're building now" are plain pills (no arch, no gold): a filled malachite dot for built, a half dot for in progress and in trials, an empty ring for planned, and the infinity icon for "always". They reuse the dots of "Where things stand".
- **Shared parts** are `<symbol>`s: the seal (`s-seal`) and the existing icons (`i-friend`, `i-clock`, `i-refresh`).
- **Never** people's faces or figures (the friend icon has heads and shoulders only), religious symbols, stars beside the moon, crossed window bars, or anything that looks like clip art. The moon is a plain crescent, alone.

## What never changes

- **Covers stay a calm, opaque neutral:** limestone `#e5e7e1` in light, lapis-black `#121828` in dark. No arch, no ring, no rule, no gold, no serif and no texture on a cover. A cover must look like a pause, not an ornament.
- **The way-out line** stays in the system sans at the same size, centred on the cover. Its key caps are plain neutral caps with near-black glyphs (light) or near-white glyphs (dark), so the keys are the most legible thing on the cover. In Lumen the caps were teal on teal, which this study drops. See `wayout-window-*.png` in the study's screenshots.
- **QR codes** stay black on white in a plain frame, so phones can read them.
- **Body text, buttons and fields** stay in the system sans with the same sizes, weights and hit areas.
- **No new motion.** Reduced motion is respected as before.
- **Nothing loads from another origin.** All shapes are CSS or inline SVG, so the keyholder page keeps its byte-for-byte hash rule and both CSPs stay as strict as before.
- The words don't change. (The website's new "stays on" wording came from the owner, in a separate commit.) The five-step walkthrough and the "How it works" picture came from the owner's request for more illustrations and a simpler walkthrough; "Why it exists" and the promise still match the README word for word.

## Sources for the research

- [ARCE: Monastery of St. Anthony](https://arce.org/?p=3612) and [Coptic Art (ARCE, Google Arts & Culture)](https://artsandculture.google.com/story/aAXRRtTdmDRuTw)
- [Bawit (Wikipedia)](https://en.wikipedia.org/wiki/Bawit) and [Wall paintings from Bawit (Art of the Middle Ages)](https://artofthemiddleages.com/s/main/item/3207)
- [Icon of Christ and Abbot Mena (Wikipedia)](https://en.wikipedia.org/wiki/Icon_of_Christ_and_Abbot_Mena)
- [Roundel with Interlace Pattern, Brooklyn Museum](https://www.brooklynmuseum.org/objects/121828) and [Textiles, Coptic (Encyclopedia.com)](https://encyclopedia.com/fashion/encyclopedias-almanacs-transcripts-and-maps/textiles-coptic)
- Green earth at St Antony: H. H. Marey Mahmoud's study, listed on [scite](https://scite.ai/authors/h-h-marey-mahmoud-9gMxy9)
