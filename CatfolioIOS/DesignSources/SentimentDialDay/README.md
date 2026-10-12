# Daylight sentiment dial

Source: [Catfolio, node 640:24288](https://www.figma.com/design/EtNSXmasS8lz9JzrWUoMd9/Catfolio?node-id=640-24288).

The SVGs and `spectrum.png` are unchanged Figma downloads. `render.cjs` records
the original layer bounds and normalizes the 357.575-point dial to the existing
454-point component coordinate system. The face combines nodes 640:24298–24304;
the live pointer is 640:24305, and the soft/hard-light overlays are 640:24314/24315.
The reference screen and its system chrome are not bundled as app artwork.

Rebuild with the same renderer used by the dark dial:

```sh
npm install --prefix /tmp/catfolio-svg-render @resvg/resvg-js
NODE_PATH=/tmp/catfolio-svg-render/node_modules node CatfolioIOS/DesignSources/SentimentDialDay/render.cjs
python3 CatfolioIOS/DesignSources/SentimentDial/blur-header.py --source CatfolioIOS/DesignSources/SentimentDialDay/header-sharp.png --destination CatfolioIOS/CatfolioIOS/Assets.xcassets/SentimentDialDayHeaderFace.imageset
```

The industry sentiment page uses this artwork in light appearance, retaining
the bottom fade and cached progressive softening. Only the pointer rotates
at runtime; `MechanicalSentimentDial` selects the four daylight image sets.
The original night artwork is retained. Research uses its large title and
search field without a dial.
