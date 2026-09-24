# Legacy asset logos

The ~1,000 single-version PNG logos the app shipped before the reviewed SVG
export. They are **not** in the app target. `core/tools/export_reviewed_logos_ios.py`
copies into `CatfolioIOS/Resources/AssetLogos/<TICKER>.png` only the ones whose
ticker the reviewed export does not cover, and removes those copies once it does.
`AssetLogo` tries the reviewed export first, then these, then Brandfetch.
