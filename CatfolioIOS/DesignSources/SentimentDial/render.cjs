// npm install --prefix /tmp/catfolio-svg-render @resvg/resvg-js
// NODE_PATH=/tmp/catfolio-svg-render/node_modules node CatfolioIOS/DesignSources/SentimentDial/render.cjs
// Xcode's SVG importer drops the original inner-shadow and noise filters.
// Bake only these static material layers; the pointer remains vector artwork.
const fs = require('node:fs');
const path = require('node:path');
const { Resvg } = require('@resvg/resvg-js');

for (const name of ['Bezel', 'Rim', 'Face', 'Stroke', 'HubLight', 'NewNeedle', 'PanelNeedle', 'GlossSoft', 'GlossHard']) {
    const source = fs.readFileSync(path.join(__dirname, `${name}.svg`));
    const image = new Resvg(source, { fitTo: { mode: 'zoom', value: 3 } }).render().asPng();
    const destination = path.join(__dirname, '../../CatfolioIOS/Assets.xcassets', `SentimentDial${name}.imageset`);
    fs.writeFileSync(path.join(destination, 'art.png'), image);
}
