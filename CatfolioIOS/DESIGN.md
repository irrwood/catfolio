# Catfolio iOS Design System

The rules the iOS app is built to. The root `DESIGN.md` covers the web workspace; where the two disagree about a number, this file governs iOS.

Two of these rules are enforced by `scripts/check_ios_design.py`, which fails the same way a compile error does. A rule with no check is how the last one was missed.

## Colour

### Where a Colour May Be Written


This is the rule the rest of the section depends on, and it is enforced rather than encouraged. Before it existed the app carried nine different greens all meaning "this went up" and five reds meaning "this went down", because every screen picked its own. A reader comparing two rows cannot tell a deliberate shade from an accidental one.

Colour literals live in one file. On iOS that is `DesignSystem.swift`; everywhere else, name a token.

`scripts/check_ios_design.py` fails on a literal `Color(red:)`, `Color(white:)` or `Color(hue:)` written anywhere else. Files that predate the rule carry a budget equal to what they held the day it landed: the count may fall and never rise, so the debt drains without blocking work on the files that still carry it. Lower a budget when you clear one; delete the entry at zero.

Choose in this order, and stop at the first that fits.

1. **A system semantic colour.** `.primary`, `.secondary`, `.tertiary`, `Color(uiColor: .systemGroupedBackground)`, `.tint`. Text, backgrounds, separators, selection and disabled states are the platform's job — it already handles light and dark, contrast settings, and whatever the next OS changes. Reaching past it is how a card ends up a hand-picked grey that is lighter and bluer than the system's.
2. **A semantic token** — `gain`, `loss`, `warning`, `accent`. One definition each, with its light and dark values written together where they can be compared. Ask for the meaning, never the hue.
3. **A named entry in a categorical palette.** Series and sector colours come from an ordered list or an explicit map, assigned centrally. Never invented at a call site.
4. **A brand colour**, from the one table of them, for a real brand only.

There is no fifth option.

### Semantic Colour

`CatfolioTheme` in `DesignSystem.swift` is the source of truth.

Neutral UI roles use dynamic system colours: `neutralIcon` uses `secondaryLabel`,
`neutralFill` uses `secondarySystemFill`, `subtleFill` uses `quaternarySystemFill`,
and loading placeholders share `skeletonFill` (`tertiarySystemFill`). Page and
card backgrounds use the grouped system backgrounds. Do not use the fixed
`neutral50`–`neutral900` palette swatches for UI surfaces or text: they do not
adapt to dark appearance or increased contrast.

| Role | Light | Dark | Meaning |
|---|---|---|---|
| `gain` | `#008724` | `#34C759` | A rise, a positive delta, a completed state |
| `loss` | `#E30045` | `#FF4567` | A fall, a destructive action, a failure |
| `warning` | `orange500` | same | Stale data, waiting, caution |
| `accent` | `blue500` | same | Selection, the primary action, interactive affordances |

`gain` and `loss` differ between appearances because a bright green on white fails contrast while the same green on black is correct; the two values are declared together so that relationship stays visible. The other two do not, and are single values today — if either ever needs an appearance split it gets the same treatment rather than a second literal at a call site.

A scheme-free `gainDefault` / `lossDefault` exists only for contexts with no `ColorScheme` to hand — a `Canvas` closure, a value computed off the view tree. Anywhere the environment is available, use the scheme-aware pair.

Do not give one colour two jobs in the same view. An account row once used the accent both for "included in the portfolio" and for "waiting for its first sync", so an unsynced account read as a selected one.

Prefer the scheme-aware form. A scheme-free default exists for contexts that have no `ColorScheme` — a `Canvas` closure, a value computed off the view tree — and is the only acceptable use of it.

### Categorical Colour

For series, sectors, and anything else where the colour identifies rather than means:

- One colour per identity, in one table. A series' line and its chip read the same table, so they cannot diverge — the portfolio line was once teal while its own chip was green.
- Where an identity has an obvious colour, give it that colour. Gold is gold. The reader's own portfolio is the same green a gain is.
- Neighbours in the table must stay distinguishable from each other and from `gain` and `loss`, which are already on screen.
- Do not reuse a semantic colour for an identity that is not that thing.

### Brand Colour

Only for a real brand — a broker, an issuer, a logo tint — and only from the brand table. A brand colour never carries product meaning: a red brand mark next to a red loss figure is two different reds saying two different things, and the reader has to work out which is which.

## Type

### Type Scale


`TypeScale` in `Typography.swift` is the source of truth. Every size in the app comes from it; none is written at a call site. These are the twelve that survived deduplicating the fourteen the screens had grown, several of which sat a point apart doing the same job.

| Token | Size | Dynamic Type ramp | Prose weight | Figure weight | Extra leading |
|---|---:|---|---|---|---:|
| `display` | 32 | largeTitle | medium | semibold | 0 |
| `displayUnit` | 21 | largeTitle | medium | semibold | 0 |
| `title` | 24 | title | semibold | bold | 0 |
| `heading` | 19 | headline | medium | semibold | 0 |
| `subheading` | 17 | body | regular | medium | 0 |
| `body` | 16 | body | regular | medium | 3 |
| `callout` | 15 | callout | regular | medium | 3 |
| `footnote` | 14 | footnote | regular | medium | 2 |
| `label` | 13 | caption | medium | semibold | 0 |
| `caption` | 12 | caption | regular | medium | 2 |
| `micro` | 11 | caption2 | medium | semibold | 0 |
| `nano` | 10 | caption2 | medium | semibold | 0 |

