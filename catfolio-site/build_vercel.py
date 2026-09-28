"""Build the Vercel deployment in dist/: English at /, Chinese at /zh.

Deploy: python3 catfolio-site/build_vercel.py && cd catfolio-site/dist && npx vercel deploy --prod
"""
import re
import hashlib
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DIST = ROOT / 'dist'
LINKS = {'href="index.html"': 'href="/zh"', 'href="en.html"': 'href="/"'}

def build():
    # The hero must show two distinct screens, even if files have different names.
    for page in ('index.html', 'en.html'):
        html = (ROOT / page).read_text()
        hero = re.search(r'<div class="screens">(.*?)</div>', html, re.S)
        assert hero, f'Missing hero screenshots in {page}'
        paths = re.findall(r'src="([^"]+)"', hero[1])
        hashes = [hashlib.sha256((ROOT / path).read_bytes()).digest() for path in paths]
        assert len(paths) == 2 and len(set(hashes)) == 2, f'Duplicate hero screenshots in {page}'
    # Keep dist/.vercel, the link to the Vercel project.
    DIST.mkdir(exist_ok=True)
    for item in DIST.iterdir():
        if item.name != '.vercel':
            shutil.rmtree(item) if item.is_dir() else item.unlink()
    (DIST / 'assets').mkdir()
    for page, target in (('en.html', 'index.html'), ('index.html', 'zh.html')):
        html = (ROOT / page).read_text()
        for old, new in LINKS.items():
            html = html.replace(old, new)
        (DIST / target).write_text(html)
    for name in ('style.css', 'app.js'):
        shutil.copy(ROOT / name, DIST / name)
    for name in ('cat.svg', 'nunito.ttf'):
        shutil.copy(ROOT / 'assets' / name, DIST / 'assets' / name)
    shutil.copytree(ROOT / 'assets' / 'refresh', DIST / 'assets' / 'refresh')
    for language in ('zh-latest', 'en-latest'):
        shutil.copytree(ROOT / 'assets' / language, DIST / 'assets' / language)
    (DIST / 'vercel.json').write_text('{\n  "cleanUrls": true,\n  "redirects": [{ "source": "/en", "destination": "/" }]\n}\n')
    text = ''.join((DIST / f).read_text() for f in ('index.html', 'zh.html', 'style.css', 'app.js'))
    missing = sorted({p for p in re.findall(r'assets/[\w./-]+\.\w+', text) if not (DIST / p).is_file()})
    assert not missing, f'Missing assets: {missing}'
    print(f'Built {DIST.relative_to(ROOT.parent)}: English at /, Chinese at /zh.')

if __name__ == '__main__':
    build()
