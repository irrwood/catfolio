"""
Generic CSV portfolio import.

Accepts transaction-based CSV exports from any broker with these columns
(case-insensitive, extra columns are ignored):

  Date       YYYY-MM-DD, MM/DD/YYYY, or DD/MM/YYYY
  Action     BUY / SELL / DIVIDEND  (case-insensitive)
  Ticker     stock symbol (e.g. AAPL, LLOY.L)
  Quantity   number of shares (positive)
  Price      price per share in the stated currency
  Currency   USD / GBP / GBX / EUR  (optional, default USD)
  Name       human-readable name  (optional)

Computes weighted-average cost (WAC) per position and writes the result to
portfolio_analysis.json and trading212_data.json so every page picks it up.
"""

import csv
import io
import json
import shutil
import time
from datetime import datetime
from pathlib import Path

_FX = {"USD": 1.0, "GBP": 1.346, "GBX": 0.01346, "EUR": 1.163}

# Normalise common column name variants to canonical names
_COL_ALIASES = {
    "date":       ["date", "trade date", "transaction date", "time"],
    "action":     ["action", "type", "transaction type", "side", "direction"],
    "ticker":     ["ticker", "symbol", "instrument", "stock", "isin", "code"],
    "quantity":   ["quantity", "qty", "shares", "units", "amount", "no. of shares"],
    "price":      ["price", "price / share", "trade price", "unit price", "execution price"],
    "currency":   ["currency", "ccy", "curr", "currency (price)", "price currency"],
    "name":       ["name", "company", "description", "instrument name", "security name"],
}


def _normalise_headers(raw_headers):
    """Return a dict mapping canonical name → column index."""
    low = [h.strip().lower() for h in raw_headers]
    result = {}
    for canonical, aliases in _COL_ALIASES.items():
        for alias in aliases:
            if alias in low:
                result[canonical] = low.index(alias)
                break
    return result


def _parse_date(s):
    s = s.strip()
    for fmt in ("%Y-%m-%d", "%m/%d/%Y", "%d/%m/%Y", "%Y/%m/%d", "%d-%m-%Y"):
        try:
            return datetime.strptime(s, fmt)
        except ValueError:
            continue
    raise ValueError(f"Unrecognised date format: {s!r}")


def _num(s):
    return float(str(s).replace(",", "").strip())


def parse_transactions(csv_text: str) -> tuple[list[dict], list[str]]:
    """Parse CSV text into a list of transaction dicts.  Returns (rows, warnings)."""
    reader = csv.reader(io.StringIO(csv_text.strip()))
    rows_raw = list(reader)
    if not rows_raw:
        return [], ["CSV is empty"]

    headers = _normalise_headers(rows_raw[0])
    required = {"date", "action", "ticker", "quantity", "price"}
    missing = required - headers.keys()
    if missing:
        return [], [f"Missing required columns: {', '.join(sorted(missing))}. "
                    f"Found: {', '.join(rows_raw[0][:8])}"]

    transactions = []
    warnings = []
    for i, row in enumerate(rows_raw[1:], start=2):
        if not any(row):
            continue
        try:
            action = row[headers["action"]].strip().upper()
            if action not in ("BUY", "SELL", "DIVIDEND"):
                continue  # skip rows like DEPOSIT, WITHDRAWAL, etc.
            date = _parse_date(row[headers["date"]])
            ticker = row[headers["ticker"]].strip().upper()
            if not ticker:
                continue
            qty = _num(row[headers["quantity"]])
            price = _num(row[headers["price"]])
            currency = row[headers["currency"]].strip().upper() if "currency" in headers else "USD"
            if currency == "GBP":
                currency = "GBX" if price < 200 else "GBP"  # T212 exports pence as GBP sometimes
            name = row[headers["name"]].strip() if "name" in headers else ""
            transactions.append({
                "date": date,
                "action": action,
                "ticker": ticker,
                "quantity": qty,
                "price": price,
                "currency": currency or "USD",
                "name": name,
            })
        except Exception as exc:
            warnings.append(f"Row {i}: {exc}")

    return transactions, warnings


