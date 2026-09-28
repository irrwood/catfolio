// NODE_PATH=/tmp/catfolio-svg-render/node_modules node CatfolioIOS/DesignSources/SentimentDial/render-header.cjs
// Follow with python3 CatfolioIOS/DesignSources/SentimentDial/blur-header.py.
const fs = require('node:fs');
const path = require('node:path');
const { Resvg } = require('@resvg/resvg-js');
const root = path.join(__dirname, '../../CatfolioIOS/Assets.xcassets');
const layers = [['Bezel',0,0,454,454],['Rim',17,17,420,420],['Face',20,20,414,414],['Stroke',20,20,414,414],['NewSpectrum',34,34,386,386],['Center',127,127,200,200]];
let svg = '<svg xmlns="http://www.w3.org/2000/svg" width="454" height="454" viewBox="0 0 454 454">';
for (const [name,x,y,width,height] of layers) {
 const dir = path.join(root, `SentimentDial${name}.imageset`);
 const filename = JSON.parse(fs.readFileSync(path.join(dir,'Contents.json'))).images.find(x=>x.filename).filename;
 const mime = filename.endsWith('.svg') ? 'image/svg+xml' : 'image/png';
 svg += `<image x="${x}" y="${y}" width="${width}" height="${height}" href="data:${mime};base64,${fs.readFileSync(path.join(dir,filename)).toString('base64')}"/>`;
}
svg += '</svg>';
fs.writeFileSync(path.join(__dirname,'header-sharp.png'),new Resvg(svg,{fitTo:{mode:'zoom',value:3}}).render().asPng());
