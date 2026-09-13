"""Render the static, no-JavaScript-required gallery from features.json."""
import json
import re
from html import escape
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def render():
    features = json.loads((ROOT / "features.json").read_text())
    assert len({item["id"] for item in features}) == len(features)
    cards = []
    for item in features:
        assert (ROOT / item["image"]).is_file(), item["image"]
        e = {key: escape(str(value), quote=True) for key, value in item.items()}
        rows = "".join(f"<li>{escape(line)}</li>" for line in item["items"])
        cards.append(f'''<article class="capability" data-group="{e['group']}" id="capability-{e['id']}">
<button class="screenshot-button" data-shot="{e['id']}" aria-label="放大查看：{e['label']}截图"><img src="{e['image']}" width="1206" height="2622" alt="{e['label']}：{e['note']}" loading="lazy" decoding="async"><span class="zoom-label">查看截图 ↗</span></button>
<p class="capability-label">{e['label']}</p><h3>{e['title']}</h3><p class="capability-description">{e['description']}</p>
<ul>{rows}</ul><p class="capability-note">{e['note']}</p></article>''')
    path = ROOT / "index.html"
    html = path.read_text()
    block = '<!-- FEATURES:START -->\n<div class="capability-grid">\n' + "\n".join(cards) + '\n</div>\n<!-- FEATURES:END -->'
    html, count = re.subn(r"<!-- FEATURES:START -->.*?<!-- FEATURES:END -->", lambda _: block, html, flags=re.S)
    assert count == 1, "Expected exactly one gallery block"
    html = re.sub(r'(<span data-feature-total>)\d+', rf'\g<1>{len(features)}', html)
    html = re.sub(r'(<span id="feature-count"[^>]*>)\d+ 项功能', rf'\g<1>{len(features)} 项功能', html)
    path.write_text(html)
    print(f"Rendered {len(features)} features with verified image paths.")


if __name__ == "__main__":
    render()
    from render_english import render as render_english
    render_english()
