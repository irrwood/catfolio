#!/usr/bin/env python3
"""Reshape core's GBP FX delivery into the form the app bundles.

The delivery repeats `status` and `source` on all 159,000 points. Every one
of them is VERIFIED/ecb, so hoisting the pair into the header is lossless and
takes the payload from 12.1 MB to 2.5 MB — which matters because the app
decodes this on a background task at launch, and raw size is what that costs.

Dates become one shared axis with a parallel array per currency; null marks a
day that currency has no observation for. That preserves the delivery's
OMIT_NO_FORWARD_FILL promise exactly: a missing day stays missing rather than
inheriting its neighbour.

Refuses to write if any point disagrees with the hoisted status or source, so
a future delivery that mixes providers fails here instead of silently
claiming ECB for all of it.

    python3 scripts/make_gbp_fx_resource.py <delivery.json> <out.json>
"""
import hashlib
import json
import sys


def main(src: str, dst: str) -> None:
    raw = open(src, "rb").read()
    doc = json.loads(raw)
    rates = {c: v for c, v in doc["rates"].items() if v}

    statuses = {p["status"] for v in rates.values() for p in v}
    sources = {p["source"] for v in rates.values() for p in v}
    if statuses != {"VERIFIED"} or sources != {"ecb"}:
        raise SystemExit(f"mixed provenance, cannot hoist: {statuses} {sources}")

    dates = sorted({p["date"] for v in rates.values() for p in v})
    index = {d: i for i, d in enumerate(dates)}
    series = {c: [None] * len(dates) for c in rates}
    for currency, points in rates.items():
        for point in points:
            series[currency][index[point["date"]]] = point["rate"]

    out = {
        "schemaVersion": 1,
        "baseCurrency": doc["baseCurrency"],
        "direction": doc["direction"],
        "conversionToGBP": doc["conversionToGBP"],
        "rateKind": doc["rateKind"],
        "formula": doc["formula"],
        "dateMeaning": doc["dateMeaning"],
        "nonObservationDayPolicy": doc["nonObservationDayPolicy"],
        "lookupPolicy": doc["lookupPolicy"],
        "missingPointStatus": doc["missingPointStatus"],
        "status": "VERIFIED",
        "source": "ecb",
        "unsupportedCurrencies": doc["unsupportedCurrencies"],
        "derivedFrom": {
            "sha256": hashlib.sha256(raw).hexdigest(),
            "transform": "hoist uniform status/source; share one date axis; null marks no observation",
        },
        "dates": dates,
        "rates": series,
    }
    json.dump(out, open(dst, "w"), separators=(",", ":"), ensure_ascii=False)
    print(f"{len(dates)} dates x {len(series)} currencies -> {dst}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
