# Asset logo presentation

`AssetLogo` shares the same rendering rules across holding rows, detail pages, contribution charts and heatmap snapshots. `AssetLogoArtwork` always uses aspect fit: the full source image keeps its proportions instead of being enlarged and cropped to fill a square.

`AssetLogoLayout` samples a 32 × 32 canvas during decoding. Opaque, approximately square brand tiles retain full-size presentation. Transparent or near-white canvas artwork touching the outer three sample pixels receives an 8% inset on each side; existing generous whitespace is retained without adding another inset. No cropping, recolouring or OCR is performed on source artwork. Mostly white ink on transparency receives a dark backing; other neutral-canvas artwork receives a white backing for consistent contrast in both themes. These are geometric and contrast heuristics, not semantic wordmark recognition.

The image cache stores both the decoded image and its layout under one eviction policy. Visible logo views also retain the resolved layout, so cache eviction does not change their appearance. Brand-colour callbacks continue to use the original decoded pixels.

Source images that are already deformed or low-resolution need replacement with a verified official icon or wordmark. Fitting cannot reconstruct lost source proportions. Very long wordmarks can remain small at 40pt; replacing them with an official compact symbol is an asset-curation decision, not automatic cropping or invented lettering.

Validation uses wide and tall synthetic artwork to check rendered pixel ratios, existing padding, opaque brand tiles, white-ink contrast and the existing asynchronous heatmap snapshot callback. Light/dark visual comparisons include ASML, Coca-Cola, NVIDIA, Oracle, Vanguard and IBM at 64pt and 40pt, plus synthetic horizontal and white wordmarks.
