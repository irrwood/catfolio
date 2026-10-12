// Figma Catfolio / 640:24288. Original downloads beside this script are kept
// unchanged. Rasterize the supplied layers, not the reference screenshot.
// NODE_PATH=/tmp/catfolio-svg-render/node_modules node CatfolioIOS/DesignSources/SentimentDialDay/render.cjs
// python3 CatfolioIOS/DesignSources/SentimentDial/blur-header.py --source CatfolioIOS/DesignSources/SentimentDialDay/header-sharp.png --destination CatfolioIOS/CatfolioIOS/Assets.xcassets/SentimentDialDayHeaderFace.imageset
const fs = require('node:fs');
const path = require('node:path');
const { Resvg } = require('@resvg/resvg-js');
const assets = path.join(__dirname, '../../CatfolioIOS/Assets.xcassets');
const size = 357.5752258300781;
const scale = 454 / size;
const origin = [22.4423828125, 79];
// Exact frames returned by get_design_context/get_metadata, in screen points.
const layers = [
    ['bezel.svg', '640:24298', 22.4423828125, 79, size, size],
    ['rim.svg', '640:24299', 35.83203125, 92.38916015625, 330.79644775390625, 330.79644775390625],
    ['face.svg', '640:24300', 38.19482421875, 94.751953125, 326.07080078125, 326.07080078125],
    ['stroke.svg', '640:24301', 38.19482421875, 94.751953125, 326.07080078125, 326.07080078125],
    ['spectrum.png', '640:24302', 49.22119140625, 105.77880859375, 304.0177001953125, 304.0177001953125],
    ['center.svg', '640:24303', 122.46923828125, 179.0263671875, 157.52212524414062, 157.52212524414062],
    ['hub.svg', '640:24304', 189.416015625, 245.9736328125, 23.628318786621094, 23.628318786621094],
];
let svg = '<svg xmlns="http://www.w3.org/2000/svg" width="454" height="454" viewBox="0 0 454 454">';
for (const [file, , x, y, width, height] of layers) {
    const mime = file.endsWith('.svg') ? 'image/svg+xml' : 'image/png';
    const data = fs.readFileSync(path.join(__dirname, file)).toString('base64');
    svg += `<image x="${(x - origin[0]) * scale}" y="${(y - origin[1]) * scale}" width="${width * scale}" height="${height * scale}" href="data:${mime};base64,${data}"/>`;
}
svg += '</svg>';
fs.writeFileSync(path.join(__dirname, 'header-sharp.png'), new Resvg(svg, { fitTo: { mode: 'zoom', value: 3 } }).render().asPng());

// The pointer and its two original blend overlays stay separate so the live
// value can rotate the pointer without redrawing the static face.
for (const [file, name] of [['needle.svg', 'PanelNeedle'], ['gloss-soft.svg', 'GlossSoft'], ['gloss-hard.svg', 'GlossHard']]) {
    const directory = path.join(assets, `SentimentDialDay${name}.imageset`);
    fs.mkdirSync(directory, { recursive: true });
    const png = new Resvg(fs.readFileSync(path.join(__dirname, file)), { fitTo: { mode: 'zoom', value: 3 * scale } }).render().asPng();
    fs.writeFileSync(path.join(directory, 'art.png'), png);
    fs.writeFileSync(path.join(directory, 'Contents.json'), JSON.stringify({
        images: [{ filename: 'art.png', idiom: 'universal', scale: '3x' }],
        info: { author: 'xcode', version: 1 },
    }, null, 2) + '\n');
}
