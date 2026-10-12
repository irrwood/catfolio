# Performance entry cards

Appearance references in Catfolio `EtNSXmasS8lz9JzrWUoMd9`:

- Light: `487:5331`
- Dark: `641:25494`
- Light loss glow: `534:26459`, exported independently from the chart group.

SVG exports are stored untouched in the asset catalog. `assets.json` records their
canvas dimensions and hashes. The return/cycle Back, Middle, Front and CycleGlow
exports match the existing assets byte for byte, so those assets are reused.

`ReturnsSourceCard` keeps its live stacked gain/loss history. Only its paints,
glows and glyphs follow the references. Comparison cards retain their calculated
annualized returns rather than the example amounts in the design.

SVG blur filters are not rendered by the asset catalog; the existing SwiftUI
33-point glow and progressive card blur supply that effect. Original SVG canvas
sizes and padding are retained. Comparison artwork uses a 173-point design
canvas, scaled by its parent to the available card width.

Rendered validation: `ReturnsScrollPerformanceTests` captures the actual page in
both appearances. `ReturnsEntryAppearanceTests` checks contrast tokens and the
compiled artwork's dimensions and visible pixels.
