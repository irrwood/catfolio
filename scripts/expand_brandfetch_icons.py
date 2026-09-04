#!/usr/bin/env python3
"""Expand Catfolio's bundled logo set with exact-domain Brandfetch icons.

The Brandfetch Search API returns a signed square icon URL and does not consume
the limited Brand API quota.  Only exact domain matches above the configured
quality threshold are accepted.  Existing hand-selected Brand API symbols are
never replaced.
"""

from __future__ import annotations

import argparse
import ast
import io
import json
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ASSET_DIR = ROOT / "CatfolioIOS/CatfolioIOS/Resources/AssetLogos"
DEFAULT_MANIFEST = ROOT / "CatfolioIOS/brandfetch-symbols.json"
DEFAULT_SOURCE = Path("/Users/qian/Downloads/us_stock_logos.py")
SEARCH_URL = "https://api.brandfetch.io/v2/search/{query}"


def load_fallback_companies(source: Path) -> list[tuple[str, str, str]]:
    tree = ast.parse(source.read_text(encoding="utf-8"), filename=str(source))
    for node in tree.body:
        if isinstance(node, ast.Assign):
            if any(isinstance(target, ast.Name) and target.id == "FALLBACK_COMPANIES" for target in node.targets):
                rows = ast.literal_eval(node.value)
                return [(str(t), str(n), str(d)) for t, n, d in rows if d]
    raise RuntimeError(f"FALLBACK_COMPANIES not found in {source}")


def exact_brand(session: requests.Session, domain: str, min_quality: float) -> dict | None:
    response = session.get(SEARCH_URL.format(query=domain), timeout=20)
    response.raise_for_status()
    for brand in response.json():
        if (brand.get("domain") or "").lower() != domain.lower():
            continue
        if not brand.get("verified"):
            return None
        if float(brand.get("qualityScore") or 0) < min_quality:
            return None
        if not brand.get("icon"):
            return None
        return brand
    return None


def download_png(session: requests.Session, url: str, destination: Path, size: int) -> int:
    response = session.get(url, timeout=20)
    response.raise_for_status()
    if not (response.headers.get("Content-Type") or "").startswith("image/"):
        raise RuntimeError("Brandfetch returned a non-image response")
    with Image.open(io.BytesIO(response.content)) as source:
        image = source.convert("RGBA")
        image.thumbnail((size, size), Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        canvas.alpha_composite(image, ((size - image.width) // 2, (size - image.height) // 2))
        canvas.save(destination, "PNG", optimize=True)
    return destination.stat().st_size


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--asset-dir", type=Path, default=DEFAULT_ASSET_DIR)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--limit", type=int, default=75, help="maximum number of newly accepted icons")
    parser.add_argument("--size", type=int, default=96)
    parser.add_argument("--min-quality", type=float, default=0.85)
    parser.add_argument("--delay", type=float, default=0.12)
    args = parser.parse_args()

    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    protected = {row["ticker"] for row in manifest.get("assets", [])}
    protected.update(
        row["ticker"]
        for row in manifest.get("failed", [])
        if row.get("reason") == "not_symbol_like_after_visual_review"
    )
    candidates = [row for row in load_fallback_companies(args.source) if row[0] not in protected]
    session = requests.Session()
    session.headers["User-Agent"] = "Catfolio/1.0 Brandfetch icon pack builder"

    accepted: list[dict] = []
    failed: list[dict] = []
    for ticker, company, domain in candidates:
        if len(accepted) >= args.limit:
            break
        try:
            brand = exact_brand(session, domain, args.min_quality)
            if brand is None:
                failed.append({"ticker": ticker, "domain": domain, "reason": "no_exact_verified_icon"})
                continue
            size_bytes = download_png(session, brand["icon"], args.asset_dir / f"{ticker}.png", args.size)
            accepted.append({
                "ticker": ticker,
                "brand": brand.get("name") or company,
                "domain": domain,
                "brand_id": brand.get("brandId"),
                "asset_type": "icon",
                "theme": "brand_default",
                "format": "png",
                "quality_score": round(float(brand.get("qualityScore") or 0), 4),
                "bytes": size_bytes,
            })
            print(f"{len(accepted):>3}  {ticker:<6} {brand.get('name') or company}")
        except Exception as error:
            failed.append({"ticker": ticker, "domain": domain, "reason": type(error).__name__})
        time.sleep(args.delay)

    manifest["generated_at"] = datetime.now(timezone.utc).isoformat()
    manifest["selection"] = (
        "Hand-selected Brand API symbols are preferred; exact-domain, verified, "
        "high-quality Brandfetch Search API icons expand coverage; FMP remains the fallback."
    )
    manifest["assets"].extend(accepted)
    manifest["count"] = len(manifest["assets"])
    manifest.setdefault("failed", []).extend(failed)
    args.manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Added {len(accepted)} Brandfetch icons; total Brandfetch coverage: {manifest['count']}")


if __name__ == "__main__":
    main()
