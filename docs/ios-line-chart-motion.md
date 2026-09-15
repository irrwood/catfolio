# Shared line-chart motion — updated 2026-09-14

## Behaviour

- Entrance history lives outside the view in `ChartAppearanceHistory`, for the
  current app process. Stable chart IDs survive navigation, sheet recreation
  and cache restoration; symbols distinguish security charts. Reopening a
  displayed chart starts at its final geometry without a loading morph.
- Background updates with the same interaction key replace data without
  animation. Intentional range / mode transitions keep their existing motion.
- Loading lines inherit real series widths; a 2.2-second travelling highlight
  is masked to skeleton geometry. Text and icons use similarly sized shapes;
  non-line charts use bars or circles. A previously displayed chart uses static
  placeholders if it must wait again. Reduce Motion disables the shimmer.

- First appearance uses the shared preset curve, continuously morphing into
  the real shape in 0.45 seconds. Canvas changes loading grey to each series'
  semantic colour along the same geometry. Home no longer uses the separate
  left-to-right sweep.
- Subsequent range / return-mode changes continue from the existing curve.
  A second change during an animation takes a snapshot using the last Canvas
  presentation progress, rather than jumping to the previous target first.
- Respect the system Reduce Motion preference. No per-frame observable state
  updates are sent to the parent; correspondence is prepared once per update.

## Home card overlap

As the Today card moves over the pinned asset chart, a native backdrop blur
increases with upward travel. A soft mask makes the covered content clearer
at the card's leading edge and more blurred deeper underneath it. The card's
own text and charts stay sharp. Its final opaque surface arrives later in the
travel so the blur remains visible during the transition; scrolling back down
reverses the same effect. Width, scroll detents and chart data are unchanged.

`PortfolioSheetBackdropBlur` uses the existing scroll offset, a paused native
blur animator and a mask applied directly to its effect view. It does not take
snapshots or create another chart. The effect is removed at the clear/opaque
endpoints and when offscreen. Reduce Transparency uses the opaque surface.
This change was compiled and installed only; no gesture or UI tests were run.

## Root cause of comparison spikes

The previous viewport animation directly joined old and incoming samples by
date, preferring incoming values only on exact duplicate dates. Return windows
and modes can have different bases and different sampling dates. Alternating
old-base / new-base vertices created a temporary sawtooth before the final frame.

`StandardLineChartViewportPath` interpolates both histories at each common date
and blends corresponding values. Its animated endpoints use that same path.
The first and final frames return the exact original vertex arrays. This is a
presentation change only; return calculations and stored observations are not
modified.

## Annotations and special charts

- Trade markers identify their owning price series. Shared markers remain on
  its animated path; entering/leaving markers scale in/out along that path.
- Price downsampling retains annotated trade-day vertices so a marker also
  stays on the polyline at rest. Fill price/account math is unchanged.
- Cost reference lines and their labels share the animated value-domain
  projection. Currency, colour, rings, interaction dimming and measurement
  remain owned by the existing feature.
- Canvas consumers: home, security price, return comparison, drawdown and
  industry sentiment. Swift Charts consumers use the same entrance template:
  research market sparklines, sector detail, rotation benchmark and analyst
  history. Native chart marks, missing-data segments, target bands, rating bars
  and selection remain intact. Two-dimensional rotation trails and non-line
  visualisations are not converted.

## Historical verification — 2026-09-10

The 2026-09-14 changes were not tested, at the user’s request. The results
below belong to the earlier implementation and do not validate this update.

Simulator: `9BAE01F7-1E92-45BD-A817-395FC654CC16`, iOS 26.5. No physical iPhone
operations or cache clearing. The existing isolated research XCTest host avoids
portfolio loading and model/provider calls.

- Incremental build-for-testing passed.
- `/tmp/CatfolioLineMotionTests-20260910.xcresult`: 40 passed, 1 opt-in live
  provider test skipped. Includes geometry, rapid retargeting, dense nine-series
  paths, marker alignment, card layout, fund visibility and existing interactions.
- `/tmp/CatfolioLineMotionReducedTests-20260910.xcresult`: 1 passed with the
  actual simulator Reduce Motion setting enabled and asserted by XCTest. The
  setting was restored to its original disabled state afterwards.
- 17 focused Python contracts passed. The broader existing range-picker suite
  has one unrelated stale expectation of `[.maximum]`; the current picker
  already uses `[.maximum, .fiveYears]`. The picker implementation was not changed.
- `git diff --check` passed.

Native nine-series fixtures captured in light/dark at entrance, rest, rebasing,
rapid interruption and settled states; intermediate frames visually checked.
These deliberately synthetic curves reproduce interleaved-date rebasing and
are not presented as portfolio returns.

- Normal frames: `/tmp/CatfolioLineMotionFrames/manifest.json`
- Reduced-motion frames: `/tmp/CatfolioLineMotionReducedFrames/manifest.json`