def compute_holdings(transactions: list[dict]) -> list[dict]:
    """Compute current holdings via weighted-average cost from sorted transactions."""
    transactions = sorted(transactions, key=lambda t: t["date"])
    positions: dict[str, dict] = {}

    for tx in transactions:
        ticker = tx["ticker"]
        ccy = tx["currency"]
        qty = tx["quantity"]
        price = tx["price"]
        name = tx.get("name", "")

        pos = positions.setdefault(ticker, {
            "ticker": ticker, "name": name, "currency": ccy,
            "shares": 0.0, "avg_cost_native": 0.0,
        })
        if name and not pos["name"]:
            pos["name"] = name

        if tx["action"] == "BUY":
            new_qty = pos["shares"] + qty
            if new_qty > 0:
                pos["avg_cost_native"] = (
                    pos["avg_cost_native"] * pos["shares"] + price * qty
                ) / new_qty
            pos["shares"] = new_qty
        elif tx["action"] == "SELL":
            pos["shares"] = max(0.0, pos["shares"] - qty)

    # Filter out fully-closed positions (< 0.001 shares remaining)
    return [p for p in positions.values() if p["shares"] > 0.001]


def holdings_to_portfolio_json(holdings: list[dict]) -> dict:
    """Convert computed holdings to portfolio_analysis.json format."""
    rows = []
    total_cost = 0.0
    for h in holdings:
        ccy = h["currency"]
        fx = _FX.get(ccy, 1.0)
        cost_native = h["shares"] * h["avg_cost_native"]
        cost_usd = cost_native * fx
        total_cost += cost_usd
        rows.append({
            "ticker": h["ticker"],
            "name": h["name"] or h["ticker"],
            "yahoo_symbol": h["ticker"],
            "shares": round(h["shares"], 6),
            "cost_currency": ccy,
            "avg_cost_native": round(h["avg_cost_native"], 4),
            "cost_usd_standard": round(cost_usd, 2),
            "last_trade_price": None,
            "price_currency": ccy,
        })
    return {
        "summary": {
            "total_cost_usd_standard": round(total_cost, 2),
            "open_positions": len(rows),
            "as_of": datetime.now().strftime("%Y-%m-%d"),
            "source": "csv_import",
        },
        "holdings": rows,
        "holdings_by_account": [{"account": "Imported", "holdings": rows}],
    }


def holdings_to_trading212_json(holdings: list[dict]) -> dict:
    """Produce a trading212_data.json-compatible structure from imported holdings."""
    positions = []
    for h in holdings:
        positions.append({
            "ticker": h["ticker"],
            "name": h["name"] or h["ticker"],
            "shares": round(h["shares"], 6),
            "avg_cost_native": round(h["avg_cost_native"], 4),
            "last_trade_price": None,
            "price_currency": h["currency"],
            "cost_currency": h["currency"],
        })
    return {
        "as_of_unix": int(time.time()),
        "summary": {"positions": len(positions)},
        "account_cash": {"total": 0.0, "currency": "USD"},
        "positions": positions,
        "warnings": [],
        "source": "csv_import",
    }


def process_csv_upload(csv_text: str, v2_dir: Path) -> dict:
    """Full pipeline: parse → compute holdings → write JSON files.

    Returns a result dict with 'ok', 'holdings_count', 'warnings'.
    """
    transactions, parse_warnings = parse_transactions(csv_text)
    if not transactions and parse_warnings:
        return {"ok": False, "warnings": parse_warnings, "holdings_count": 0}

    holdings = compute_holdings(transactions)
    if not holdings:
        return {"ok": False, "warnings": parse_warnings + ["No open positions found in CSV"], "holdings_count": 0}

    v2_dir.mkdir(parents=True, exist_ok=True)
    pf_path = v2_dir / "portfolio_analysis.json"
    t212_path = v2_dir / "trading212_data.json"

    existing_paths = [path for path in (pf_path, t212_path) if path.exists()]
    backup_created = bool(existing_paths)
    if backup_created:
        backup_dir = v2_dir / "csv_import_backups" / datetime.now().strftime("%Y%m%dT%H%M%S%f")
        backup_dir.mkdir(parents=True, exist_ok=False)
        for path in existing_paths:
            shutil.copy2(path, backup_dir / path.name)

    pf_path.write_text(json.dumps(holdings_to_portfolio_json(holdings), ensure_ascii=False, indent=2), encoding="utf-8")
    t212_path.write_text(json.dumps(holdings_to_trading212_json(holdings), ensure_ascii=False, indent=2), encoding="utf-8")

    # Invalidate snapshot cache so next page load picks up fresh data
    from app.cache import clear_all
    clear_all()

    return {
        "ok": True,
        "holdings_count": len(holdings),
        "transactions_count": len(transactions),
        "backup_created": backup_created,
        "warnings": parse_warnings,
        "holdings": [{"ticker": h["ticker"], "name": h["name"], "shares": round(h["shares"], 4),
                      "avg_cost": round(h["avg_cost_native"], 2), "currency": h["currency"]}
                     for h in sorted(holdings, key=lambda x: x["ticker"])],
    }
