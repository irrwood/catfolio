# Assistant and today-change control icons

Source: [Catfolio, frame 656:26612](https://www.figma.com/design/EtNSXmasS8lz9JzrWUoMd9/Catfolio?node-id=656-26612).
Imported on 2026-10-12 from the original Figma SVG exports.

| Asset | Node | Use |
| --- | --- | --- |
| `AssistantSparkles` | `656:26624` | 今天值得关注 and 洞察 entry rows, as specified by the user. |
| `AssistantMenu` | `656:26628` | Conversation-library button in the assistant's native and embedded headers; also the portfolio and holdings-heatmap sort/filter controls. |
| `TodayChangeRise` | `656:26633` | The 今日变化 direction button while showing rising contributions. |
| `TodayChangeFall` | `656:26635` | The same button while showing falling contributions. |

The user specified the two arrows for the button at the top of 今日变化.
They are not buy/sell indicators or a global replacement for price-direction symbols.

Each asset is an unmodified 24 × 24 SVG with vector preservation and template
rendering enabled. Existing foreground colors provide light/dark adaptation.
The blue Figma canvas is a preview background, not part of the icon assets.

On 2026-10-12 the user also selected the same three-line `AssistantMenu` artwork
for the holdings list and holdings heatmap. Both inline and floating controls
reuse this asset at its native 24 × 24 size, including the expanded heatmap's
toolbar and the portfolio loading placeholder. The old `PortfolioHeaderSort`
asset was removed after its final callsites were replaced.

## Search and calendar refresh

Source: [frame 656:26765](https://www.figma.com/design/EtNSXmasS8lz9JzrWUoMd9/Catfolio?node-id=656-26765), imported on 2026-10-12.

- `SearchIcon`, node `656:26782`: the research page's native search field,
  shared by its inline, pinned and editing states.
- `CorporateCalendarIcon`, node `656:26787`: updated company calendar heading
  artwork; the provenance hash is in `ReturnsEntries/assets.json`.

Both are unmodified 24 × 24 template SVGs. UIKit retains the search glyph's
native tint and the search field's existing layout and interaction.
