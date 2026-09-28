"""Generate en.html from the shared layout and checked English content."""
import json
import re
from html import escape, unescape
from pathlib import Path

ROOT = Path(__file__).resolve().parent

def render():
    translations = json.loads((ROOT / 'translations.en.json').read_text())
    features = json.loads((ROOT / 'features.en.json').read_text())
    original = json.loads((ROOT / 'features.json').read_text())
    assert [f['id'] for f in features] == [f['id'] for f in original], 'English feature IDs need updating'
    html = (ROOT / 'index.html').read_text()
    html = re.sub(r'<!-- FEATURES:START -->.*?<!-- FEATURES:END -->', '<!-- ENGLISH_GALLERY -->', html, flags=re.S)
    def translate(value):
        stripped = unescape(value.strip())
        if re.fullmatch(r'\d+ 项功能', stripped):
            return value.replace(value.strip(), str(len(features)) + ' features')
        if not re.search(r'[\u4e00-\u9fff]', stripped):
            return value
        assert stripped in translations, f'Missing English translation: {stripped}'
        return value.replace(value.strip(), escape(translations[stripped], quote=True))
    html = re.sub(r'>([^<>]+)<', lambda m: '>' + translate(m[1]) + '<', html)
    html = re.sub(r'(alt|aria-label|content)="([^"]*)"', lambda m: m[1] + '="' + translate(m[2]) + '"', html)
    cards = []
    for f, source in zip(features, original):
        assert (ROOT / f['image']).is_file()
        e = {k: escape(str(v), quote=True) for k, v in f.items()}
        rows = ''.join('<li>' + escape(item) + '</li>' for item in f['items'])
        cards.append(f'''<article class="capability" data-group="{e['group']}" id="capability-{e['id']}">
<button class="screenshot-button" data-shot="{e['id']}" aria-label="Enlarge {e['label']} screenshot"><img src="{e['image']}" width="1206" height="2622" alt="{e['label']}: {e['note']}" loading="lazy" decoding="async"><span class="zoom-label">View screenshot ↗</span></button>
<h3 class="capability-label">{e['label']}</h3><p class="capability-description">{e['description']}</p><details class="capability-details"><summary>Details &amp; data notes</summary><ul>{rows}</ul><p class="capability-note">{e['note']}</p></details></article>''')
    html = html.replace('<!-- ENGLISH_GALLERY -->', '<div class="capability-grid">\n' + '\n'.join(cards) + '\n</div>')
    html = html.replace('assets/zh-latest/', 'assets/en-latest/')
    html = html.replace('lang="zh-CN"', 'lang="en"', 1)
    html = html.replace('href="index.html" hreflang="zh-CN" lang="zh-CN" data-language-switch aria-current="page">Chinese', 'href="index.html" hreflang="zh-CN" lang="zh-CN" data-language-switch>Chinese')
    html = html.replace('href="en.html" hreflang="en" lang="en" data-language-switch>English', 'href="en.html" hreflang="en" lang="en" data-language-switch aria-current="page">English')
    html = re.sub(r'(<span id="feature-count"[^>]*>)[^<]+', lambda m: m[1] + str(len(features)) + ' features', html)
    leftovers = re.findall(r'[\u4e00-\u9fff]+', html.replace('简体中文', ''))
    assert not leftovers, leftovers
    (ROOT / 'en.html').write_text(html)
    print(f'Rendered English page with {len(features)} translated features.')

if __name__ == '__main__':
    render()