Notes on the columns.

- **Ramp.** Which Dynamic Type style the token grows along. A token that scaled along `body` everywhere would make the money headline grow faster than the layout can absorb, so the display pair follows `largeTitle` and the small end follows `caption2`.
- **Figure weight** is one step above prose weight, for the reason in Numerals below.
- **Extra leading** is added to the face's own, and only on tokens that wrap. A single-line figure gains nothing from it but a taller row.
- `displayUnit` is not a rung on the ramp. It is the small currency symbol that sits beside `display`, baseline-aligned, and is declared next to the token it pairs with.

Call sites ask for a role: `appText`, `appNumber`, `appCaps`. For a size the scale does not name, `Typography.number(size:)` and `Typography.text(size:)` still route through the tokens' faces and features.

### Numerals


Every figure in the product is set in the same face as the text around it, with three glyph substitutions and two rules about width. The app is a screen full of digits people compare against each other, and the default forms are optimised for reading prose.

**Alternate forms.** Use SF's straight-sided six, straight-sided nine, and open four.

- The default six and nine curl their terminals back toward the bowl, which closes the counter and makes them approach an eight at small sizes.
- The default four is closed, which makes it approach a nine.
- The straight-sided and open forms keep those counters open, so 6/8, 9/8 and 4/9 stay distinct in a dense column.

On Apple platforms these are stylistic sets, applied through a font descriptor because SwiftUI has no API for stylistic sets on the system font:

| Alternate | Stylistic set | Feature selector |
|---|---:|---:|
| Straight-sided six and nine | 1 | 2 |
| Open four | 2 | 4 |

The selector is `2n` for set `n`, per the `kStylisticAlternativesType` convention.

Do not take the set numbers on trust. Which set carries which alternate is a property of the shipped font, and it has moved between OS releases; a descriptor naming a set the font does not have is accepted silently and changes nothing. Verify by rendering: draw `469` with and without the feature and compare the pixels, and draw `012357` both ways and confirm they are identical. If the first pair matches or the second pair differs, the mapping is wrong.

Apply the alternates to figures only. Prose has no 6/8 confusion to solve, and the straight-sided forms in running text read as a second typeface.

**Width.** Figures use fixed-width digits by default, so a value that changes cannot change the width of its own frame and shift what sits beside it. Pair that with a rolling numeric transition where the value animates.

Turn fixed width off for a figure that never changes and sits in no column — a share count, a settled date. A fixed-width `1` is padded to the width of an `8`, so numbers with several 1s in them carry visible gaps, and a static figure gains nothing in return.

**Weight.** Set figures one step heavier than the same size gives prose. A rounded face reads lighter than a standard one at the same nominal weight — the rounded terminals take ink out of every stroke ending — and a figure has no word shape holding it together, so at small sizes a regular-weight number washes out against its own label.

**Where a figure's font may be built.** Only the type tokens. A font assembled at a call site from `Font.system(design: .rounded)` skips the alternates and the figure weight, which is how the oversized display amount ended up as the one number in the app without the straight-sided six and nine — visibly different from every figure beneath it. `scripts/check_ios_design.py` fails on a rounded system font built outside the token file. For a size the scale does not name, use `Typography.number(size:)`, which still applies both.

**Where a figure may be abbreviated.** Only `DisplayFormat`. Three screens each divided by a million on their own and none of them agreed. A statement line ran its own K/M/B/T table with its own currency symbols, which printed CNY and JPY both as `¥` while the rest of the app said `CN¥`. An axis label stopped at M, so a portfolio past a billion drew `1234M` instead of `1B`. A contribution bar used `.compactName`, which under zh-Hans says 万 and 亿 rather than K and M. Three ladders, three answers, and a reader comparing two figures cannot tell which convention either one is following.

So there is one ladder: `DisplayFormat.compact` and `DisplayFormat.compactMoney`. `scripts/check_ios_design.py` fails on a division by a thousand or a million written anywhere else, and on `.notation(.compactName)` outside the token file.

Two things are named rather than decided again at each call site:

| | |
| --- | --- |
| `.whole` | No decimals. An axis label, where a decimal point is noise. |
| `.tenth` | Up to one. The default for a figure read at a glance. |
| `.statement` | Two below 100, none at or above — roughly three significant digits, which is what a statement line needs. |

| | |
| --- | --- |
| `.latin` | K / M / B / T, identical in every language. The default, and what any figure compared against another one uses. |
| `.localised` | The locale's own names — 万 and 亿 under zh-Hans. Only the contribution bar, which reads as prose beside the figure it abbreviates. |

**Open:** whether `.localised` should exist at all. A Chinese reader may well expect 亿, but the app currently says 亿 on one screen and B on the others, which is worse than either answer alone. Settle it and delete the other case.

**Signs and symbols.** The sign leads the whole amount — `-$1.50K`, not `$-1.50K`, which reads as a negative quantity of dollars. Symbols come from the same formatter `money()` uses, so a currency looks the same wherever it appears; a currency with no glyph prints its code followed by a non-breaking space, because `SEK1.00T` reads as one token.

**Tracking.** None. The system face carries the platform's optical tracking per size; adding to it visibly loosens display sizes. The one exception is text set in capitals, which needs roughly 6% of the size and does not get it from optical sizing.
